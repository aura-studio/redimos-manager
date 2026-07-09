//go:build windows

package main

// Per-PID CPU / memory sampling via the Win32 API. Deliberately dependency-free
// (stdlib syscall + a lazy psapi.dll binding) so the c-shared DLL keeps building
// offline; docker children are sampled through `docker stats` instead (phase 4).

import (
	"syscall"
	"time"
	"unsafe"
)

var (
	modpsapi                 = syscall.NewLazyDLL("psapi.dll")
	procGetProcessMemoryInfo = modpsapi.NewProc("GetProcessMemoryInfo")
)

// processMemoryCounters mirrors PROCESS_MEMORY_COUNTERS (psapi.h).
type processMemoryCounters struct {
	Cb                         uint32
	PageFaultCount             uint32
	PeakWorkingSetSize         uintptr
	WorkingSetSize             uintptr
	QuotaPeakPagedPoolUsage    uintptr
	QuotaPagedPoolUsage        uintptr
	QuotaPeakNonPagedPoolUsage uintptr
	QuotaNonPagedPoolUsage     uintptr
	PagefileUsage              uintptr
	PeakPagefileUsage          uintptr
}

const processQueryLimitedInformation = 0x1000

// sampleProcess returns the accumulated CPU busy time (kernel+user) and the
// current working-set size of pid. The caller turns two busy-time samples into
// a CPU percentage.
func sampleProcess(pid int) (busy time.Duration, memBytes uint64, err error) {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return 0, 0, err
	}
	defer syscall.CloseHandle(h)

	var creation, exit, kernel, user syscall.Filetime
	if err := syscall.GetProcessTimes(h, &creation, &exit, &kernel, &user); err != nil {
		return 0, 0, err
	}
	busy = time.Duration(kernel.Nanoseconds() + user.Nanoseconds())

	var pmc processMemoryCounters
	pmc.Cb = uint32(unsafe.Sizeof(pmc))
	r, _, callErr := procGetProcessMemoryInfo.Call(uintptr(h), uintptr(unsafe.Pointer(&pmc)), uintptr(pmc.Cb))
	if r == 0 {
		return busy, 0, callErr
	}
	return busy, uint64(pmc.WorkingSetSize), nil
}
