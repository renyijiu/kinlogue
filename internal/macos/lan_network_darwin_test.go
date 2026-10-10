//go:build darwin

package macos

import (
	"regexp"
	"sync/atomic"
	"testing"
	"time"
)

func TestLANNetworkObserverFailuresReleaseResources(t *testing.T) {
	for _, fail := range []string{"store", "queue", "keys", "schedule", ""} {
		var stores, queues atomic.Int32
		api := lanNetworkAPI{
			create: func(uintptr) uintptr {
				if fail == "store" {
					return 0
				}
				return 1
			},
			queue: func() uintptr {
				if fail == "queue" {
					return 0
				}
				return 2
			},
			keys:         func(uintptr) bool { return fail != "keys" },
			schedule:     func(_, q uintptr) bool { return q == 0 || fail != "schedule" },
			releaseStore: func(uintptr) { stores.Add(1) }, releaseQueue: func(uintptr) { queues.Add(1) },
		}
		remove, err := installLANNetwork(api, func() {})
		if fail == "" {
			if err != nil {
				t.Fatal(err)
			}
			remove()
			remove()
		} else if err == nil {
			t.Fatal("install failure accepted", fail)
		}
		wantStore := int32(1)
		if fail == "store" {
			wantStore = 0
		}
		wantQueue := int32(1)
		if fail == "store" || fail == "queue" {
			wantQueue = 0
		}
		if stores.Load() != wantStore || queues.Load() != wantQueue {
			t.Fatalf("resource release %s: %d/%d", fail, stores.Load(), queues.Load())
		}
	}
}
func TestLANNetworkSameSnapshotEventAndLateCallback(t *testing.T) {
	var token uintptr
	stopped := make(chan struct{}, 2)
	api := lanNetworkAPI{create: func(t uintptr) uintptr { token = t; return 1 }, queue: func() uintptr { return 2 }, keys: func(uintptr) bool { return true }, schedule: func(uintptr, uintptr) bool { return true }, releaseStore: func(uintptr) {}, releaseQueue: func(uintptr) {}}
	remove, err := installLANNetwork(api, func() { stopped <- struct{}{} })
	if err != nil {
		t.Fatal(err)
	}
	notifyLANNetwork(token) // Same address snapshot: any subscribed event still stops.
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("path change ignored")
	}
	remove()
	notifyLANNetwork(token)
	select {
	case <-stopped:
		t.Fatal("late callback delivered after removal")
	default:
	}
}

func TestLANNetworkSubscribedKeys(t *testing.T) {
	for _, tc := range []struct {
		key  string
		want bool
	}{
		{"State:/Network/Interface/synthetic/IPv4", true},
		{"State:/Network/Interface/synthetic/IPv6", true},
		{"State:/Network/Interface/synthetic/Link", true},
		{"State:/Network/Interface/synthetic/AirPort", true},
		{"State:/Network/Global/IPv4", true},
		{"State:/Network/Global/IPv6", true},
		{"State:/Network/Service/synthetic/IPv4", true},
		{"State:/Network/Service/synthetic/DNS", true},
		{"State:/Unrelated", false},
		{"State:/Network/Interface/synthetic/IPv4/extra", false},
	} {
		matched := false
		for _, pattern := range lanNetworkPatterns {
			if regexp.MustCompile(pattern).MatchString(tc.key) {
				matched = true
			}
		}
		if matched != tc.want {
			t.Fatalf("key subscription %s: %v", tc.key, matched)
		}
	}
}
