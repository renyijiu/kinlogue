package macos

import (
	"net/netip"
	"testing"
)

func TestLANAddressAndPeerBoundary(t *testing.T) {
	for _, host := range []string{"0.0.0.0", "0.1.2.3", "127.0.0.1", "169.254.1.2", "224.0.0.1", "240.0.0.1", "::", "::1", "::192.0.2.1", "::ffff:192.0.2.1", "fe80::1", "ff02::1"} {
		if usableLANAddress(netip.MustParseAddr(host)) {
			t.Errorf("accepted invalid address %s", host)
		}
	}
	for _, tc := range []struct {
		local, peer string
		bits        int
		want        bool
	}{
		{"192.0.2.10", "192.0.2.20", 24, true}, {"192.0.2.10", "192.0.3.20", 24, false},
		{"192.0.2.10", "::ffff:192.0.2.20", 24, false}, {"2001:db8::10", "2001:db8::20", 64, true},
		{"2001:db8::10", "2001:db9::20", 64, false}, {"192.0.2.10", "192.0.2.20", 0, false},
	} {
		iface := LANInterface{Name: "synthetic", Index: 7, Address: netip.MustParseAddr(tc.local), PrefixBits: tc.bits}
		if got := iface.AllowsPeer(netip.MustParseAddr(tc.peer)); got != tc.want {
			t.Errorf("%+v got %v", tc, got)
		}
	}
}

func TestLANExactSnapshot(t *testing.T) {
	x := LANInterface{Name: "synthetic", Index: 7, Address: netip.MustParseAddr("192.0.2.10"), PrefixBits: 24}
	if !matchesLANInterface(x, []LANInterface{x}) {
		t.Fatal("matching snapshot rejected")
	}
	for _, change := range []func(*LANInterface){func(i *LANInterface) { i.Index++ }, func(i *LANInterface) { i.Name = "other" }, func(i *LANInterface) { i.PrefixBits = 25 }, func(i *LANInterface) { i.Address = netip.MustParseAddr("192.0.2.11") }} {
		changed := x
		change(&changed)
		if matchesLANInterface(x, []LANInterface{changed}) {
			t.Fatal("changed snapshot accepted")
		}
	}
}

func TestLANLifecycleOnlyPublicStopEvents(t *testing.T) {
	for _, name := range []string{"NSWorkspaceWillSleepNotification", "NSWorkspaceScreensDidSleepNotification", "NSWorkspaceSessionDidResignActiveNotification"} {
		if !stopsLANLifecycle(name) {
			t.Fatal("missing stop event", name)
		}
	}
	for _, name := range []string{"NSApplicationDidResignActiveNotification", "NSWorkspaceDidWakeNotification", "com.apple.screenIsLocked"} {
		if stopsLANLifecycle(name) {
			t.Fatal("unexpected stop event", name)
		}
	}
}
