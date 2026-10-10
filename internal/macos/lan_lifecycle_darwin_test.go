//go:build darwin

package macos

import "testing"

func TestLANLifecycleRevokesBeforeCallbackReturnsAndDoesNotCoalesce(t *testing.T) {
	count := 0
	observer := lanObservation{stop: func() { count++ }}
	observer.active.Store(true)
	observer.notify()
	if count != 1 {
		t.Fatal("revocation deferred beyond callback")
	}
	observer.notify()
	if count != 2 {
		t.Fatal("later session event coalesced with earlier stop")
	}
	observer.active.Store(false)
	observer.notify()
	if count != 2 {
		t.Fatal("removed observer affected later session")
	}
}
