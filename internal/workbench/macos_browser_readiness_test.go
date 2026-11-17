package workbench

import (
	"context"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/internal/cage"
	"github.com/sylvinus/agent-vm/internal/guestprofile"
	"golang.org/x/crypto/ssh"
)

func TestMacOSReadyProbeDoesNotQueueBrowserProfileWrites(t *testing.T) {
	g := newMacWorkspaceGuest(t, func(_ ssh.Channel, command string) (uint32, bool) {
		return 0, strings.Contains(command, "uname -s")
	})
	s := g.s
	s.macComponentsChecked = true
	if _, err := guestprofile.Create(s.profile, guestprofile.Options{Hostname: "TEST-PC", Username: "alex", BrowserUsername: "web"}); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(s.configPath)
	if err != nil {
		t.Fatal(err)
	}
	gate, err := cage.NewEgressGate(cfg)
	if err != nil {
		t.Fatal(err)
	}
	stop, err := cage.StartGateControl(s.configPath, s.instanceDir(), gate)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	var starts atomic.Int32
	c := &windowsBrowserClient{ctx: ctx, cancel: cancel, start: func(ctx context.Context) (*exec.Cmd, error) {
		starts.Add(1)
		return exec.CommandContext(ctx, "/bin/sh", "-c", "exit 0"), nil
	}}
	s.windowsBrowserControl = c
	defer c.close()
	if err := s.attachMacOSGuest(); err != nil || !s.ready || starts.Load() != 0 {
		t.Fatalf("healthy guest depends on browser queue: starts=%d ready=%t err=%v", starts.Load(), s.ready, err)
	}
	// A new guest connection still requires its profile before becoming ready,
	// and failure cannot authorize external traffic.
	s.ready = false
	attempt, end := context.WithTimeout(t.Context(), 500*time.Millisecond)
	defer end()
	if err := s.attachMacOSGuestContext(attempt); err == nil || s.ready || starts.Load() == 0 || gate.Status().Mode != cage.GateClosed {
		t.Fatalf("fresh attach bypassed readiness/gate: starts=%d ready=%t err=%v", starts.Load(), s.ready, err)
	}
}
