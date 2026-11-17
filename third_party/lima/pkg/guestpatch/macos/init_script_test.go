package macos

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestInitWaitsForExecutableAfterMountDirectoryAppears(t *testing.T) {
	dir := t.TempDir()
	agent := filepath.Join(dir, "lima-guestagent")
	if err := os.WriteFile(agent, []byte("#!/bin/sh\nprintf 'boot-agent-ready'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	script := strings.ReplaceAll(initScript, "/Volumes/cidata/lima-guestagent", agent)
	ctx, cancel := context.WithTimeout(t.Context(), 4*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", script)
	go func() {
		time.Sleep(150 * time.Millisecond)
		_ = os.Chmod(agent, 0700)
	}()
	output, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(output), "boot-agent-ready") {
		t.Fatalf("did not wait for media: %v, %s", err, output)
	}
}

func TestInitFailsClosedWhenGuestAgentNeverAppears(t *testing.T) {
	script := strings.ReplaceAll(initScript, "/Volumes/cidata/lima-guestagent", filepath.Join(t.TempDir(), "missing"))
	script = strings.ReplaceAll(script, `-ge 60`, `-ge 1`)
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "/bin/sh", "-c", script).CombinedOutput()
	if err == nil || !strings.Contains(string(output), "guest agent did not become ready") {
		t.Fatalf("missing media accepted: %v, %s", err, output)
	}
}
