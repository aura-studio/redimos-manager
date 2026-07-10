//go:build windows

package main

// Windows implementations of the two heuristic reap layers (the registry
// reconcile is OS-neutral and preferred; these backstop registry loss):
//
//	port → pid    GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER), BOTH
//	              AF_INET and AF_INET6 — a Go listener on ":port" binds a
//	              dual-stack IPv6 socket that only shows in the v6 table.
//	pid → proof   QueryFullProcessImageNameW (exact exe path — sufficient for
//	              redimos binaries) and, when the exe is a shared host like
//	              java.exe, the command line read from the target's PEB
//	              (NtQueryInformationProcess + ReadProcessMemory) to match the
//	              DynamoDBLocal.jar path.
//	orphan test   Windows does NOT reparent to pid 1: th32ParentProcessID is a
//	              snapshot taken at creation, never rewritten when the parent
//	              dies. "Orphan" therefore means: recorded parent no longer
//	              exists, or has exited, or its pid was recycled by a YOUNGER
//	              process (a "parent" created after its "child" cannot be the
//	              real parent — compare GetProcessTimes creation stamps).
//
// Everything is best-effort like the darwin version: any failure skips the
// candidate, and a live process's children are never touched.

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

var (
	modiphlpapi             = syscall.NewLazyDLL("iphlpapi.dll")
	procGetExtendedTcpTable = modiphlpapi.NewProc("GetExtendedTcpTable")

	procReadProcessMemory         = modkernel32.NewProc("ReadProcessMemory")
	procNtQueryInformationProcess = modntdll.NewProc("NtQueryInformationProcess")
)

const (
	afInet  = 2  // AF_INET
	afInet6 = 23 // AF_INET6

	tcpTableOwnerPidListener = 3 // TCP_TABLE_OWNER_PID_LISTENER (iprtrmib.h enum order)
	mibTCPStateListen        = 2 // MIB_TCP_STATE_LISTEN

	errInsufficientBuffer = 122                // ERROR_INSUFFICIENT_BUFFER
	errInvalidParameter   = syscall.Errno(87) // ERROR_INVALID_PARAMETER

	processQueryInformation = 0x0400 // PROCESS_QUERY_INFORMATION (PEB read)
	processVMRead           = 0x0010 // PROCESS_VM_READ
)

// mibTCPRowOwnerPid mirrors MIB_TCPROW_OWNER_PID (tcpmib.h). dwState FIRST.
type mibTCPRowOwnerPid struct {
	State      uint32
	LocalAddr  uint32
	LocalPort  uint32 // network byte order in the low 16 bits
	RemoteAddr uint32
	RemotePort uint32
	OwningPid  uint32
}

// mibTCP6RowOwnerPid mirrors MIB_TCP6ROW_OWNER_PID (tcpmib.h).
// NOTE: field order differs from the IPv4 row — dwState is SEVENTH here.
type mibTCP6RowOwnerPid struct {
	LocalAddr     [16]byte
	LocalScopeID  uint32
	LocalPort     uint32
	RemoteAddr    [16]byte
	RemoteScopeID uint32
	RemotePort    uint32
	State         uint32
	OwningPid     uint32
}

var (
	_ [unsafe.Sizeof(mibTCPRowOwnerPid{}) - 24]byte
	_ [24 - unsafe.Sizeof(mibTCPRowOwnerPid{})]byte
	_ [unsafe.Sizeof(mibTCP6RowOwnerPid{}) - 56]byte
	_ [56 - unsafe.Sizeof(mibTCP6RowOwnerPid{})]byte
)

// ntohs16 converts a dwLocalPort DWORD (port in network byte order in the low
// word) to a host-order port number.
func ntohs16(v uint32) int { return int(v&0xFF)<<8 | int(v>>8&0xFF) }

// fetchTCPTable runs the standard size-probe loop for one address family and
// returns the raw table buffer (DWORD dwNumEntries, then packed rows).
func fetchTCPTable(family uintptr) []byte {
	var size uint32
	for range [4]int{} { // table can grow between probe and fetch; retry a little
		if size > 0 {
			buf := make([]byte, size)
			r, _, _ := procGetExtendedTcpTable.Call(uintptr(unsafe.Pointer(&buf[0])),
				uintptr(unsafe.Pointer(&size)), 0, family, tcpTableOwnerPidListener, 0)
			if r == 0 {
				return buf[:size]
			}
			if r != errInsufficientBuffer {
				return nil
			}
			continue
		}
		r, _, _ := procGetExtendedTcpTable.Call(0,
			uintptr(unsafe.Pointer(&size)), 0, family, tcpTableOwnerPidListener, 0)
		if r != errInsufficientBuffer || size == 0 {
			return nil
		}
	}
	return nil
}

