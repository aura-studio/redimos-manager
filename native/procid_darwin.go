//go:build darwin

package main

/*
#include <libproc.h>
#include <sys/proc.h>
*/
import "C"

import "unsafe"

// procIdentity returns the (start-time-µs, short command name) identity of a
// live pid. The (pid, startUnixMicro) pair is unique across pid reuse — a
// recycled pid can't reproduce the original start microsecond — and comm is a
// free extra guard (a re-exec keeps pid+start but changes comm). ok=false for
// dead pids and zombies.
func procIdentity(pid int) (startUnixMicro int64, comm string, ok bool) {
	var ti C.struct_proc_bsdinfo
	n := C.proc_pidinfo(C.int(pid), C.PROC_PIDTBSDINFO, 0, unsafe.Pointer(&ti), C.int(unsafe.Sizeof(ti)))
	if int(n) < int(unsafe.Sizeof(ti)) {
		return 0, "", false
	}
	if ti.pbi_status == C.SZOMB {
		return 0, "", false // exited, merely unreaped — not a live child
	}
	start := int64(ti.pbi_start_tvsec)*1_000_000 + int64(ti.pbi_start_tvusec)
	return start, C.GoString(&ti.pbi_comm[0]), true
}
