//go:build darwin && arm64 && cgo && !no_vz

package maclogin

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#include "bridge.h"
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"golang.org/x/sys/unix"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

// Only the profile's current workbench controller may lease the native view.
// The socket remains open for the lease: EOF, lock, or controller death closes it.
func desktopControllerPeer(conn *net.UnixConn, profile string) bool {
	var record struct {
		PID int `json:"pid"`
	}
	data, err := os.ReadFile(filepath.Join(profile, "control.json"))
	if err != nil || json.Unmarshal(data, &record) != nil || record.PID < 2 {
		return false
	}
	raw, err := conn.SyscallConn()
	if err != nil {
		return false
	}
	var pid int
	var peerErr error
	err = raw.Control(func(fd uintptr) { pid, peerErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID) })
	return err == nil && peerErr == nil && pid == record.PID
}

func serveNativeDesktop(ctx context.Context, dir string) error {
	if !ownsLoginDirectory(dir) {
		return errors.New("invalid native desktop instance")
	}
	path := filepath.Join(dir, "cage-native-desktop.sock")
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode()&os.ModeSocket == 0 {
			return errors.New("unexpected native desktop socket")
		}
		probe, e := net.DialTimeout("unix", path, 300*time.Millisecond)
		if e == nil {
			probe.Close()
			return errors.New("native desktop already running")
		}
		if err = os.Remove(path); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(path)
	if err = os.Chmod(path, 0600); err != nil {
		return err
	}
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()
	slot := make(chan struct{}, 1)
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if !desktopControllerPeer(conn, filepath.Dir(os.Getenv("CLAUDE_CAGE_CONFIG"))) {
			conn.Close()
			continue
		}
		select {
		case slot <- struct{}{}:
		default:
			conn.Close()
			continue
		}
		go func() {
			defer func() { <-slot; conn.Close() }()
			if !bool(C.cageDesktopOpen()) {
				return
			}
			defer C.cageDesktopClose()
			if _, err := conn.Write([]byte("ready\n")); err != nil {
				return
			}
			done := make(chan struct{})
			go func() { _, _ = io.Copy(io.Discard, conn); close(done) }()
			ticker := time.NewTicker(250 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-done:
					return
				case <-ticker.C:
					if !bool(C.cageDesktopIsOpen()) {
						return
					}
				}
			}
		}()
	}
}
