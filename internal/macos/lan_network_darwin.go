//go:build darwin

package macos

import (
	"context"
	"runtime"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/ebitengine/purego"
)

// Public SystemConfiguration dynamic-store keys. Link and AirPort changes also
// revoke a session when the replacement network retains the same IP snapshot.
var lanNetworkPatterns = []string{
	"^State:/Network/Interface/[^/]+/(IPv4|IPv6|Link|AirPort)$",
	"^State:/Network/Global/(IPv4|IPv6)$",
	"^State:/Network/Service/[^/]+/(IPv4|IPv6|DNS|Proxies)$",
}

type lanNetworkAPI struct {
	create       func(uintptr) uintptr
	queue        func() uintptr
	keys         func(uintptr) bool
	schedule     func(uintptr, uintptr) bool
	releaseStore func(uintptr)
	releaseQueue func(uintptr)
}

var lanNetworkTokens atomic.Uint64
var lanNetworkObservers sync.Map

type lanNetworkObservation struct {
	active atomic.Bool
	once   sync.Once
	stop   func()
}

func notifyLANNetwork(token uintptr) {
	value, ok := lanNetworkObservers.Load(token)
	if !ok {
		return
	}
	observation := value.(*lanNetworkObservation)
	observation.once.Do(func() {
		if observation.active.Load() {
			observation.stop()
		}
	})
}
func installLANNetwork(api lanNetworkAPI, stop func()) (func(), error) {
	token := uintptr(lanNetworkTokens.Add(1))
	observation := &lanNetworkObservation{stop: stop}
	observation.active.Store(true)
	lanNetworkObservers.Store(token, observation)
	store := api.create(token)
	if store == 0 {
		lanNetworkObservers.Delete(token)
		return nil, ErrLANUnavailable
	}
	queue := api.queue()
	var once sync.Once
	remove := func() {
		once.Do(func() {
			observation.active.Store(false)
			lanNetworkObservers.Delete(token)
			api.schedule(store, 0)
			api.releaseStore(store)
			if queue != 0 {
				api.releaseQueue(queue)
			}
		})
	}
	if queue == 0 || !api.keys(store) || !api.schedule(store, queue) {
		remove()
		return nil, ErrLANUnavailable
	}
	return remove, nil
}

type lanSCContext struct{ version, info, retain, release, description uintptr }

var lanSCOnce sync.Once
var lanSCErr error
var lanSCCreate func(uintptr, id, uintptr, *lanSCContext) uintptr
var lanSCKeys func(uintptr, id, id) uint8
var lanSCQueue func(uintptr, uintptr) uint8
var lanDispatchCreate func(string, uintptr) uintptr
var lanDispatchRelease func(uintptr)
var lanSCCallback uintptr

func loadLANNetwork() error {
	lanSCOnce.Do(func() {
		sc, err := purego.Dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			lanSCErr = ErrLANUnavailable
			return
		}
		system, err := purego.Dlopen("/usr/lib/libSystem.B.dylib", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			lanSCErr = ErrLANUnavailable
			return
		}
		bind := func(fn any, lib uintptr, name string) {
			if lanSCErr != nil {
				return
			}
			p, err := purego.Dlsym(lib, name)
			if err != nil {
				lanSCErr = ErrLANUnavailable
				return
			}
			purego.RegisterFunc(fn, p)
		}
		bind(&lanSCCreate, sc, "SCDynamicStoreCreate")
		bind(&lanSCKeys, sc, "SCDynamicStoreSetNotificationKeys")
		bind(&lanSCQueue, sc, "SCDynamicStoreSetDispatchQueue")
		bind(&lanDispatchCreate, system, "dispatch_queue_create")
		bind(&lanDispatchRelease, system, "dispatch_release")
		if lanSCErr == nil {
			lanSCCallback = purego.NewCallback(func(_, _ uintptr, info uintptr) { notifyLANNetwork(info) })
		}
	})
	return lanSCErr
}
func observeLANNetwork(stop func()) (func(), error) {
	var remove func()
	err := native(context.Background(), func() error {
		if err := loadLANNetwork(); err != nil {
			return err
		}
		api := lanNetworkAPI{
			create: func(token uintptr) uintptr {
				// SystemConfiguration copies the context synchronously. info is an opaque
				// integer registry key, never a Go pointer dereferenced by native code.
				context := lanSCContext{info: token}
				result := lanSCCreate(0, nsString("Kinlogue Go LAN session"), lanSCCallback, &context)
				runtime.KeepAlive(&context)
				return result
			},
			queue: func() uintptr { return lanDispatchCreate("org.kinlogue.go.lan-network", 0) },
			keys: func(store uintptr) bool {
				patterns := make([]id, 0, len(lanNetworkPatterns))
				for _, p := range lanNetworkPatterns {
					patterns = append(patterns, nsString(p))
				}
				return lanSCKeys(store, 0, nsArray(patterns...)) != 0
			},
			schedule:     func(store, queue uintptr) bool { return lanSCQueue(store, queue) != 0 },
			releaseStore: cfRelease, releaseQueue: lanDispatchRelease,
		}
		var err error
		remove, err = installLANNetwork(api, stop)
		return err
	})
	return remove, err
}

// Match the public five-word SCDynamicStoreContext ABI on supported 64-bit Macs.
var _ [5*unsafe.Sizeof(uintptr(0)) - unsafe.Sizeof(lanSCContext{})]byte
