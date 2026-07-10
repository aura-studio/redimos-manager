//go:build darwin

package main

// Per-PID CPU / memory sampling via libproc's proc_pid_rusage. Mirrors the
// Windows implementation's interface (procstats_windows.go): accumulated busy
// time + resident size; the sampler turns two busy samples into a CPU %.

/*
#include <libproc.h>
#include <mach/mach_time.h>
*/
import "C"

import (
	"fmt"
	"sync"
	"time"
	"unsafe"
)

var (
	timebaseOnce sync.Once
	timebaseN    uint64 = 1
	timebaseD    uint64 = 1
)

// machToNanos converts mach absolute time units (what ri_user_time /
// ri_system_time are reported in) to nanoseconds. 1:1 on Intel; 125/3 on ARM.
func machToNanos(v uint64) uint64 {
	timebaseOnce.Do(func() {
		var tb C.struct_mach_timebase_info
		if C.mach_timebase_info(&tb) == 0 {
			timebaseN = uint64(tb.numer)
			timebaseD = uint64(tb.denom)
		}
	})
	return v * timebaseN / timebaseD
}

func sampleProcess(pid int) (busy time.Duration, memBytes uint64, diskBytes uint64, err error) {
	var ru C.struct_rusage_info_v2
	rc := C.proc_pid_rusage(C.int(pid), C.RUSAGE_INFO_V2, (*C.rusage_info_t)(unsafe.Pointer(&ru)))
	if rc != 0 {
		return 0, 0, 0, fmt.Errorf("proc_pid_rusage(%d) rc=%d", pid, rc)
	}
	busy = time.Duration(machToNanos(uint64(ru.ri_user_time) + uint64(ru.ri_system_time)))
	// Cumulative logical disk I/O (bytes read + written) since the process began.
	disk := uint64(ru.ri_diskio_bytesread) + uint64(ru.ri_diskio_byteswritten)
	return busy, uint64(ru.ri_resident_size), disk, nil
}
