//go:build darwin

package macos

import (
	"context"
	"net"
	"sync"
	"syscall"

	"golang.org/x/sys/unix"
)

// ListenLAN binds only the exact address and interface the user selected; it
// never listens on a wildcard address. Each accepted socket is re-validated and
// restricted to the selected interface prefix before HTTP reads a byte. The
// sandboxed preview needs com.apple.security.network.server for this call.
func ListenLAN(ctx context.Context, i LANInterface) (net.Listener, error) {
	if ctx.Err() != nil || !i.Valid() {
		return nil, ErrLANUnavailable
	}
	network := "tcp6"
	level, option := unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF
	if i.Address.Is4() {
		network = "tcp4"
		level, option = unix.IPPROTO_IP, unix.IP_BOUND_IF
	}
	config := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var bindErr error
		err := c.Control(func(fd uintptr) { bindErr = unix.SetsockoptInt(int(fd), level, option, i.Index) })
		if err != nil {
			return err
		}
		return bindErr
	}}
	listener, err := config.Listen(ctx, network, net.JoinHostPort(i.Address.String(), "0"))
	if err != nil {
		return nil, ErrLANUnavailable
	}
	if !i.Valid() {
		listener.Close()
		return nil, ErrLANUnavailable
	}
	admitted := &lanListener{Listener: listener, iface: i, valid: i.Valid, done: make(chan struct{})}
	go func() {
		select {
		case <-ctx.Done():
			admitted.Close()
		case <-admitted.done:
		}
	}()
	return admitted, nil
}

type lanListener struct {
	net.Listener
	iface LANInterface
	valid func() bool
	done  chan struct{}
	once  sync.Once
}

func (l *lanListener) Close() error {
	err := l.Listener.Close()
	l.once.Do(func() { close(l.done) })
	return err
}
func (l *lanListener) Accept() (net.Conn, error) {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		if !l.valid() {
			conn.Close()
			l.Close()
			return nil, ErrLANUnavailable
		}
		peer, ok := conn.RemoteAddr().(*net.TCPAddr)
		if !ok {
			conn.Close()
			continue
		}
		address := peer.AddrPort().Addr()
		if l.iface.Address.Is4() {
			address = address.Unmap()
		}
		if !l.iface.AllowsPeer(address) {
			conn.Close()
			continue
		}
		return conn, nil
	}
}
