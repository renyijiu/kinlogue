//go:build !darwin

package macos

import (
	"context"
	"net"
)

func ListenLAN(context.Context, LANInterface) (net.Listener, error) { return nil, ErrLANUnavailable }
func ObserveLANLifecycle(func()) (func(), error)                    { return nil, ErrLANUnavailable }

func observeLANNetwork(func()) (func(), error) { return nil, ErrLANUnavailable }
