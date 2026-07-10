//go:build windows

package main

// No janitor on Windows: the job object with KILL_ON_JOB_CLOSE is the
// (stronger, kernel-side) lifetime binding there.
func startJanitor()                                            {}
func janitorRegister(detached bool, pid int, bin, cont string) {}
func janitorUnregister(pid int, container string)              {}
func janitorClose()                                            {}
