//go:build windows

package main

// Job-object child containment: the canonical Windows replacement for the
// missing "kill children when the manager dies" semantics.
//
// Per lifetime-bound instance (redimos children; NOT the detached Local
// DynamoDB, which the next session adopts):
//
//	job := CreateJobObjectW(nil, nil)                        // anonymous, NON-inheritable
//	SetInformationJobObject(job, JobObjectExtendedLimitInformation,
//	                        {LimitFlags: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE})
//	CreateProcess(..., CREATE_SUSPENDED, ...)                // via exec.Cmd SysProcAttr
//	AssignProcessToJobObject(job, child)
//	NtResumeProcess(child)                                   // undo CREATE_SUSPENDED
//
// Why this is airtight against manager crash/taskkill: KILL_ON_JOB_CLOSE
// "causes all processes associated with the job to terminate when the last
// handle to the job is closed" (winnt.h docs), and process termination — by
// ANY means, including TerminateProcess and unhandled crashes — closes all of
// the dying process's kernel handles ("Terminating a Process", MS docs). The
// manager holds the only handle (CreateJobObjectW with nil security attrs
// yields a non-inheritable handle, and Go's exec restricts inheritance to the
// std handles via PROC_THREAD_ATTRIBUTE_HANDLE_LIST), so the manager dying —
// gracefully or not — drops the job's handle count to zero and the KERNEL
// terminates every process still in the job.
//
// Why CREATE_SUSPENDED: children created by a job member join the job
// automatically, but only children created AFTER the member was assigned.
// Assign-after-Start leaves a window in which a fast child could spawn
// grandchildren outside the job. Starting suspended and assigning before the
// child's first instruction closes that window completely. Every postSpawn
// path MUST resume, or cmd.Wait() hangs the supervisor.
//
// Nested jobs are fine since Windows 8 (a process may be in several jobs), so
// this works even when the whole app was itself jobbed by an IDE or packaged-
// app host; on assign failure we degrade gracefully (child runs un-jailed, the
// registry reconcile still covers it at next boot).

import (
	"os/exec"
	"syscall"
	"unsafe"
)

var (
	procCreateJobObjectW         = modkernel32.NewProc("CreateJobObjectW")
	procSetInformationJobObject  = modkernel32.NewProc("SetInformationJobObject")
	procAssignProcessToJobObject = modkernel32.NewProc("AssignProcessToJobObject")
	procTerminateJobObject       = modkernel32.NewProc("TerminateJobObject")

	modntdll            = syscall.NewLazyDLL("ntdll.dll")
	procNtResumeProcess = modntdll.NewProc("NtResumeProcess")

	// Documented fallback for resuming when NtResumeProcess is unavailable:
	// walk the system thread snapshot and ResumeThread the child's threads.
	procThread32First = modkernel32.NewProc("Thread32First")
	procThread32Next  = modkernel32.NewProc("Thread32Next")
	procOpenThread    = modkernel32.NewProc("OpenThread")
	procResumeThread  = modkernel32.NewProc("ResumeThread")
)

const (
	processTerminate = 0x0001 // PROCESS_TERMINATE

	createSuspended = 0x00000004 // CREATE_SUSPENDED (processthreadsapi)

	jobObjectExtendedLimitInformation = 9          // JobObjectExtendedLimitInformation
	jobObjectLimitKillOnJobClose      = 0x00002000 // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE

	processSetQuota      = 0x0100 // PROCESS_SET_QUOTA      (AssignProcessToJobObject)
	processSuspendResume = 0x0800 // PROCESS_SUSPEND_RESUME (NtResumeProcess)

	threadSuspendResume = 0x0002 // THREAD_SUSPEND_RESUME
	th32csSnapThread    = 0x0004 // TH32CS_SNAPTHREAD
)

// jobBasicLimit mirrors JOBOBJECT_BASIC_LIMIT_INFORMATION (winnt.h). Go's
// natural alignment reproduces the MSVC layout exactly (64 bytes on 64-bit).
type jobBasicLimit struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

