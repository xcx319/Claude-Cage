//go:build !windows

package workbench

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestNativeBrowserReadReconnectsStalePipe(t *testing.T) {
	for _, route := range []string{"/health", "/tabs", "/events", "/frame"} {
		t.Run(route, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			var starts atomic.Int32
			c := &windowsBrowserClient{ctx: ctx, cancel: cancel, start: func(ctx context.Context) (*exec.Cmd, error) {
				if starts.Add(1) == 1 {
					// Return one reply, then close the pipe while its owner still
					// retains it. The next read must reconnect exactly once.
					return exec.CommandContext(ctx, "/bin/sh", "-c", `read -r line; printf '%s\n' '{"ok":true,"service":{"version":1,"persistent":true}}'`), nil
				}
				return exec.CommandContext(ctx, "/bin/sh", "-c", `while read -r line; do printf '%s\n' '{"ok":true}'; done`), nil
			}}
			defer c.close()
			for range 3 {
				if _, err := c.request(t.Context(), "GET", route, nil); err != nil {
					t.Fatal(err)
				}
			}
			if starts.Load() != 2 {
				t.Fatalf("healthy pipe not retained: starts=%d", starts.Load())
			}
		})
	}
}

func TestNativeBrowserLostMutationReplyIsNeverReplayed(t *testing.T) {
	for _, route := range []string{"/click", "/pointer", "/key", "/insert-text", "/file-finish", "/navigate", "/profile"} {
		t.Run(route, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			applied := filepath.Join(t.TempDir(), "applied")
			var starts atomic.Int32
			c := &windowsBrowserClient{ctx: ctx, cancel: cancel, start: func(ctx context.Context) (*exec.Cmd, error) {
				starts.Add(1)
				return exec.CommandContext(ctx, "/bin/sh", "-c", `read -r line; printf x >> "$1"`, "fixture", applied), nil
			}}
			defer c.close()
			_, err := c.request(t.Context(), "POST", route, nil)
			data, readErr := os.ReadFile(applied)
			if !errors.Is(err, errNativeBrowserDisconnected) || starts.Load() != 1 || readErr != nil || string(data) != "x" {
				t.Fatalf("mutation lost/replayed: starts=%d applied=%q read=%v err=%v", starts.Load(), data, readErr, err)
			}
		})
	}
}

func TestNativeBrowserReadRetryIsBounded(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	var starts atomic.Int32
	c := &windowsBrowserClient{ctx: ctx, cancel: cancel, start: func(ctx context.Context) (*exec.Cmd, error) {
		starts.Add(1)
		return exec.CommandContext(ctx, "/bin/sh", "-c", "exit 0"), nil
	}}
	defer c.close()
	if _, err := c.request(t.Context(), "GET", "/tabs", nil); !errors.Is(err, errNativeBrowserDisconnected) || starts.Load() != 2 {
		t.Fatalf("retry not bounded: starts=%d err=%v", starts.Load(), err)
	}
	cancel()
	if _, err := c.request(t.Context(), "GET", "/tabs", nil); !errors.Is(err, context.Canceled) || starts.Load() != 2 {
		t.Fatalf("closed service restarted: starts=%d err=%v", starts.Load(), err)
	}
}

func TestNativeBrowserLegacyOwnerHonorsCallerDeadline(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	c := &windowsBrowserClient{ctx: ctx, cancel: cancel, ownsBrowser: true, start: func(ctx context.Context) (*exec.Cmd, error) {
		return exec.CommandContext(ctx, "/bin/sh", "-c", "read -r line; exec sleep 10"), nil
	}}
	defer c.close()
	request, stop := context.WithTimeout(t.Context(), 150*time.Millisecond)
	defer stop()
	finished := make(chan error, 1)
	go func() { _, err := c.request(request, "GET", "/tabs", nil); finished <- err }()
	select {
	case err := <-finished:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("legacy request extended the caller's deadline")
	}
}
