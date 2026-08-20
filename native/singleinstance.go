package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// errInstanceHandoff reports a successful front-stage handoff: the new
// process asked the running manager to come to the front, and must exit
// quietly instead of booting.
var errInstanceHandoff = errors.New("handoff: signalled the running redimos-manager instance to the front; exiting")

// acquireInstanceLock takes the machine-wide single-instance lock
// (~/.redimos/manager.lock). Two live managers would fight over children —
// reapStalePort would kill the sibling's healthy child and both would race
// store.json — so the second instance gets a load error instead of a footgun.
// The returned *os.File (and with it the lock) is held for the process
// lifetime; the OS releases it on any kind of exit, including SIGKILL.
//
// When the lock is already held, the contender asks the holder to bring its
// window to the front (front-stage handoff — a second launch behaves like
// re-activating the running app). Only when that signal cannot be delivered
// (e.g. the holder is an older build with no control server) does it fall
// back to the old "close it first" load error.
func acquireInstanceLock() (*os.File, error) {
	path := filepath.Join(filepath.Dir(defaultStorePath()), "manager.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := flockExclusive(f, false); err != nil {
		_ = f.Close()
		if signalRunningInstance(path) == nil {
			return nil, errInstanceHandoff
		}
		return nil, fmt.Errorf("another redimos-manager instance is already running (close it first)")
	}
	// Publish pid + control port so the next contender can reach us. The
	// flock owns the file, so a plain rewrite is race-free.
	if err := f.Truncate(0); err == nil {
		_, _ = f.Seek(0, io.SeekStart)
		fmt.Fprintf(f, "%d\n%d\n", os.Getpid(), startControlServer())
	}
	return f, nil
}
