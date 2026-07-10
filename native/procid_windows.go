//go:build windows

package main

import (
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

var procQueryFullProcessImageNameW = modkernel32.NewProc("QueryFullProcessImageNameW")

const stillActive = 259 // STILL_ACTIVE (GetExitCodeProcess)

// procIdentity returns the (start-time-µs, short command name) identity of a
// live pid. The (pid, startUnixMicro) pair is unique across pid reuse; comm is
// the lowercased image basename without .exe (matches what spawn recorded).
// ok=false for dead pids and for process objects that merely linger because
// someone still holds a handle.
func procIdentity(pid int) (startUnixMicro int64, comm string, ok bool) {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return 0, "", false
	}
	defer syscall.CloseHandle(h)
	var code uint32
	if syscall.GetExitCodeProcess(h, &code) != nil || code != stillActive {
		return 0, "", false // exited (object pinned by an open handle somewhere)
	}
	var c, e, k, u syscall.Filetime
	if syscall.GetProcessTimes(h, &c, &e, &k, &u) != nil {
		return 0, "", false
	}
	// FILETIME is 100ns ticks since 1601-01-01; convert to unix microseconds.
	ft := int64(c.HighDateTime)<<32 | int64(uint32(c.LowDateTime))
	const epochDelta100ns = 116444736000000000
	start := (ft - epochDelta100ns) / 10

	buf := make([]uint16, 4096)
	n := uint32(len(buf))
	name := ""
	if r, _, _ := procQueryFullProcessImageNameW.Call(uintptr(h), 0,
		uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&n))); r != 0 {
		name = strings.TrimSuffix(strings.ToLower(filepath.Base(syscall.UTF16ToString(buf[:n]))), ".exe")
	}
	return start, name, true
}
