//go:build windows

package main

import (
	"os"
	"syscall"
	"unsafe"
)

var (
	procLockFileEx   = modkernel32.NewProc("LockFileEx")
	procUnlockFileEx = modkernel32.NewProc("UnlockFileEx")
)

const (
	lockfileExclusiveLock   = 0x2
	lockfileFailImmediately = 0x1
)

// flockExclusive takes an exclusive lock on the first byte of f; with
// wait=false it fails immediately when another process holds the lock.
// LockFileEx locks are released automatically when the handle closes or the
// process dies — same lifetime semantics as BSD flock.
func flockExclusive(f *os.File, wait bool) error {
	flags := uintptr(lockfileExclusiveLock)
	if !wait {
		flags |= lockfileFailImmediately
	}
	var ov syscall.Overlapped
	r, _, err := procLockFileEx.Call(f.Fd(), flags, 0, 1, 0, uintptr(unsafe.Pointer(&ov)))
	if r == 0 {
		return err
	}
	return nil
}

func funlock(f *os.File) {
	var ov syscall.Overlapped
	_, _, _ = procUnlockFileEx.Call(f.Fd(), 0, 1, 0, uintptr(unsafe.Pointer(&ov)))
}
