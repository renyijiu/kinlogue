//go:build darwin

package macos

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"testing"
)

type lanTestListener struct {
	connections []net.Conn
	closed      bool
}

func (l *lanTestListener) Accept() (net.Conn, error) {
	if len(l.connections) == 0 {
		return nil, net.ErrClosed
	}
	c := l.connections[0]
	l.connections = l.connections[1:]
	return c, nil
}
func (l *lanTestListener) Close() error   { l.closed = true; return nil }
func (l *lanTestListener) Addr() net.Addr { return &net.TCPAddr{} }

type lanTestConn struct {
	net.Conn
	remote net.Addr
	closed bool
}

func (c *lanTestConn) RemoteAddr() net.Addr { return c.remote }
func (c *lanTestConn) Close() error         { c.closed = true; return nil }
func TestLANListenerRejectsBeforeDelivery(t *testing.T) {
	outside := &lanTestConn{remote: &net.TCPAddr{IP: net.IPv4(192, 0, 3, 20), Port: 42}}
	inside := &lanTestConn{remote: &net.TCPAddr{IP: net.IPv4(192, 0, 2, 20), Port: 42}}
	raw := &lanTestListener{connections: []net.Conn{outside, inside}}
	l := &lanListener{Listener: raw, iface: LANInterface{Name: "synthetic", Index: 7, Address: netip.MustParseAddr("192.0.2.10"), PrefixBits: 24}, done: make(chan struct{}), valid: func() bool { return true }}
	accepted, err := l.Accept()
	if err != nil || accepted != inside || !outside.closed || inside.closed {
		t.Fatal("admission boundary failed")
	}
}
func TestLANListenerClosesChangedInterface(t *testing.T) {
	conn := &lanTestConn{remote: &net.TCPAddr{IP: net.IPv4(192, 0, 2, 20), Port: 42}}
	raw := &lanTestListener{connections: []net.Conn{conn}}
	l := &lanListener{Listener: raw, done: make(chan struct{}), valid: func() bool { return false }}
	_, err := l.Accept()
	if !errors.Is(err, ErrLANUnavailable) || !conn.closed || !raw.closed {
		t.Fatal("changed interface did not revoke admission")
	}
}

func TestListenLANRejectsInvalidInterfaceBeforeSocket(t *testing.T) {
	for _, tc := range []struct {
		name  string
		iface LANInterface
		ctx   func() context.Context
	}{
		{"zero interface", LANInterface{}, context.Background},
		{"cancelled", LANInterface{Name: "synthetic", Index: 7, Address: netip.MustParseAddr("192.0.2.10"), PrefixBits: 24}, func() context.Context {
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			return ctx
		}},
		{"unknown synthetic interface", LANInterface{Name: "synthetic", Index: 7, Address: netip.MustParseAddr("192.0.2.10"), PrefixBits: 24}, context.Background},
	} {
		t.Run(tc.name, func(t *testing.T) {
			listener, err := ListenLAN(tc.ctx(), tc.iface)
			if listener != nil {
				listener.Close()
				t.Fatal("unselected interface opened a socket")
			}
			if !errors.Is(err, ErrLANUnavailable) {
				t.Fatalf("expected interface rejection: %v", err)
			}
		})
	}
}
