//go:build darwin

// SPDX-License-Identifier: Apache-2.0

package macos

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Execute the production shell control flow with a synthetic sleep command.
// The fixture advances media readiness after N polls without a 60-second test.
func TestInitWaitsForExecutableMediaAndPreservesExecResult(t *testing.T) {
	for _, tc := range []struct {
		name, initial                        string
		after, agentExit, wantWait, wantExit int
	}{
		{"already executable", "ready", 0, 0, 0, 0},
		{"file appears after mount directory", "missing", 3, 0, 3, 0},
		{"file becomes executable", "nonexec", 2, 0, 2, 0},
		{"file never appears", "missing", 0, 0, 60, 1},
		{"file never becomes executable", "nonexec", 0, 0, 60, 1},
		{"directory is not an executable file", "directory", 0, 0, 60, 1},
		{"agent failure is not retried", "ready", 0, 37, 0, 37},
		{"late agent failure is not retried", "missing", 1, 37, 1, 37},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			bin := filepath.Join(dir, "bin")
			media := filepath.Join(dir, "volume with spaces")
			if err := os.MkdirAll(bin, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(media, 0700); err != nil {
				t.Fatal(err)
			}
			agent := filepath.Join(media, "lima-guestagent")
			count := filepath.Join(dir, "polls")
			ran := filepath.Join(dir, "ran")
			template := filepath.Join(dir, "template")
			body := []byte("#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$CAGE_CIDATA_TEST_RAN\"\nexit " + strconv.Itoa(tc.agentExit) + "\n")
			if err := os.WriteFile(template, body, 0700); err != nil {
				t.Fatal(err)
			}
			switch tc.initial {
			case "ready", "nonexec":
				mode := os.FileMode(0700)
				if tc.initial == "nonexec" {
					mode = 0600
				}
				if err := os.WriteFile(agent, body, mode); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Mkdir(agent, 0700); err != nil {
					t.Fatal(err)
				}
			}
			sleep := `#!/bin/sh
set -eu
[ "$1" = 1 ]
n=0
if [ -f "$CAGE_CIDATA_TEST_COUNT" ]; then n=$(cat "$CAGE_CIDATA_TEST_COUNT"); fi
n=$((n + 1))
printf '%s' "$n" > "$CAGE_CIDATA_TEST_COUNT"
if [ "$CAGE_CIDATA_TEST_AFTER" -gt 0 ] && [ "$n" -eq "$CAGE_CIDATA_TEST_AFTER" ]; then
  /bin/cp "$CAGE_CIDATA_TEST_TEMPLATE" "$CAGE_CIDATA_TEST_AGENT"
  /bin/chmod 700 "$CAGE_CIDATA_TEST_AGENT"
fi
`
			if err := os.WriteFile(filepath.Join(bin, "sleep"), []byte(sleep), 0700); err != nil {
				t.Fatal(err)
			}
			script := strings.ReplaceAll(initScript, "/Volumes/cidata/lima-guestagent", "'"+strings.ReplaceAll(agent, "'", "'\"'\"'")+"'")
			ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "/bin/sh", "-c", script)
			cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"), "CAGE_CIDATA_TEST_COUNT="+count, "CAGE_CIDATA_TEST_RAN="+ran, "CAGE_CIDATA_TEST_AFTER="+strconv.Itoa(tc.after), "CAGE_CIDATA_TEST_AGENT="+agent, "CAGE_CIDATA_TEST_TEMPLATE="+template)
			output, err := cmd.CombinedOutput()
			if ctx.Err() != nil {
				t.Fatal("init did not terminate within the test deadline")
			}
			code := 0
			if err != nil {
				if e, ok := err.(*exec.ExitError); ok {
					code = e.ExitCode()
				} else {
					t.Fatal(err)
				}
			}
			if code != tc.wantExit {
				t.Fatalf("exit=%d want=%d: %s", code, tc.wantExit, output)
			}
			polls := 0
			if b, e := os.ReadFile(count); e == nil {
				polls, _ = strconv.Atoi(string(b))
			}
			if polls != tc.wantWait {
				t.Fatalf("polls=%d want=%d", polls, tc.wantWait)
			}
			b, e := os.ReadFile(ran)
			if tc.wantExit == 1 {
				if e == nil {
					t.Fatal("unready agent was executed")
				}
				if !strings.Contains(string(output), "did not become executable") {
					t.Fatal("missing timeout diagnostic")
				}
			} else if e != nil || string(b) != "fake-cloud-init\n" {
				t.Fatalf("agent arguments or execution count changed: %q %v", b, e)
			}
		})
	}
}
