//go:build !windows

package main

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// reapStalePort kills any process listening on `port` whose command line
// references `match` — i.e. one of our own children (a redimos binary or the
// DynamoDBLocal jar) launched in a prior session that outlived an ungraceful
// app exit and is still holding the port. Matching on our own path means it
// can't touch unrelated apps that happen to use the same port (e.g. a real
// Redis on 6379). Best-effort: any failure is ignored (the caller falls back
// to the normal spawn/supervisor path).
func reapStalePort(port int, match string, live map[int]bool) {
	if match == "" {
		return
	}
	out, err := exec.Command("lsof", "-nP", "-iTCP:"+strconv.Itoa(port), "-sTCP:LISTEN", "-t").Output()
	if err != nil {
		return
	}
	for _, line := range strings.Fields(string(out)) {
		pid, perr := strconv.Atoi(line)
		if perr != nil || pid <= 0 || live[pid] {
			continue // skip a child this session already manages
		}
		cmd, cerr := exec.Command("ps", "-o", "command=", "-p", line).Output()
		if cerr != nil || !strings.Contains(string(cmd), match) {
			continue // not ours — leave it alone
		}
		killChildTree(pid)
	}
}

// reapStartupOrphans is the LEGACY heuristic backstop behind reconcileOnBoot:
// it catches our orphans when the registry was lost or predates them. A
// candidate must clear three independent bars before it is killed:
//
//  1. PPID == 1 — on macOS this only proves "launchd child" (every GUI app
//     qualifies), so it merely scopes the scan to processes with no live
//     parent;
//  2. its command line references one of our managed absolute paths;
//  3. its ENVIRONMENT carries the REDIMOS_MANAGER_SESSION sentinel that
//     spawn() injects — which a user's own copy of the same binary (nohup'd
//     from a closed terminal, or a `tail -f` on a path under ours) never has.
//
// Bar 3 is what kills the false-positive class the audit demonstrated; orphans
// from builds too old to set the sentinel are healed lazily by reapStalePort at
// the next Start of their port instead. Runs once at boot, under the
// single-instance lock.
func (m *manager) reapStartupOrphans() {
	matches := m.managedPathMatches()
	live := m.livePids() // adopted children are parentless + tagged — never reap them
	out, err := exec.Command("ps", "-axo", "pid=,ppid=,command=").Output()
	if err != nil {
		return
	}
	self := os.Getpid()
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, e1 := strconv.Atoi(fields[0])
		ppid, e2 := strconv.Atoi(fields[1])
		if e1 != nil || e2 != nil || ppid != 1 || pid == self || live[pid] {
			continue // not parentless, us, or a child we manage (incl. adopted)
		}
		matched := false
		for _, mstr := range matches {
			if strings.Contains(line, mstr) {
				matched = true
				break
			}
		}
		if !matched {
			continue // not one of our managed binaries
		}
		if !hasManagerEnvMarker(pid) {
			continue // same path but not spawned by us — leave it alone
		}
		killChildTree(pid)
	}
}

// hasManagerEnvMarker reports whether pid's environment (the exec-time
// snapshot, readable for same-user processes) carries the sentinel spawn()
// injects into every child.
func hasManagerEnvMarker(pid int) bool {
	out, err := exec.Command("ps", "-E", "-ww", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	return err == nil && strings.Contains(string(out), "REDIMOS_MANAGER_SESSION=")
}
