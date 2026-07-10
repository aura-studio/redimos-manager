//go:build darwin

package main

/*
#include <dlfcn.h>

// Anchor for dladdr: resolves to THIS dylib's on-disk path, wherever the host
// app put it (Contents/MacOS in the bundle, native/ in dev harnesses).
static const char* rm_dylib_path(void) {
	Dl_info info;
	if (dladdr((void*)&rm_dylib_path, &info) == 0) return 0;
	return info.dli_fname;
}
*/
import "C"

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The macOS lifetime-binding layer: a lifeline pipe to the rm-janitor helper
// (see native/janitor). The write end lives ONLY in this process; when the
// manager dies — Cmd-Q, SIGKILL, crash — the kernel closes it, the janitor
// sees EOF and reaps every registered lifetime-bound child. Complements, not
// replaces, the registry reconcile (which covers janitor+manager dying
// together) and the graceful rm_shutdown path (after which the janitor's EOF
// pass is a no-op).
type janitorLink struct {
	mu      sync.Mutex
	w       *os.File  // lifeline + control (janitor stdin)
	cmd     *exec.Cmd // the running janitor
	entries []string  // live registrations, replayed on janitor respawn
	closing bool      // set by janitorClose on graceful quit — stops respawns
	started time.Time // last spawn time, for respawn-storm backoff
	strikes int       // consecutive fast deaths
}

var janitor janitorLink

// dylibDir returns the directory holding this dylib (via dladdr), "" unknown.
func dylibDir() string {
	p := C.rm_dylib_path()
	if p == nil {
		return ""
	}
	return filepath.Dir(C.GoString(p))
}

// janitorBinary locates the rm-janitor helper next to the dylib or the host
// executable ("" when absent — layers 1-3 still cover, just without the
// SIGKILL-proof prevention).
func janitorBinary() string {
	var cands []string
	if d := dylibDir(); d != "" {
		cands = append(cands, filepath.Join(d, "rm-janitor"))
	}
	if exe, err := os.Executable(); err == nil {
		cands = append(cands, filepath.Join(filepath.Dir(exe), "rm-janitor"))
	}
	for _, c := range cands {
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
			return c
		}
	}
	return ""
}

// startJanitor launches the helper and hands it the lifeline. Called once at
// boot (lock-holding sessions only) and again whenever the janitor dies.
func startJanitor() {
	janitor.mu.Lock()
	defer janitor.mu.Unlock()
	janitor.startLocked()
}

func (j *janitorLink) startLocked() {
	bin := janitorBinary()
	if bin == "" || j.closing || j.cmd != nil {
		return
	}
	r, w, err := os.Pipe()
	if err != nil {
		return
	}
	cmd := exec.Command(bin)
	cmd.Stdin = r
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // survive group-kills aimed at us
	if err := cmd.Start(); err != nil {
		_ = r.Close()
		_ = w.Close()
		return
	}
	_ = r.Close() // the janitor's dup keeps the read end alive
	j.w, j.cmd, j.started = w, cmd, time.Now()
	// Replay live registrations (fresh boot: none; respawn: current children).
	for _, line := range j.entries {
		_, _ = fmt.Fprintln(w, line)
	}
	go func() {
		_ = cmd.Wait()
		j.mu.Lock()
		defer j.mu.Unlock()
		if j.cmd != cmd {
			return
		}
		if j.w != nil {
			_ = j.w.Close()
		}
		j.w, j.cmd = nil, nil
		if j.closing {
			return
		}
		// Respawn, but back off (and eventually give up) on a crash-loop so a
		// broken janitor binary can't become a fork/exec storm for the app's
		// whole lifetime.
		if time.Since(j.started) < 3*time.Second {
			j.strikes++
		} else {
			j.strikes = 0
		}
		if j.strikes >= 5 {
			return // give up — the boot sweeps / job objects are the backstop
		}
		delay := time.Duration(j.strikes) * time.Second
		time.AfterFunc(delay, startJanitor)
	}()
}

// janitorClose stops the janitor for good on a graceful quit: it disarms the
// respawn loop and closes the lifeline write end, which the janitor sees as EOF
// (by then rm_shutdown has already killed the children, so its reap pass is an
// idempotent no-op). Called from rm_shutdown.
func janitorClose() {
	janitor.mu.Lock()
	defer janitor.mu.Unlock()
	janitor.closing = true
	if janitor.w != nil {
		_ = janitor.w.Close()
		janitor.w = nil
	}
}

func (j *janitorLink) send(line string) {
	if j.w != nil {
		_, _ = fmt.Fprintln(j.w, line)
	}
}

// janitorRegister tracks a freshly spawned lifetime-bound child. Detached
// children (Local DynamoDB) are deliberately NOT registered — they survive
// manager death for adoption by the next session.
func janitorRegister(detached bool, pid int, bin, container string) {
	if detached {
		return
	}
	var line string
	if container != "" {
		line = fmt.Sprintf("CTR %s %s", bin, container)
	} else {
		line = fmt.Sprintf("PGID %d %s", pid, bin)
	}
	janitor.mu.Lock()
	defer janitor.mu.Unlock()
	janitor.entries = append(janitor.entries, line)
	janitor.send(line)
}

// janitorUnregister forgets a child that reached a terminal state through the
// supervisor (stopped / error / failed): nothing left for the EOF pass.
func janitorUnregister(pid int, container string) {
	var unreg, prefix string
	if container != "" {
		unreg = fmt.Sprintf("UNREG CTR %s", container)
		prefix = "CTR "
	} else {
		unreg = fmt.Sprintf("UNREG PGID %d", pid)
		prefix = fmt.Sprintf("PGID %d ", pid)
	}
	janitor.mu.Lock()
	defer janitor.mu.Unlock()
	kept := janitor.entries[:0]
	for _, e := range janitor.entries {
		if container != "" && strings.HasPrefix(e, prefix) && strings.HasSuffix(e, " "+container) {
			continue
		}
		if container == "" && strings.HasPrefix(e, prefix) {
			continue
		}
		kept = append(kept, e)
	}
	janitor.entries = kept
	janitor.send(unreg)
}