// jobExtendedLimit mirrors JOBOBJECT_EXTENDED_LIMIT_INFORMATION (winnt.h).
// IoInfo reuses the ioCounters struct from the procstats sampler.
type jobExtendedLimit struct {
	BasicLimitInformation jobBasicLimit
	IoInfo                ioCounters
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

// Compile-time layout assertions (either line fails to build if a size drifts).
var (
	_ [unsafe.Sizeof(jobBasicLimit{}) - 64]byte
	_ [64 - unsafe.Sizeof(jobBasicLimit{})]byte
	_ [unsafe.Sizeof(jobExtendedLimit{}) - 144]byte
	_ [144 - unsafe.Sizeof(jobExtendedLimit{})]byte
)

// preSpawn makes the child start SUSPENDED so postSpawn can jail it before its
// first instruction. syscall.StartProcess ORs SysProcAttr.CreationFlags into
// the CreateProcess flags, so this composes with Go's own flags.
func preSpawn(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.CreationFlags |= createSuspended
}

// postSpawn runs right after a successful cmd.Start(): create the instance's
// job on first use, assign the (still-suspended) child, resume it. EVERY path
// resumes — a child left suspended would hang cmd.Wait() and the supervisor.
// The job handle is deliberately kept open for the manager's lifetime: closing
// it is exactly what kills the tree. Detached children (Local DynamoDB) are
// resumed but never jailed — they must survive manager death for adoption.
//
// PID-reuse safety: exec.Cmd's os.Process holds an open handle to the child
// from Start() until Wait(), and Windows never recycles a PID while a handle
// to the process object is open, so OpenProcess(pid) here cannot land on a
// stranger.
func postSpawn(in *instance, cmd *exec.Cmd) {
	pid := cmd.Process.Pid
	defer resumeProcess(pid)
	in.mu.Lock()
	detached := in.detached
	job := in.job
	in.mu.Unlock()
	if detached {
		return
	}
	if job == 0 {
		j, err := newKillOnCloseJob()
		if err != nil {
			in.appendLog("[job object unavailable, child not kill-on-close jailed: " + err.Error() + "]")
			return
		}
		in.mu.Lock()
		in.job = j
		job = j
		in.mu.Unlock()
	}
	if err := assignPidToJob(job, pid); err != nil {
		in.appendLog("[job assign failed, child not kill-on-close jailed: " + err.Error() + "]")
	}
}

// newKillOnCloseJob creates an anonymous, non-inheritable job object whose
// members the kernel terminates as soon as the last handle to the job closes.
func newKillOnCloseJob() (uintptr, error) {
	h, _, callErr := procCreateJobObjectW.Call(0, 0) // nil SA => not inheritable
	if h == 0 {
		return 0, callErr
	}
	var info jobExtendedLimit
	info.BasicLimitInformation.LimitFlags = jobObjectLimitKillOnJobClose
	ok, _, callErr := procSetInformationJobObject.Call(
		h, jobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), unsafe.Sizeof(info))
	if ok == 0 {
		_ = syscall.CloseHandle(syscall.Handle(h))
		return 0, callErr
	}
	return h, nil
}

func assignPidToJob(job uintptr, pid int) error {
	h, err := syscall.OpenProcess(processSetQuota|processTerminate, false, uint32(pid))
	if err != nil {
		return err
	}
	defer syscall.CloseHandle(h)
	ok, _, callErr := procAssignProcessToJobObject.Call(job, uintptr(h))
	if ok == 0 {
		return callErr
	}
	return nil
}

// resumeProcess undoes CREATE_SUSPENDED. NtResumeProcess resumes every thread
// in one call; the documented fallback re-derives the thread list because Go's
// StartProcess has already closed the main thread handle by the time Start()
// returns.
func resumeProcess(pid int) {
	if procNtResumeProcess.Find() == nil {
		if h, err := syscall.OpenProcess(processSuspendResume, false, uint32(pid)); err == nil {
			_, _, _ = procNtResumeProcess.Call(uintptr(h)) // NTSTATUS; best-effort
			_ = syscall.CloseHandle(h)
			return
		}
	}
	resumeThreadsToolhelp(pid)
}

// threadEntry32 mirrors THREADENTRY32 (tlhelp32.h): 28 bytes, all 4-aligned.
type threadEntry32 struct {
	Size           uint32
	Usage          uint32
	ThreadID       uint32
	OwnerProcessID uint32
	BasePri        int32
	DeltaPri       int32
	Flags          uint32
}

var (
	_ [unsafe.Sizeof(threadEntry32{}) - 28]byte
	_ [28 - unsafe.Sizeof(threadEntry32{})]byte
)

func resumeThreadsToolhelp(pid int) {
	snap, err := syscall.CreateToolhelp32Snapshot(th32csSnapThread, 0)
	if err != nil {
		return
	}
	defer syscall.CloseHandle(snap)
	var te threadEntry32
	te.Size = uint32(unsafe.Sizeof(te))
	ok, _, _ := procThread32First.Call(uintptr(snap), uintptr(unsafe.Pointer(&te)))
	for ; ok != 0; ok, _, _ = procThread32Next.Call(uintptr(snap), uintptr(unsafe.Pointer(&te))) {
		if te.OwnerProcessID != uint32(pid) {
			continue
		}
		th, _, _ := procOpenThread.Call(threadSuspendResume, 0, uintptr(te.ThreadID))
		if th != 0 {
			_, _, _ = procResumeThread.Call(th) // drops suspend count by 1
			_ = syscall.CloseHandle(syscall.Handle(th))
		}
	}
}

// killInstanceTree is terminate()'s kill: TerminateJobObject takes down every
// process in the job — grandchildren included — falling back to a direct
// TerminateProcess when the instance never got a job (detached, or assign
// failed).
func killInstanceTree(in *instance, pid int) {
	in.mu.Lock()
	job := in.job
	in.mu.Unlock()
	if job != 0 {
		if ok, _, _ := procTerminateJobObject.Call(job, 1); ok != 0 {
			return
		}
	}
	killPid(pid)
}

// killChildTree kills a process for which no instance/job exists (registry
// reconcile of a dead session's orphan). No SIGTERM analog on Windows — a
// verified orphan is terminated directly.
func killChildTree(pid int) { killPid(pid) }

// killPid force-kills one specific pid whose identity the caller has already
// verified.
func killPid(pid int) {
	if pid <= 0 {
		return
	}
	h, err := syscall.OpenProcess(processTerminate, false, uint32(pid))
	if err != nil {
		return
	}
	_ = syscall.TerminateProcess(h, 1)
	_ = syscall.CloseHandle(h)
}
