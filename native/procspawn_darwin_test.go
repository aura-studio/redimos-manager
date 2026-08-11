//go:build darwin

package main

import (
	"os/exec"
	"strings"
	"testing"
)

// On darwin there is no console-window problem, so hideWindow must be a strict
// no-op — these tests pin that the fix changed nothing for the macOS build.

func TestHideWindowNoopDarwin(t *testing.T) {
	cmd := exec.Command("docker")
	hideWindow(cmd) // must not panic
}

func TestHideWindowLeavesSysProcAttrNilDarwin(t *testing.T) {
	cmd := exec.Command("docker")
	hideWindow(cmd)
	if cmd.SysProcAttr != nil {
		t.Errorf("hideWindow on darwin must not touch SysProcAttr; got %+v", cmd.SysProcAttr)
	}
}

func TestPreSpawnDarwinUnchanged(t *testing.T) {
	cmd := exec.Command("docker")
	preSpawn(cmd)
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.Setpgid {
		t.Error("preSpawn on darwin must still set Setpgid (process-group containment)")
	}
	// SysProcAttr's HideWindow/CreationFlags fields are Windows-only and do not
	// exist in the darwin build, so there is nothing Windows-specific to assert
	// absent here; the Setpgid contract above is the darwin behaviour to pin.
}

// TestHideWindowPreservesStdoutCaptureDarwin proves the hiding change does not
// break stdout/stderr pipe capture on the darwin path (regression guard for
// Property 2). Requires a local docker; skips cleanly when absent.
func TestHideWindowPreservesStdoutCaptureDarwin(t *testing.T) {
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not available; stdout-capture is verified on the Windows smoke run")
	}
	cmd := exec.Command("docker", "version", "--format", "{{.Client.Version}}")
	hideWindow(cmd)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("docker version via hideWindow cmd failed: %v", err)
	}
	if strings.TrimSpace(string(out)) == "" {
		t.Error("stdout capture through a hideWindow'd cmd returned empty output")
	}
}
