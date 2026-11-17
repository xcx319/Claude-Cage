package workbench

import (
	"bufio"
	"context"
	"net"
	"net/http"
	"path/filepath"
	"time"
)

// The trusted local window holds this connection for the lifetime of the
// native view. Account-lock and controller shutdown cancel the request.
func (s *Server) macOSNativeDesktop(w http.ResponseWriter, r *http.Request) {
	if s.macosGuest == nil || !s.hasTrustedView(r) || !s.localVMStorage() {
		http.NotFound(w, r)
		return
	}
	// Validate the WebSocket handshake and Origin before opening a guest view.
	ws, err := s.upgrade(w, r)
	if err != nil {
		return
	}
	defer ws.Close()
	var dial net.Dialer
	conn, err := dial.DialContext(r.Context(), "unix", filepath.Join(s.instanceDir(), "cage-native-desktop.sock"))
	if err != nil {
		_ = ws.WriteJSON(map[string]string{"error": "虚拟 Mac 运行器尚未启动"})
		return
	}
	defer conn.Close()
	stop := context.AfterFunc(r.Context(), func() { conn.Close() })
	defer stop()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil || line != "ready\n" {
		_ = ws.WriteJSON(map[string]string{"error": "完整桌面未能打开"})
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	if ws.WriteJSON(map[string]bool{"open": true}) != nil {
		return
	}
	done := make(chan struct{})
	go func() { var b [1]byte; _, _ = conn.Read(b[:]); close(done); ws.Close() }()
	for {
		if _, _, err := ws.ReadMessage(); err != nil {
			break
		}
	}
	conn.Close()
	<-done
}