// listenersOnPort returns the pids of every process with a LISTEN socket on
// port, across IPv4 and IPv6 (dual-stack Go listeners only appear in v6).
// Rows start at offset 4 in both families: every row field has 4-byte (or
// smaller) alignment, so MSVC does not pad after the leading dwNumEntries.
func listenersOnPort(port int) []int {
	var pids []int
	if buf := fetchTCPTable(afInet); len(buf) >= 4 {
		if n := *(*uint32)(unsafe.Pointer(&buf[0])); n > 0 && len(buf) >= 4+int(n)*int(unsafe.Sizeof(mibTCPRowOwnerPid{})) {
			rows := unsafe.Slice((*mibTCPRowOwnerPid)(unsafe.Pointer(&buf[4])), n)
			for i := range rows {
				if rows[i].State == mibTCPStateListen && ntohs16(rows[i].LocalPort) == port {
					pids = append(pids, int(rows[i].OwningPid))
				}
			}
		}
	}
	if buf := fetchTCPTable(afInet6); len(buf) >= 4 {
		if n := *(*uint32)(unsafe.Pointer(&buf[0])); n > 0 && len(buf) >= 4+int(n)*int(unsafe.Sizeof(mibTCP6RowOwnerPid{})) {
			rows := unsafe.Slice((*mibTCP6RowOwnerPid)(unsafe.Pointer(&buf[4])), n)
			for i := range rows {
				if rows[i].State == mibTCPStateListen && ntohs16(rows[i].LocalPort) == port {
					pids = append(pids, int(rows[i].OwningPid))
				}
			}
		}
	}
	return pids
}

// processImagePath returns the full executable path of pid ("" on failure).
func processImagePath(pid int) string {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return ""
	}
	defer syscall.CloseHandle(h)
	buf := make([]uint16, 4096)
	n := uint32(len(buf))
	ok, _, _ := procQueryFullProcessImageNameW.Call(uintptr(h), 0,
		uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&n)))
	if ok == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf[:n])
}

// processBasicInformation mirrors PROCESS_BASIC_INFORMATION (winternl.h).
type processBasicInformation struct {
	ExitStatus                   uintptr
	PebBaseAddress               uintptr
	AffinityMask                 uintptr
	BasePriority                 uintptr
	UniqueProcessID              uintptr
	InheritedFromUniqueProcessID uintptr
}

// processCommandLine reads the target's command line out of its PEB. 64-bit
// offsets (identical on amd64 and arm64): PEB+0x20 = ProcessParameters,
// RTL_USER_PROCESS_PARAMETERS+0x70 = CommandLine UNICODE_STRING. Best-effort:
// returns "" for 32-bit targets or protected processes.
func processCommandLine(pid int) string {
	h, err := syscall.OpenProcess(processQueryInformation|processVMRead, false, uint32(pid))
	if err != nil {
		return ""
	}
	defer syscall.CloseHandle(h)

	var pbi processBasicInformation
	st, _, _ := procNtQueryInformationProcess.Call(uintptr(h), 0, // ProcessBasicInformation
		uintptr(unsafe.Pointer(&pbi)), unsafe.Sizeof(pbi), 0)
	if st != 0 || pbi.PebBaseAddress == 0 {
		return ""
	}
	read := func(addr, dst, n uintptr) bool {
		var got uintptr
		ok, _, _ := procReadProcessMemory.Call(uintptr(h), addr, dst, n,
			uintptr(unsafe.Pointer(&got)))
		return ok != 0 && got == n
	}
	var params uintptr
	if !read(pbi.PebBaseAddress+0x20, uintptr(unsafe.Pointer(&params)), unsafe.Sizeof(params)) || params == 0 {
		return ""
	}
	var us struct { // UNICODE_STRING, 64-bit layout
		Length        uint16
		MaximumLength uint16
		_             uint32
		Buffer        uintptr
	}
	if !read(params+0x70, uintptr(unsafe.Pointer(&us)), unsafe.Sizeof(us)) || us.Buffer == 0 || us.Length == 0 || us.Length > 1<<15 {
		return ""
	}
	chars := make([]uint16, us.Length/2)
	if !read(us.Buffer, uintptr(unsafe.Pointer(&chars[0])), uintptr(us.Length)) {
		return ""
	}
	return syscall.UTF16ToString(chars)
}

func fileTime64(ft syscall.Filetime) uint64 {
	return uint64(ft.HighDateTime)<<32 | uint64(ft.LowDateTime)
}

