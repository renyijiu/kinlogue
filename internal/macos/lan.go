package macos

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sort"
	"sync"
	"time"
)

var ErrLANUnavailable = errors.New("lan_interface_unavailable")
var ErrLANLockUnavailable = errors.New("lan_lock_revocation_unavailable")

// LANReceptionReadiness retains the disabled-preview gate pending separately
// authorized inbound networking and device acceptance. The historical error name
// is retained; automatic lock detection is no longer a product requirement.
// No setting or environment override enables reception.
func LANReceptionReadiness() error { return ErrLANLockUnavailable }

// LANInterface identifies the exact address, interface and prefix chosen by the user.
type LANInterface struct {
	Name       string
	Index      int
	Address    netip.Addr
	PrefixBits int
}

func usableLANAddress(a netip.Addr) bool {
	if !a.IsValid() || a.Zone() != "" || a.Is4In6() || !a.IsGlobalUnicast() || a.IsLoopback() {
		return false
	}
	if a.Is4() {
		b := a.As4()
		return b[0] != 0 && b[0] < 224
	}
	b := a.As16()
	for _, v := range b[:12] {
		if v != 0 {
			return true
		}
	}
	return false
}
func (i LANInterface) eligible() bool {
	return i.Name != "" && i.Index > 0 && usableLANAddress(i.Address) && i.PrefixBits > 0 && i.PrefixBits <= i.Address.BitLen()
}
func (i LANInterface) AllowsPeer(peer netip.Addr) bool {
	return i.eligible() && usableLANAddress(peer) && i.Address.BitLen() == peer.BitLen() && netip.PrefixFrom(i.Address, i.PrefixBits).Contains(peer)
}
func matchesLANInterface(selected LANInterface, current []LANInterface) bool {
	if !selected.eligible() {
		return false
	}
	for _, i := range current {
		if i == selected {
			return true
		}
	}
	return false
}

// LANInterfaces performs local interface enumeration only; it does not open sockets.
func LANInterfaces() ([]LANInterface, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, ErrLANUnavailable
	}
	out := []LANInterface{}
	for _, i := range interfaces {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagRunning == 0 || i.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := i.Addrs()
		if err != nil {
			return nil, ErrLANUnavailable
		}
		for _, raw := range addresses {
			n, ok := raw.(*net.IPNet)
			if !ok {
				continue
			}
			bits, total := n.Mask.Size()
			if bits == 0 || total == 0 {
				continue
			}
			a, ok := netip.AddrFromSlice(n.IP)
			if !ok {
				continue
			}
			a = a.Unmap()
			candidate := LANInterface{Name: i.Name, Index: i.Index, Address: a, PrefixBits: bits}
			if candidate.eligible() && total == a.BitLen() {
				out = append(out, candidate)
			}
		}
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].Name != out[b].Name {
			return out[a].Name < out[b].Name
		}
		return out[a].Address.Compare(out[b].Address) < 0
	})
	return out, nil
}

// Valid revalidates the full selected snapshot. Call again before publishing an upload.
func (i LANInterface) Valid() bool {
	current, err := LANInterfaces()
	return err == nil && matchesLANInterface(i, current)
}

// WatchLANInterface fails closed if public network notifications cannot be installed.
// Every matching path-change event revokes the session, even when the selected
// interface snapshot stays identical. Polling additionally detects lost addresses.
// stop must synchronously revoke the session (for example, cancel its context),
// then schedule teardown asynchronously; it must not block or call remove inline.
func WatchLANInterface(ctx context.Context, i LANInterface, stop func()) (func(), error) {
	if stop == nil || ctx.Err() != nil {
		return nil, ErrLANUnavailable
	}
	remove, err := observeLANNetwork(stop)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	var once sync.Once
	cleanup := func() { once.Do(func() { cancel(); remove() }) }
	go func() {
		defer cleanup()
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if !i.Valid() {
					stop()
					return
				}
			}
		}
	}()
	return cleanup, nil
}

var lanStopNotifications = []string{"NSWorkspaceWillSleepNotification", "NSWorkspaceScreensDidSleepNotification", "NSWorkspaceSessionDidResignActiveNotification"}

func stopsLANLifecycle(name string) bool {
	for _, n := range lanStopNotifications {
		if n == name {
			return true
		}
	}
	return false
}
