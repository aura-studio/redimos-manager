package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// acquireInstanceLock takes the machine-wide single-instance lock
// (~/.redimos/manager.lock). Two live managers would fight over children —
// reapStalePort would kill the sibling's healthy child and both would race
// store.json — so the second instance gets a load error instead of a footgun.
// The returned *os.File (and with it the lock) is held for the process
// lifetime; the OS releases it on any kind of exit, including SIGKILL.
func acquireInstanceLock() (*os.File, error) {
	path := filepath.Join(filepath.Dir(defaultStorePath()), "manager.lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := flockExclusive(f, false); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("another redimos-manager instance is already running (close it first)")
	}
	return f, nil
}
