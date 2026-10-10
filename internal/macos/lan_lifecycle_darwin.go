//go:build darwin

package macos

import (
	"sync"
	"sync/atomic"

	"github.com/ebitengine/purego/objc"
)

var lanObserverClassOnce sync.Once
var lanObserverClass objc.Class
var lanObserverClassErr error
var lanObservers sync.Map

type lanObservation struct {
	active atomic.Bool
	stop   func()
}

// notify runs on the AppKit thread, as does observer removal. Each delivered
// event revokes its current session; events must not be coalesced across starts.
func (o *lanObservation) notify() {
	if o.active.Load() {
		o.stop()
	}
}

// ObserveLANLifecycle must be installed and removed on the AppKit main thread.
// The callback must synchronously revoke without waiting for storage or OCR;
// it may schedule teardown off-thread (Service.RevokeLAN implements this).
// These documented notifications cover sleep, display sleep and session resign;
// they do not establish detection of every lock-with-display-awake transition.
// Ordinary application focus loss and wake never trigger or restart reception.
func ObserveLANLifecycle(stop func()) (func(), error) {
	if stop == nil {
		return nil, ErrLANUnavailable
	}
	if err := load(); err != nil {
		return nil, err
	}
	if send(class("NSThread"), "isMainThread") == 0 {
		return nil, ErrLANUnavailable
	}
	lanObserverClassOnce.Do(func() {
		lanObserverClass, lanObserverClassErr = objc.RegisterClass("KinlogueGoLANLifecycleObserver", objc.GetClass("NSObject"), nil, nil, []objc.MethodDef{{
			Cmd: objc.RegisterName("kinlogueLANStop:"), Fn: func(self objc.ID, _ objc.SEL, _ objc.ID) {
				value, ok := lanObservers.Load(self)
				if !ok {
					return
				}
				value.(*lanObservation).notify()
			},
		}})
	})
	if lanObserverClassErr != nil {
		return nil, ErrLANUnavailable
	}
	pool := poolPush()
	defer poolPop(pool)
	center := send(send(class("NSWorkspace"), "sharedWorkspace"), "notificationCenter")
	observer := send(send(id(lanObserverClass), "alloc"), "init")
	if center == 0 || observer == 0 {
		release(observer)
		return nil, ErrLANUnavailable
	}
	observation := &lanObservation{stop: stop}
	observation.active.Store(true)
	lanObservers.Store(observer, observation)
	for _, name := range lanStopNotifications {
		send(center, "addObserver:selector:name:object:", uintptr(observer), uintptr(objc.RegisterName("kinlogueLANStop:")), uintptr(nsString(name)), 0)
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			// Main-thread removal cannot overlap a delivered callback. Disable before
			// unregistering so a later delivery cannot revoke a newly started session.
			observation.active.Store(false)
			send(center, "removeObserver:", uintptr(observer))
			lanObservers.Delete(observer)
			release(observer)
		})
	}, nil
}
