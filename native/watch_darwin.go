//go:build darwin

package main

/*
#include <sys/event.h>
#include <unistd.h>
*/
import "C"

import (
	"fmt"
	"time"
)

// watchProcessExit invokes fn exactly once when pid exits — the adopted-child
// replacement for cmd.Wait(), which only works on your own children. kqueue
// EVFILT_PROC NOTE_EXIT works for same-uid non-children and in practice
// delivers the full wait status in `data` (the man page only guarantees
// NOTE_EXITSTATUS for children, so a zero status is reported as a clean exit
// rather than trusted blindly). Falls back to 2s identity polling if kqueue
// registration fails. startMicro re-verifies identity after registration to
// close the adopt→watch pid-reuse window.
func watchProcessExit(pid int, startMicro int64, fn func(error)) {
	go func() {
		kq := C.kqueue()
		if kq >= 0 {
			defer C.close(kq)
			var kev C.struct_kevent
			kev.ident = C.uintptr_t(pid)
			kev.filter = C.EVFILT_PROC
			kev.flags = C.EV_ADD | C.EV_ONESHOT
			kev.fflags = C.NOTE_EXIT | C.NOTE_EXITSTATUS
			if C.kevent(kq, &kev, 1, nil, 0, nil) == 0 {
				// Registered. Re-verify we watched the right process: it could
				// have died (and its pid been recycled) between the adoption
				// check and this registration.
				if s, _, ok := procIdentity(pid); !ok || s != startMicro {
					fn(fmt.Errorf("adopted process exited before the watch attached"))
					return
				}
				var out C.struct_kevent
				if C.kevent(kq, nil, 0, &out, 1, nil) == 1 {
					fn(waitStatusToErr(int(out.data)))
					return
				}
			}
		}
		// Fallback: poll the identity until it stops matching.
		for {
			time.Sleep(2 * time.Second)
			if s, _, ok := procIdentity(pid); !ok || s != startMicro {
				fn(fmt.Errorf("process exited (adopted; exit status unknown)"))
				return
			}
		}
	}()
}

// waitStatusToErr mirrors what cmd.Wait would have produced from a raw wait
// status: nil for a clean exit, an error naming the code or signal otherwise.
func waitStatusToErr(status int) error {
	if status == 0 {
		return nil
	}
	if status&0x7f == 0 {
		return fmt.Errorf("exit status %d", status>>8)
	}
	return fmt.Errorf("signal: %d", status&0x7f)
}
