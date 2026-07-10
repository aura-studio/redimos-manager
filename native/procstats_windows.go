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
	modkernel32              = syscall.NewLazyDLL("kernel32.dll")
	procGetProcessIoCounters = modkernel32.NewProc("GetProcessIoCounters")
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

// ioCounters mirrors IO_COUNTERS (winnt.h): cumulative I/O totals for a process.
type ioCounters struct {
	ReadOperationCount  uint64
	WriteOperationCount uint64
	OtherOperationCount uint64
	ReadTransferCount   uint64
	WriteTransferCount  uint64
	OtherTransferCount  uint64
}

// sampleProcess returns the accumulated CPU busy time (kernel+user), the current
// working-set size, and the cumulative disk I/O bytes (read+written) of pid. The
// caller turns two busy-time / disk samples into a CPU percentage / a byte rate.
func sampleProcess(pid int) (busy time.Duration, memBytes uint64, diskBytes uint64, err error) {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return 0, 0, 0, err
	}
	defer syscall.CloseHandle(h)

	var creation, exit, kernel, user syscall.Filetime
	if err := syscall.GetProcessTimes(h, &creation, &exit, &kernel, &user); err != nil {
		return 0, 0, 0, err
	}
	busy = time.Duration(kernel.Nanoseconds() + user.Nanoseconds())

	var pmc processMemoryCounters
	pmc.Cb = uint32(unsafe.Sizeof(pmc))
	r, _, callErr := procGetProcessMemoryInfo.Call(uintptr(h), uintptr(unsafe.Pointer(&pmc)), uintptr(pmc.Cb))
	if r == 0 {
		return busy, 0, 0, callErr
	}

	// Disk I/O is best-effort: a failure leaves diskBytes at 0 rather than erroring.
	var io ioCounters
	if r2, _, _ := procGetProcessIoCounters.Call(uintptr(h), uintptr(unsafe.Pointer(&io))); r2 != 0 {
		diskBytes = io.ReadTransferCount + io.WriteTransferCount
	}
	return busy, uint64(pmc.WorkingSetSize), diskBytes, nil
}
