//go:build windows

package main

import (
	"os"
	"syscall"
	"unsafe"
)

var moduser32 = syscall.NewLazyDLL("user32.dll")

var (
	procEnumWindows           = moduser32.NewProc("EnumWindows")
	procGetWindowThreadProcID = moduser32.NewProc("GetWindowThreadProcessId")
	procIsWindowVisible       = moduser32.NewProc("IsWindowVisible")
	procShowWindow            = moduser32.NewProc("ShowWindow")
	procSetForegroundWindow   = moduser32.NewProc("SetForegroundWindow")
)

const swRestore = 9

// platformActivate brings this manager's own window to the front: find this
// process's visible top-level window, restore it if minimised, and give it
// the foreground. Runs inside the lock HOLDER's process, so "self" is the
// running manager.
func platformActivate() {
	pid := uint32(os.Getpid())
	cb := syscall.NewCallback(func(hwnd, lParam uintptr) uintptr {
		var wp uint32
		_, _, _ = procGetWindowThreadProcID.Call(hwnd, uintptr(unsafe.Pointer(&wp)))
		if wp != pid {
			return 1 // keep enumerating
		}
		visible, _, _ := procIsWindowVisible.Call(hwnd)
		if visible == 0 {
			return 1
		}
		_, _, _ = procShowWindow.Call(hwnd, swRestore)
		_, _, _ = procSetForegroundWindow.Call(hwnd)
		return 0 // found ours; stop
	})
	_, _, _ = procEnumWindows.Call(cb, 0)
}
