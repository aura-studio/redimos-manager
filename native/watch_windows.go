//go:build windows

package main

import (
	"fmt"
	"syscall"
)

const synchronize = 0x00100000 // SYNCHRONIZE (WaitForSingleObject)

// watchProcessExit invokes fn exactly once when pid exits — the adopted-child
// replacement for cmd.Wait(). On Windows a non-child process handle supports a
// real blocking wait plus the true exit code, so adoption is first-class.
// startMicro re-verifies identity after the handle is open (holding the handle
// then pins the pid against reuse).
func watchProcessExit(pid int, startMicro int64, fn func(error)) {
	go func() {
		h, err := syscall.OpenProcess(synchronize|processQueryLimitedInformation, false, uint32(pid))
		if err != nil {
			fn(fmt.Errorf("adopted process exited before the watch attached"))
			return
		}
		defer syscall.CloseHandle(h)
		if s, _, ok := procIdentity(pid); !ok || s != startMicro {
			fn(fmt.Errorf("adopted process exited before the watch attached"))
			return
		}
		if _, werr := syscall.WaitForSingleObject(h, syscall.INFINITE); werr != nil {
			fn(fmt.Errorf("process exited (adopted; exit status unknown)"))
			return
		}
		var code uint32
		if syscall.GetExitCodeProcess(h, &code) == nil && code != 0 {
			fn(fmt.Errorf("exit status %d", code))
			return
		}
		fn(nil)
	}()
}
