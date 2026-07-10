//go:build darwin

package main

import (
	"os/exec"
	"syscall"
	"time"
)

// preSpawn configures OS-level child attributes before Start(). On darwin every
// child gets its own process group so that (a) killChildTree can take down any
// subtree the payload forks, and (b) terminal signals aimed at the manager's
// own group (e.g. Ctrl-C under `flutter run`) no longer hit the children behind
// the supervisor's back.
func preSpawn(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
}

// postSpawn runs right after a successful Start(). Nothing to do on darwin —
// the process group was created by the kernel as part of the fork.
func postSpawn(in *instance, cmd *exec.Cmd) {}

// killChildTree stops a native child and everything it forked: SIGTERM to the
// process group (each child is its own group leader, pgid == pid — see
// preSpawn), a short grace so clean shutdown paths can run (java flushing
// persist files, redimos closing listeners), then SIGKILL. Falls back to
// pid-targeted signals for a process that is not a group leader.
func killChildTree(pid int) {
	if pid <= 0 {
		return
	}
	target := -pid // negative pid == the whole process group
	if err := syscall.Kill(target, syscall.SIGTERM); err != nil {
		target = pid
		if err := syscall.Kill(target, syscall.SIGTERM); err != nil {
			return // already gone
		}
	}
	deadline := time.Now().Add(1200 * time.Millisecond)
	for time.Now().Before(deadline) {
		if syscall.Kill(target, 0) != nil {
			return // group/process fully gone
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = syscall.Kill(target, syscall.SIGKILL)
}

// killInstanceTree is terminate()'s kill; on darwin the child's own process
// group is the tree handle, no per-instance state needed.
func killInstanceTree(in *instance, pid int) { killChildTree(pid) }

// killPid force-kills one specific pid whose identity the caller has already
// verified (registry / cmdline match).
func killPid(pid int) {
	if pid > 0 {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
}
