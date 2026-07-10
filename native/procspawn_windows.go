//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// Windows access right shared by the spawn/kill helpers.
const processTerminate = 0x0001 // PROCESS_TERMINATE

// preSpawn / postSpawn are the per-OS spawn hooks. The job-object containment
// (CREATE_SUSPENDED → AssignProcessToJobObject → resume) lands with the
// Windows hardening pass; until then these are inert.
func preSpawn(cmd *exec.Cmd)                {}
func postSpawn(in *instance, cmd *exec.Cmd) {}

// killChildTree on Windows terminates the direct child. Upgraded to job-wide
// termination (TerminateJobObject) by the job-object pass.
func killChildTree(pid int) { killPid(pid) }

// killPid force-kills one specific pid whose identity the caller has already
// verified.
func killPid(pid int) {
	if pid <= 0 {
		return
	}
	h, err := syscall.OpenProcess(processTerminate, false, uint32(pid))
	if err != nil {
		return
	}
	_ = syscall.TerminateProcess(h, 1)
	_ = syscall.CloseHandle(h)
}
