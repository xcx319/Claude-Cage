//go:build !windows

package workbench

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/sylvinus/agent-vm/internal/guestos"
)

func TestNativeDesktopRequiresTrustedUnlockedViewAndClosesOnLock(t *testing.T) {
	s := testServer(t)
	dir, err := os.MkdirTemp("/tmp", "cage-desktop-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	s.profile = dir
	s.macosGuest = &guestos.MacOSProfile{Instance: "mac", User: "test"}
	if err := os.MkdirAll(s.instanceDir(), 0700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(s.instanceDir(), "cage-native-desktop.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	closed := make(chan struct{})
	accepted := make(chan struct{}, 1)
	go func() {
		c, e := listener.Accept()
		if e != nil {
			return
		}
		defer c.Close()
		accepted <- struct{}{}
		_, _ = c.Write([]byte("ready\n"))
		_, _ = io.Copy(io.Discard, c)
		close(closed)
	}()
	server := httptest.NewUnstartedServer(s.handler())
	server.Start()
	defer server.Close()
	s.origin = server.URL
	headers := http.Header{"Origin": {s.origin}, "Cookie": {s.cookieName() + "=" + s.session}}
	url := "ws" + strings.TrimPrefix(server.URL, "http") + "/api/macos/native-desktop"
	if c, response, err := websocket.DefaultDialer.Dial(url, headers); err == nil {
		c.Close()
		t.Fatal("untrusted view accepted")
	} else if response == nil || response.StatusCode != http.StatusForbidden {
		t.Fatalf("unexpected rejection: %v", err)
	}
	headers.Set("Cookie", s.cookieName()+"="+s.session+"; "+s.cookieName()+"-desktop="+trustedViewProof(s.token))
	headers.Set("Origin", "https://invalid.example")
	if c, _, err := websocket.DefaultDialer.Dial(url, headers); err == nil {
		c.Close()
		t.Fatal("cross-origin view accepted")
	}
	select {
	case <-accepted:
		t.Fatal("cross-origin request opened native view")
	default:
	}
	headers.Set("Origin", s.origin)
	c, response, err := websocket.DefaultDialer.Dial(url, headers)
	if err != nil {
		if response != nil {
			t.Fatalf("handshake %d: %v", response.StatusCode, err)
		}
		t.Fatal(err)
	}
	defer c.Close()
	if _, _, err := c.ReadMessage(); err != nil {
		t.Fatal(err)
	}
	s.account.lock()
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("account lock did not close desktop lease")
	}
}
