//go:build !windows

package workbench

import (
	"context"
	"errors"
	"os/exec"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/internal/guestprofile"
)

func TestNativeProfileRetriesOnlyDisconnectedTransport(t *testing.T) {
	for _, rejected := range []bool{false, true} {
		t.Run(map[bool]string{false: "boot-disconnect", true: "rejected-profile"}[rejected], func(t *testing.T) {
			s := testServer(t)
			if err := s.prepareGuestProfile(&guestprofile.Options{Hostname: "TEST-PC", Username: "alex", BrowserUsername: "web"}, "debian-13"); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var starts atomic.Int32
			c := &windowsBrowserClient{ctx: ctx, cancel: cancel, start: func(context.Context) (*exec.Cmd, error) {
				n := starts.Add(1)
				if !rejected && n <= 4 {
					return exec.Command("/bin/sh", "-c", "exit 0"), nil
				}
				reply := `{"ok":true}`
				if rejected {
					reply = `{"error":"browser_components_missing"}`
				}
				return exec.Command("/bin/sh", "-c", `while IFS= read -r line; do printf '%s\n' "$1"; done`, "fixture", reply), nil
			}}
			s.windowsBrowserControl = c
			defer c.close()
			err := s.syncNativeBrowserProfile(context.Background())
			if rejected {
				if err == nil || starts.Load() != 1 {
					t.Fatalf("rejection retried: starts=%d err=%v", starts.Load(), err)
				}
			} else if err != nil || starts.Load() != 5 {
				t.Fatalf("boot retry failed: starts=%d err=%v", starts.Load(), err)
			}
		})
	}
}

func TestNativeProfileWaitStopsAtCallerDeadline(t *testing.T) {
	s := testServer(t)
	if err := s.prepareGuestProfile(&guestprofile.Options{Hostname: "TEST-PC", Username: "alex", BrowserUsername: "web"}, "debian-13"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	var starts atomic.Int32
	c := &windowsBrowserClient{ctx: ctx, cancel: cancel, start: func(context.Context) (*exec.Cmd, error) {
		starts.Add(1)
		return exec.Command("/bin/sh", "-c", "exit 0"), nil
	}}
	s.windowsBrowserControl = c
	defer c.close()
	request, stop := context.WithTimeout(t.Context(), 150*time.Millisecond)
	defer stop()
	if err := s.syncNativeBrowserProfile(request); !errors.Is(err, context.DeadlineExceeded) || starts.Load() != 1 {
		t.Fatalf("readiness wait ignored deadline: starts=%d err=%v", starts.Load(), err)
	}
}
