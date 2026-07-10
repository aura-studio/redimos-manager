//go:build !windows

package main

import (
	"os"
	"syscall"
)

// flockExclusive takes an exclusive advisory lock on f; with wait=false it
// fails immediately when another process holds the lock.
func flockExclusive(f *os.File, wait bool) error {
	how := syscall.LOCK_EX
	if !wait {
		how |= syscall.LOCK_NB
	}
	return syscall.Flock(int(f.Fd()), how)
}

func funlock(f *os.File) { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }
