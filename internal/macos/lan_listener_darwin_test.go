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

func TestLANListenerBlockedUntilLockRevocationSupported(t *testing.T) {
	// Invalid synthetic interface prevents any real socket even if the gate regresses.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	listener, err := ListenLAN(ctx, LANInterface{})
	if listener != nil {
		listener.Close()
		t.Fatal("unverified receiver opened")
	}
	if !errors.Is(err, ErrLANLockUnavailable) {
		t.Fatalf("must reject for lock capability before socket setup: %v", err)
	}
}
