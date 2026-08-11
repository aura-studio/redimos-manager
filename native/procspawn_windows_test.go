//go:build windows

package main

import (
	"os/exec"
	"syscall"
	"testing"
)

// The manager is a GUI (WIN32) process with no console of its own, so every
// console-subsystem child would pop a visible console window unless it is
// spawned with CREATE_NO_WINDOW. These tests pin the flag contract that keeps
// Windows builds windowless, and pin that the job-object suspension contract
// (CREATE_SUSPENDED) is preserved, not regressed, by the hiding change.

const (
	testCreateSuspended = 0x00000004 // CREATE_SUSPENDED
	testCreateNoWindow  = 0x08000000 // CREATE_NO_WINDOW
)

func TestHideWindowSetsFlag(t *testing.T) {
	cmd := exec.Command("docker")
	hideWindow(cmd)
	if cmd.SysProcAttr == nil {
		t.Fatal("hideWindow must initialise SysProcAttr")
	}
}

func TestHideWindowSetsHideWindow(t *testing.T) {
	cmd := exec.Command("docker")
	hideWindow(cmd)
	if !cmd.SysProcAttr.HideWindow {
		t.Error("hideWindow must set HideWindow = true")
	}
}

func TestHideWindowSetsCreateNoWindow(t *testing.T) {
	cmd := exec.Command("docker")
	hideWindow(cmd)
	if cmd.SysProcAttr.CreationFlags&testCreateNoWindow == 0 {
		t.Errorf("hideWindow must OR CREATE_NO_WINDOW (0x%08x); CreationFlags = 0x%08x",
			testCreateNoWindow, cmd.SysProcAttr.CreationFlags)
	}
}

func TestHideWindowNilSysProcAttr(t *testing.T) {
	cmd := exec.Command("docker")
	cmd.SysProcAttr = nil // explicit nil — must not panic
	hideWindow(cmd)
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.HideWindow {
		t.Error("hideWindow on nil SysProcAttr must initialise and set HideWindow")
	}
}

func TestHideWindowIdempotent(t *testing.T) {
	cmd := exec.Command("docker")
	hideWindow(cmd)
	first := cmd.SysProcAttr.CreationFlags
	hideWindow(cmd)
	if cmd.SysProcAttr.CreationFlags != first {
		t.Errorf("hideWindow must be idempotent: flags changed 0x%08x -> 0x%08x",
			first, cmd.SysProcAttr.CreationFlags)
	}
	if cmd.SysProcAttr.CreationFlags&testCreateNoWindow == 0 || !cmd.SysProcAttr.HideWindow {
		t.Error("after repeated hideWindow, CREATE_NO_WINDOW and HideWindow must stay set")
	}
}

func TestHideWindowPreservesExistingFlags(t *testing.T) {
	cmd := exec.Command("docker")
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: testCreateSuspended}
	hideWindow(cmd)
	if cmd.SysProcAttr.CreationFlags&testCreateSuspended == 0 {
		t.Error("hideWindow must preserve a pre-existing CREATE_SUSPENDED flag")
	}
	if cmd.SysProcAttr.CreationFlags&testCreateNoWindow == 0 {
		t.Error("hideWindow must still OR CREATE_NO_WINDOW on top of CREATE_SUSPENDED")
	}
}

func TestHideWindowDoesNotSetSuspended(t *testing.T) {
	cmd := exec.Command("docker")
	hideWindow(cmd)
	if cmd.SysProcAttr.CreationFlags&testCreateSuspended != 0 {
		t.Error("hideWindow alone must NOT set CREATE_SUSPENDED (that is preSpawn's job)")
	}
}

func TestPreSpawnSetsSuspended(t *testing.T) {
	cmd := exec.Command("docker")
	preSpawn(cmd)
	if cmd.SysProcAttr.CreationFlags&testCreateSuspended == 0 {
		t.Error("preSpawn must set CREATE_SUSPENDED (job-object containment contract)")
	}
}

func TestPreSpawnAlsoSetsNoWindow(t *testing.T) {
	cmd := exec.Command("docker")
	preSpawn(cmd)
	if cmd.SysProcAttr.CreationFlags&testCreateNoWindow == 0 {
		t.Error("preSpawn must also OR CREATE_NO_WINDOW so the long-lived child stays windowless")
	}
	if !cmd.SysProcAttr.HideWindow {
		t.Error("preSpawn must set HideWindow = true")
	}
}

func TestPreSpawnKeepsJobObjectContract(t *testing.T) {
	cmd := exec.Command("docker")
	preSpawn(cmd)
	flags := cmd.SysProcAttr.CreationFlags
	if flags&testCreateSuspended == 0 || flags&testCreateNoWindow == 0 {
		t.Errorf("preSpawn must set CREATE_SUSPENDED|CREATE_NO_WINDOW together; got 0x%08x", flags)
	}
}
