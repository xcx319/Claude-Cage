//go:build darwin && arm64 && cgo && !no_vz

package maclogin

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestNativeDesktopRequiresCurrentControllerPeer(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "cd-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "socket")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	peer, err := listener.AcceptUnix()
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	record := filepath.Join(dir, "control.json")
	if desktopControllerPeer(peer, dir) {
		t.Fatal("missing controller accepted")
	}
	if err := os.WriteFile(record, []byte(fmt.Sprintf(`{"pid":%d}`, os.Getpid()+1)), 0600); err != nil {
		t.Fatal(err)
	}
	if desktopControllerPeer(peer, dir) {
		t.Fatal("wrong controller accepted")
	}
	if err := os.WriteFile(record, []byte(fmt.Sprintf(`{"pid":%d}`, os.Getpid())), 0600); err != nil {
		t.Fatal(err)
	}
	if !desktopControllerPeer(peer, dir) {
		t.Fatal("current controller rejected")
	}
}
