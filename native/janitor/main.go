// rm-janitor is the manager's lifeline watchdog on macOS: a tiny helper that
// guarantees lifetime-bound children die when the manager dies — HOWEVER the
// manager dies, SIGKILL and crashes included.
//
// Mechanism: the manager keeps the write end of a pipe; the janitor's stdin is
// the read end. Kernel fd teardown closes the write end unconditionally on
// process exit (no signal handler or atexit involved), so the janitor's
// blocking read returns EOF milliseconds after the manager is gone — the only
// prevention primitive that is simultaneously SIGKILL-proof, race-free
// (level-triggered state, not a missable event) and payload-cooperation-free.
//
// Protocol (newline-framed lines on stdin):
//
//	PGID <pgid> <matchPath>       track a native child's process group
//	CTR <dockerPath> <name>       track a docker container by name
//	UNREG PGID <pgid>             child stopped cleanly, forget it
//	UNREG CTR <name>              container removed cleanly, forget it
//
// On EOF: for every tracked pgid whose group leader still matches matchPath
// (identity re-verified via ps — a recycled pid can't match), SIGTERM the
// group, grace, SIGKILL; every tracked container gets `docker rm -f`. Then the
// janitor exits. A clean manager quit unregisters everything first, so the
// EOF pass is an idempotent no-op.
//
// The janitor ignores terminal signals and detaches into its own process
// group: a Ctrl-C aimed at `flutter run` (or a group-kill of the manager) must
// not take the janitor down before it can do its job — only lifeline EOF ends
// it.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type pgidEntry struct {
	pgid  int
	match string
}

func main() {
	signal.Ignore(syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	_ = syscall.Setpgid(0, 0) // leave the manager's group; see package comment

	logf, _ := os.OpenFile(filepath.Join(os.TempDir(), "rm-janitor.log"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	logln := func(format string, a ...any) {
		if logf != nil {
			fmt.Fprintf(logf, time.Now().Format("2006-01-02 15:04:05 ")+format+"\n", a...)
		}
	}
	logln("janitor up (pid %d)", os.Getpid())

	pgids := map[int]pgidEntry{}
	ctrs := map[string]string{} // name -> docker path

	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		switch {
		case len(f) >= 3 && f[0] == "PGID":
			if pgid, err := strconv.Atoi(f[1]); err == nil && pgid > 0 {
				pgids[pgid] = pgidEntry{pgid: pgid, match: strings.Join(f[2:], " ")}
			}
		case len(f) >= 3 && f[0] == "CTR":
			// Container name is the LAST field; the docker path (which can contain
			// spaces) is everything between. Container names never contain spaces,
			// so right-anchored parsing is unambiguous — mirrors the PGID branch.
			ctrs[f[len(f)-1]] = strings.Join(f[1:len(f)-1], " ")
		case len(f) == 3 && f[0] == "UNREG" && f[1] == "PGID":
			if pgid, err := strconv.Atoi(f[2]); err == nil {
				delete(pgids, pgid)
			}
		case len(f) == 3 && f[0] == "UNREG" && f[1] == "CTR":
			delete(ctrs, f[2])
		}
	}
	// EOF (or read error): the manager is gone. Clean up and exit.
	logln("lifeline EOF: %d pgids, %d containers to reap", len(pgids), len(ctrs))

	var termed []int
	for _, e := range pgids {
		// Identity check before pulling any trigger: the group leader's command
		// line must still reference the path the manager registered. A dead or
		// recycled pid fails this and is skipped.
		out, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(e.pgid)).Output()
		if err != nil || !strings.Contains(string(out), e.match) {
			logln("skip pgid %d (gone or no longer matches %q)", e.pgid, e.match)
			continue
		}
		if err := syscall.Kill(-e.pgid, syscall.SIGTERM); err == nil {
			logln("SIGTERM pgid %d", e.pgid)
			termed = append(termed, e.pgid)
		}
	}
	for name, docker := range ctrs {
		logln("docker rm -f %s", name)
		_ = exec.Command(docker, "rm", "-f", name).Run()
	}
	if len(termed) > 0 {
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			alive := false
			for _, pgid := range termed {
				if syscall.Kill(-pgid, 0) == nil {
					alive = true
					break
				}
			}
			if !alive {
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		for _, pgid := range termed {
			if syscall.Kill(-pgid, 0) == nil {
				logln("SIGKILL pgid %d", pgid)
				_ = syscall.Kill(-pgid, syscall.SIGKILL)
			}
		}
	}
	logln("janitor done")
}