// creationStamp returns the FILETIME creation stamp of pid.
func creationStamp(pid int) (uint64, bool) {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return 0, false
	}
	defer syscall.CloseHandle(h)
	var c, e, k, u syscall.Filetime
	if syscall.GetProcessTimes(h, &c, &e, &k, &u) != nil {
		return 0, false
	}
	return fileTime64(c), true
}

// parentIsDead decides whether the recorded ppid still refers to a LIVE, REAL
// parent. Three orphan cases: (1) ppid no longer exists; (2) the process
// object still exists (pinned by an open handle) but has exited; (3) the pid
// was recycled by a process CREATED AFTER the child — impossible for a real
// parent. Any other failure is treated as "parent alive" so we never kill a
// live process's child.
func parentIsDead(ppid int, childCreated uint64) bool {
	if ppid == 0 {
		return true
	}
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(ppid))
	if err != nil {
		return err == errInvalidParameter
	}
	defer syscall.CloseHandle(h)
	var code uint32
	if err := syscall.GetExitCodeProcess(h, &code); err == nil && code != stillActive {
		return true
	}
	var c, e, k, u syscall.Filetime
	if syscall.GetProcessTimes(h, &c, &e, &k, &u) != nil {
		return false
	}
	return fileTime64(c) > childCreated
}

func containsFold(haystack, needle string) bool { // Windows paths are case-insensitive
	return strings.Contains(strings.ToLower(haystack), strings.ToLower(needle))
}

// ownedBy reports whether pid provably belongs to one of our managed paths:
// exact image path for redimos binaries, PEB command line for the jar behind a
// shared java.exe.
func ownedBy(pid int, matches []string) bool {
	img := processImagePath(pid)
	for _, m := range matches {
		if m != "" && containsFold(img, m) {
			return true
		}
	}
	cl := processCommandLine(pid)
	if cl == "" {
		return false
	}
	for _, m := range matches {
		if m != "" && containsFold(cl, m) {
			return true
		}
	}
	return false
}

// reapStalePort kills whatever LISTENs on port if — and only if — its image
// path or command line contains our managed path.
func reapStalePort(port int, match string, live map[int]bool) {
	if match == "" {
		return
	}
	self := os.Getpid()
	for _, pid := range listenersOnPort(port) {
		if pid == 0 || pid == self || live[pid] {
			continue // skip a child this session already manages
		}
		if ownedBy(pid, []string{match}) {
			killPid(pid)
		}
	}
}

// reapStartupOrphans is the Windows heuristic backstop behind reconcileOnBoot:
// sweep the process snapshot for our managed binaries whose recorded parent is
// dead (see parentIsDead — Windows has no PPID reparenting). The exe-basename
// prefilter keeps OpenProcess calls to a handful of candidates.
func (m *manager) reapStartupOrphans() {
	matches := m.managedPathMatches()
	names := map[string]bool{}
	for _, mstr := range matches {
		if mstr == "" {
			continue
		}
		if strings.EqualFold(filepath.Ext(mstr), ".jar") {
			names["java.exe"] = true
		} else {
			names[strings.ToLower(filepath.Base(mstr))] = true
		}
	}
	live := m.livePids() // adopted children are parentless + tagged — never reap them
	snap, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return
	}
	defer syscall.CloseHandle(snap)
	self := uint32(os.Getpid())
	var pe syscall.ProcessEntry32
	pe.Size = uint32(unsafe.Sizeof(pe))
	for err = syscall.Process32First(snap, &pe); err == nil; err = syscall.Process32Next(snap, &pe) {
		pid := int(pe.ProcessID)
		if pe.ProcessID == 0 || pe.ProcessID == 4 || pe.ProcessID == self || pe.ParentProcessID == self || live[pid] {
			continue // idle/system, us, or a child we manage (incl. adopted)
		}
		if !names[strings.ToLower(syscall.UTF16ToString(pe.ExeFile[:]))] {
			continue
		}
		if !ownedBy(pid, matches) {
			continue // same exe name but not our managed path
		}
		created, ok := creationStamp(pid)
		if !ok {
			continue
		}
		if !parentIsDead(int(pe.ParentProcessID), created) {
			continue // its parent is alive — not an orphan
		}
		if !containsFold(processCommandLine(pid), "redimos.manager.session=") {
			// Bar analogous to darwin's env-sentinel gate: only a process we
			// spawned carries the session marker (java via -D; a user's own
			// DynamoDBLocal.jar does not). redimos.exe carries the marker only in
			// its env, not argv, so it isn't caught here — it's healed instead by
			// reapStalePort at the next Start of its port, exactly like darwin's
			// registry-less case. Prevents killing a user's own same-path process.
			continue
		}
		killPid(pid)
	}
}
