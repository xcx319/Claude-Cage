package workbench

import (
	"context"
	"errors"
	"time"

	"github.com/sylvinus/agent-vm/internal/guestprofile"
)

func (s *Server) syncNativeBrowserProfile(ctx context.Context) error {
	p, err := guestprofile.Load(s.profile)
	if err != nil || p == nil {
		return err
	}
	input := map[string]any{"browser_width": p.BrowserWidth, "browser_height": p.BrowserHeight, "webgl": p.WebGL, "canvas": p.Canvas}
	if p.GraphicsBackend != "" {
		input["graphics_backend"] = p.GraphicsBackend
	}
	// SSH can be ready before the GUI LaunchAgent has created its socket.
	// Applying the same profile is idempotent; wait within the caller's budget
	// (and never beyond 30s), without retrying a rejection or an input action.
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for {
		_, err = s.nativeBrowserClient().request(ctx, "POST", "/profile", input)
		if !errors.Is(err, errNativeBrowserDisconnected) {
			return err
		}
		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
