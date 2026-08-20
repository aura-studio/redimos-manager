package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Test fixtures and fakes
// ---------------------------------------------------------------------------

// svc builds a fully-specified ServiceConfig fixture (no normalization).
func svc(id string, engine ServiceEngine, port int, st ServiceStorage, opts map[string]any) ServiceConfig {
	return ServiceConfig{ID: id, Name: "svc-" + id, Engine: engine, Port: port, Storage: st, EngineOptions: opts}
}

// overrideSvcBins swaps the tool-discovery indirections for fakes.
func overrideSvcBins(t *testing.T, docker, java string) {
	t.Helper()
	od, oj := svcDockerBin, svcJavaBin
	if docker != "" {
		p := docker
		svcDockerBin = func() (string, bool) { return p, true }
	}
	if java != "" {
		p := java
		svcJavaBin = func() (string, bool) { return p, true }
	}
	t.Cleanup(func() { svcDockerBin, svcJavaBin = od, oj })
}

func overrideSvcBinsMissing(t *testing.T) {
	t.Helper()
	od, oj := svcDockerBin, svcJavaBin
	svcDockerBin = func() (string, bool) { return "", false }
	svcJavaBin = func() (string, bool) { return "", false }
	t.Cleanup(func() { svcDockerBin, svcJavaBin = od, oj })
}

// sandboxRegistry redirects the children registry into the test sandbox.
func sandboxRegistry(t *testing.T) {
	t.Helper()
	old := registryDirForTest
	registryDirForTest = filepath.Join(t.TempDir(), "run")
	t.Cleanup(func() { registryDirForTest = old })
}

// sandboxManagedRoot redirects the managed data root into the test sandbox.
func sandboxManagedRoot(t *testing.T) {
	t.Helper()
	old := serviceManagedRootForTest
	serviceManagedRootForTest = filepath.Join(t.TempDir(), "services")
	t.Cleanup(func() { serviceManagedRootForTest = old })
}

// writeScript drops an executable script and returns its path.
func writeScript(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "fake")
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

// fakeDocker is a stateful docker stand-in. It logs every call to
// <state>/calls.log and serves canned answers from per-resource files:
//
//	volume inspect NAME   → <state>/vol-NAME.inspect (JSON) or exit 1
//	container inspect     → <state>/container-NAME.inspect ("<labels JSON>|<running>")
//	                      or exit 1; honours -f: a format without
//	                      .Config.Labels gets only the part after the last "|"
//	volume create/rm      → logged; rm additionally appended to vol-removed.log
//	run                   → stays alive until rm bumps the generation of
//	                      <state>/container-NAME.removed (mirrors `docker rm`
//	                      ending `docker run`). Once it has captured its stop
//	                      baseline it publishes readiness markers
//	                      <state>/container-NAME.up and <state>/port-PORT.up;
//	                      tests gate start on them so a stop can never land
//	                      before the fake can observe it (the fake's model of
//	                      real docker, where "serving on the port" implies the
//	                      container exists and rm -f is observable).
//	wait                  → errors like real docker when the container does not
//	                      exist (no up marker from a live run, no seeded
//	                      inspect); otherwise blocks until rm bumps the
//	                      generation or removes the container, then prints 0
//	ps                    → with --filter volume=NAME --format {{.Names}},
//	                      prints the names of existing containers (up marker
//	                      or seeded inspect) that mount NAME; run records the
//	                      mount in <state>/mount-NAME, rm clears it
func fakeDocker(t *testing.T) (bin, state string) {
	t.Helper()
	state = t.TempDir()
	script := `#!/bin/bash
echo "$*" >> "$STATE_DIR/calls.log"
case "$1" in
volume)
  case "$2" in
  inspect)
    f="$STATE_DIR/vol-$3.inspect"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    exit 1 ;;
  create) exit 0 ;;
  rm) echo "$3" >> "$STATE_DIR/vol-removed.log"; exit 0 ;;
  esac
  exit 0 ;;
inspect)
  f="$STATE_DIR/container-$4.inspect"
  [ -f "$f" ] || exit 1
  content=$(cat "$f")
  case "$3" in
  *".Config.Labels"*) printf '%s\n' "$content" ;;
  *) printf '%s\n' "${content##*|}" ;;
  esac
  exit 0 ;;
wait)
  name="$2"
  f="$STATE_DIR/container-$name.removed"
  # Existence: a live run publishes the up marker; a seeded inspect file stands
  # for a container created outside this fake (a crash survivor). Neither =
  # "No such container", exactly when real docker would say so — including the
  # window where rm happened before this wait started.
  if [ ! -f "$STATE_DIR/container-$name.up" ] && [ ! -f "$STATE_DIR/container-$name.inspect" ]; then
    echo "Error: No such container: $name" >&2
    exit 1
  fi
  gen=$(cat "$f" 2>/dev/null || echo 0)
  while :; do
    cur=$(cat "$f" 2>/dev/null || echo 0)
    if [ "$cur" != "$gen" ]; then echo 0; exit 0; fi
    if [ ! -f "$STATE_DIR/container-$name.up" ] && [ ! -f "$STATE_DIR/container-$name.inspect" ]; then echo 0; exit 0; fi
    sleep 0.05
  done ;;
rm)
  f="$STATE_DIR/container-$3.removed"
  cur=$(cat "$f" 2>/dev/null || echo 0)
  echo $((cur+1)) > "$f"
  # Removing the container also ends its inspectable existence (real docker:
  # inspect fails after rm) and releases its volume mount; the wait loop
  # observes the existence change.
  rm -f "$STATE_DIR/container-$3.inspect" "$STATE_DIR/mount-$3"
  exit 0 ;;
ps)
  vol=""
  for a in "$@"; do
    case "$a" in volume=*) vol="${a#volume=}" ;; esac
  done
  if [ -n "$vol" ]; then
    for mf in "$STATE_DIR"/mount-*; do
      [ -f "$mf" ] || continue
      [ "$(cat "$mf")" = "$vol" ] || continue
      cname="${mf##*/mount-}"
      if [ -f "$STATE_DIR/container-$cname.up" ] || [ -f "$STATE_DIR/container-$cname.inspect" ]; then
        echo "$cname"
      fi
    done
  fi
  exit 0 ;;
run)
  name=""; port=""; vol=""; prev=""
  for a in "$@"; do
    if [ "$prev" = "--name" ]; then name="$a"; fi
    if [ "$prev" = "-p" ]; then port="${a%%:*}"; fi
    if [ "$prev" = "-v" ]; then vol="${a%%:*}"; fi
    prev="$a"
  done
  if [ -n "$name" ] && [ -n "$vol" ]; then echo "$vol" > "$STATE_DIR/mount-$name"; fi
  f="$STATE_DIR/container-$name.removed"
  up="$STATE_DIR/container-$name.up"
  pup="$STATE_DIR/port-$port.up"
  # Drop stale readiness markers from a hard-killed earlier epoch, THEN capture
  # the generation baseline: any rm bump after this point is our stop signal.
  rm -f "$up" "$pup"
  gen=$(cat "$f" 2>/dev/null || echo 0)
  # Arm: publish readiness only AFTER the baseline is captured, so any stop
  # that a test can issue from now on is guaranteed to be seen.
  : > "$up"
  if [ -n "$port" ]; then : > "$pup"; fi
  i=0
  # Bounded lifetime (120s) so an abandoned fake container can never leak an
  # endless busy-loop past the test run.
  while [ "$i" -lt 2400 ]; do
    cur=$(cat "$f" 2>/dev/null || echo 0)
    if [ "$cur" != "$gen" ]; then break; fi
    sleep 0.05
    i=$((i+1))
  done
  rm -f "$up" "$pup"
  exit 0 ;;
esac
exit 0
`
	script = strings.ReplaceAll(script, "$STATE_DIR", state)
	return writeScript(t, script), state
}

func readCalls(t *testing.T, state string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(state, "calls.log"))
	if err != nil {
		return ""
	}
	return string(b)
}

// hasFlagSeq reports whether args contains the exact consecutive sequence.
func hasFlagSeq(args []string, seq ...string) bool {
	for i := 0; i+len(seq) <= len(args); i++ {
		ok := true
		for j, s := range seq {
			if args[i+j] != s {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

func countFlag(args []string, v string) int {
	n := 0
	for _, a := range args {
		if a == v {
			n++
		}
	}
	return n
}

// waitFor polls cond until true or the deadline passes.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// portUpFile is the readiness marker the fake docker `run` publishes for the
// host port once its stop-generation baseline is armed.
func portUpFile(state string, port int) string {
	return filepath.Join(state, fmt.Sprintf("port-%d.up", port))
}

// portUpProbe is a readiness probe reporting a fake Service ready exactly when
// its container has armed its stop channel — the fake's model of real docker,
// where "serving on the port" implies the container exists and rm -f is
// observable. Gating start on it makes stop-after-start race-free.
func portUpProbe(state string) func(int) bool {
	return func(port int) bool {
		_, err := os.Stat(portUpFile(state, port))
		return err == nil
	}
}

// waitPortUp blocks until the fake container serving port has armed (or a
// generous deadline passes). Never-ready probes call it first so a rollback's
// terminate is guaranteed to land after the fake captured its baseline.
func waitPortUp(state string, port int) {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(portUpFile(state, port)); err == nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------
// 4.1 adapter dispatch
// ---------------------------------------------------------------------------

func TestServiceEngineForDispatch(t *testing.T) {
	for _, e := range []ServiceEngine{ServiceEngineJava, ServiceEngineDockerDDB, ServiceEngineLocalStack} {
		ad, err := serviceEngineFor(e)
		if err != nil {
			t.Fatalf("%s: %v", e, err)
		}
		if ad.engine() != e {
			t.Errorf("adapter engine() = %s, want %s", ad.engine(), e)
		}
	}
	if _, err := serviceEngineFor(ServiceEngine("redis")); err == nil {
		t.Fatal("unknown engine must fail closed")
	}
}

func TestServiceLabelsMatchExact(t *testing.T) {
	sc := svc("abc123", ServiceEngineDockerDDB, 8000, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	exact := map[string]string{
		"io.redimos.managed":    "true",
		"io.redimos.entity":     "service",
		"io.redimos.service-id": "abc123",
		"io.redimos.engine":     "docker",
	}
	if !serviceLabelsMatch(exact, sc) {
		t.Fatal("exact quartet must match")
	}
	for k := range exact {
		broken := map[string]string{}
		for kk, vv := range exact {
			broken[kk] = vv
		}
		delete(broken, k)
		if serviceLabelsMatch(broken, sc) {
			t.Errorf("missing %s must not match", k)
		}
		wrong := map[string]string{}
		for kk, vv := range exact {
			wrong[kk] = vv
		}
		wrong[k] = "evil"
		if serviceLabelsMatch(wrong, sc) {
			t.Errorf("wrong %s must not match", k)
		}
	}
	// A different Service's labels never prove ownership of this one.
	other := svc("zzz999", ServiceEngineDockerDDB, 8000, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	if serviceLabelsMatch(exact, other) {
		t.Fatal("another service's labels must not match")
	}
}

// ---------------------------------------------------------------------------
// 4.2 Java DynamoDB Local adapter
// ---------------------------------------------------------------------------

func TestJavaBuildLaunchIDSpecific(t *testing.T) {
	sandboxManagedRoot(t)
	javaDir := t.TempDir()
	m := mkManager(t)
	m.st.Settings.DynamoDbLocalDir = javaDir
	fakeJava := writeScript(t, "#!/bin/bash\nexit 0\n")
	overrideSvcBins(t, "", fakeJava)

	sc := svc("aaa111", ServiceEngineJava, 9101,
		ServiceStorage{Mode: ServiceStorageManaged, Path: serviceDataDir("aaa111")},
		map[string]any{"heap": "512m"})
	ad, _ := serviceEngineFor(ServiceEngineJava)
	spec, err := ad.buildLaunch(m, sc)
	if err != nil {
		t.Fatal(err)
	}
	if spec.bin != fakeJava {
		t.Errorf("bin = %q", spec.bin)
	}
	if spec.dir != javaDir {
		t.Errorf("working dir = %q, want %q", spec.dir, javaDir)
	}
	if spec.container != "" {
		t.Errorf("java is a host process: container must stay empty")
	}
	if !hasFlagSeq(spec.args, "-Dredimos.service.id=aaa111") {
		t.Errorf("missing id sentinel: %v", spec.args)
	}
	if !strings.Contains(strings.Join(spec.args, " "), "-Dredimos.manager.session=") {
		t.Errorf("missing session sentinel: %v", spec.args)
	}
	if !hasFlagSeq(spec.args, "-Xmx512m") {
		t.Errorf("heap option not mapped: %v", spec.args)
	}
	if !hasFlagSeq(spec.args, "-port", "9101") {
		t.Errorf("port missing: %v", spec.args)
	}
	if !hasFlagSeq(spec.args, "-dbPath", sc.Storage.Path, "-sharedDb") {
		t.Errorf("managed storage argv wrong: %v", spec.args)
	}
	if !hasFlagSeq(spec.args, "-Djava.library.path="+filepath.Join(javaDir, "DynamoDBLocal_lib")) {
		t.Errorf("library path wrong: %v", spec.args)
	}

	// memory storage: inMemory, no dbPath
	mem := svc("bbb222", ServiceEngineJava, 9102, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	spec2, err := ad.buildLaunch(m, mem)
	if err != nil {
		t.Fatal(err)
	}
	if !hasFlagSeq(spec2.args, "-inMemory", "-sharedDb") || countFlag(spec2.args, "-dbPath") != 0 {
		t.Errorf("memory argv wrong: %v", spec2.args)
	}
	// Two Services never share argv identity or data path.
	if hasFlagSeq(spec2.args, "-Dredimos.service.id=aaa111") {
		t.Error("service B carries service A's sentinel")
	}
}

func TestJavaBuildLaunchMissingJava(t *testing.T) {
	overrideSvcBinsMissing(t)
	ad, _ := serviceEngineFor(ServiceEngineJava)
	_, err := ad.buildLaunch(mkManager(t), svc("a", ServiceEngineJava, 9101, ServiceStorage{Mode: ServiceStorageMemory}, nil))
	if err == nil || !strings.Contains(err.Error(), "java") {
		t.Fatalf("want java-missing error, got %v", err)
	}
}

func TestJavaInspectOwnedRegistryIdentity(t *testing.T) {
	sandboxRegistry(t)
	m := mkManager(t)
	ad, _ := serviceEngineFor(ServiceEngineJava)

	sc := svc("aaa111", ServiceEngineJava, 9101, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	// No registry entry → not owned.
	if ok, _ := ad.inspectOwned(m, sc); ok {
		t.Fatal("empty registry must report not owned")
	}
	// Unknown start time: fail open (legacy-style record).
	regUpsert(childRec{Role: serviceRole(sc.ID), PID: 4242, StartUnixMicro: 0})
	if ok, _ := ad.inspectOwned(m, sc); !ok {
		t.Fatal("record without start time must count as owned")
	}
	// PID present but recorded start time mismatches the live process (PID
	// reuse) → not owned. Use our own pid so procIdentity succeeds but the
	// start time cannot possibly equal the fabricated one.
	regUpsert(childRec{Role: serviceRole(sc.ID), PID: os.Getpid(), StartUnixMicro: 12345})
	if ok, _ := ad.inspectOwned(m, sc); ok {
		t.Fatal("recycled pid with wrong start time must not count as owned")
	}
	// Another Service's role is never ours.
	regUpsert(childRec{Role: serviceRole("zzz999"), PID: os.Getpid(), StartUnixMicro: 0})
	other := svc("ccc333", ServiceEngineJava, 9103, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	if ok, _ := ad.inspectOwned(m, other); ok {
		t.Fatal("another service's registry entry must not match")
	}
}

func TestJavaDeleteManagedData(t *testing.T) {
	sandboxRegistry(t) // the filesystem proof reads the children registry
	sandboxManagedRoot(t)
	m := mkManager(t)
	ad, _ := serviceEngineFor(ServiceEngineJava)

	own := filepath.Join(serviceManagedRoot(), "aaa111")
	data := filepath.Join(own, "ddb-data")
	if err := os.MkdirAll(data, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, "x.db"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	// managed: removed
	managed := svc("aaa111", ServiceEngineJava, 9101, ServiceStorage{Mode: ServiceStorageManaged, Path: data}, nil)
	if err := ad.deleteManagedData(m, managed); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(own); !os.IsNotExist(err) {
		t.Fatal("managed dir must be removed")
	}
	// custom: never auto-deleted
	customDir := t.TempDir()
	custom := svc("bbb222", ServiceEngineJava, 9102, ServiceStorage{Mode: ServiceStorageCustom, Path: customDir}, nil)
	if err := ad.deleteManagedData(m, custom); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(customDir); err != nil {
		t.Fatal("custom path must be preserved")
	}
	// memory: nothing to do
	mem := svc("ccc333", ServiceEngineJava, 9103, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	if err := ad.deleteManagedData(m, mem); err != nil {
		t.Fatal(err)
	}
	// a path escaping the managed root refuses deletion
	escape := svc("ddd444", ServiceEngineJava, 9104, ServiceStorage{Mode: ServiceStorageManaged, Path: "/tmp"}, nil)
	if err := ad.deleteManagedData(m, escape); err == nil {
		t.Fatal("path outside managed root must refuse")
	}
}

// ---------------------------------------------------------------------------
// 4.3 Docker adapters: launch specs
// ---------------------------------------------------------------------------

func TestDockerDdbBuildLaunch(t *testing.T) {
	fake, _ := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	ad, _ := serviceEngineFor(ServiceEngineDockerDDB)
	m := mkManager(t)

	// memory
	mem := svc("aaa111", ServiceEngineDockerDDB, 9201, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	spec, err := ad.buildLaunch(m, mem)
	if err != nil {
		t.Fatal(err)
	}
	if spec.container != "redimos-service-aaa111" {
		t.Errorf("container name = %q", spec.container)
	}
	if !hasFlagSeq(spec.args, "--name", "redimos-service-aaa111") {
		t.Errorf("--name missing: %v", spec.args)
	}
	for _, l := range []string{
		"io.redimos.managed=true",
		"io.redimos.entity=service",
		"io.redimos.service-id=aaa111",
		"io.redimos.engine=docker",
	} {
		if !hasFlagSeq(spec.args, "--label", l) {
			t.Errorf("label %s missing: %v", l, spec.args)
		}
	}
	if !hasFlagSeq(spec.args, "-p", "9201:8000") {
		t.Errorf("port mapping wrong: %v", spec.args)
	}
	if !hasFlagSeq(spec.args, "-inMemory", "-sharedDb") || countFlag(spec.args, "-v") != 0 {
		t.Errorf("memory argv wrong: %v", spec.args)
	}
	imgIdx := -1
	for i, a := range spec.args {
		if a == "amazon/dynamodb-local" {
			imgIdx = i
		}
	}
	if imgIdx < 0 || imgIdx+1 >= len(spec.args) || spec.args[imgIdx+1] != "-jar" {
		t.Errorf("image wrong: %v", spec.args)
	}

	// managed storage: volume + root + /data
	managed := svc("bbb222", ServiceEngineDockerDDB, 9202,
		ServiceStorage{Mode: ServiceStorageManaged, Volume: serviceVolumeName("bbb222")}, nil)
	spec2, err := ad.buildLaunch(m, managed)
	if err != nil {
		t.Fatal(err)
	}
	if !hasFlagSeq(spec2.args, "-v", serviceVolumeName("bbb222")+":/data", "-u", "root") {
		t.Errorf("managed volume mount wrong: %v", spec2.args)
	}
	if !hasFlagSeq(spec2.args, "-dbPath", "/data", "-sharedDb") {
		t.Errorf("managed argv wrong: %v", spec2.args)
	}
	// names, ports and labels differ across Services
	if spec2.container == spec.container {
		t.Error("two services share a container name")
	}
	if hasFlagSeq(spec2.args, "--label", "io.redimos.service-id=aaa111") {
		t.Error("service B carries service A's ownership label")
	}

	// custom without a volume fails closed
	bad := svc("ccc333", ServiceEngineDockerDDB, 9203, ServiceStorage{Mode: ServiceStorageCustom, Path: "/x"}, nil)
	if _, err := ad.buildLaunch(m, bad); err == nil {
		t.Fatal("custom storage without volume must fail")
	}

	// missing docker fails closed
	overrideSvcBinsMissing(t)
	if _, err := ad.buildLaunch(m, mem); err == nil || !strings.Contains(err.Error(), "docker") {
		t.Fatalf("want docker-missing error, got %v", err)
	}
}

func TestLocalstackBuildLaunch(t *testing.T) {
	fake, _ := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	ad, _ := serviceEngineFor(ServiceEngineLocalStack)
	m := mkManager(t)

	mem := svc("aaa111", ServiceEngineLocalStack, 9301,
		ServiceStorage{Mode: ServiceStorageMemory},
		map[string]any{"DEBUG": "1", "AWS_REGION": "us-east-1"})
	spec, err := ad.buildLaunch(m, mem)
	if err != nil {
		t.Fatal(err)
	}
	if spec.container != "redimos-service-ls-aaa111" {
		t.Errorf("container name = %q", spec.container)
	}
	if !hasFlagSeq(spec.args, "-p", "9301:4566") {
		t.Errorf("port mapping wrong: %v", spec.args)
	}
	if countFlag(spec.args, "SERVICES=dynamodb") != 1 {
		t.Errorf("SERVICES must be pinned exactly once: %v", spec.args)
	}
	// options become env in deterministic (sorted) order
	i1, i2 := -1, -1
	for i, a := range spec.args {
		if a == "AWS_REGION=us-east-1" {
			i1 = i
		}
		if a == "DEBUG=1" {
			i2 = i
		}
	}
	if i1 < 0 || i2 < 0 || i1 > i2 {
		t.Errorf("env options wrong order/absent: %v", spec.args)
	}
	if countFlag(spec.args, "-v") != 0 || countFlag(spec.args, "PERSISTENCE=1") != 0 {
		t.Errorf("memory must not mount a volume: %v", spec.args)
	}
	if spec.args[len(spec.args)-1] != "localstack/localstack:4.0" {
		t.Errorf("image must stay pinned: %v", spec.args)
	}
	for _, l := range []string{"io.redimos.managed=true", "io.redimos.entity=service", "io.redimos.service-id=aaa111", "io.redimos.engine=localstack"} {
		if !hasFlagSeq(spec.args, "--label", l) {
			t.Errorf("label %s missing: %v", l, spec.args)
		}
	}

	// managed storage: volume + PERSISTENCE
	managed := svc("bbb222", ServiceEngineLocalStack, 9302,
		ServiceStorage{Mode: ServiceStorageManaged, Volume: serviceVolumeName("bbb222")}, nil)
	spec2, err := ad.buildLaunch(m, managed)
	if err != nil {
		t.Fatal(err)
	}
	if !hasFlagSeq(spec2.args, "-v", serviceVolumeName("bbb222")+":/var/lib/localstack", "-e", "PERSISTENCE=1") {
		t.Errorf("managed mount wrong: %v", spec2.args)
	}

	// overriding SERVICES is refused (scope guard)
	hack := svc("ccc333", ServiceEngineLocalStack, 9303, ServiceStorage{Mode: ServiceStorageMemory},
		map[string]any{"SERVICES": "s3,lambda"})
	if _, err := ad.buildLaunch(m, hack); err == nil || !strings.Contains(err.Error(), "SERVICES") {
		t.Fatalf("SERVICES override must be refused, got %v", err)
	}
	// custom without a volume fails closed
	bad := svc("ddd444", ServiceEngineLocalStack, 9304, ServiceStorage{Mode: ServiceStorageCustom}, nil)
	if _, err := ad.buildLaunch(m, bad); err == nil {
		t.Fatal("custom storage without volume must fail")
	}
}

// ---------------------------------------------------------------------------
// Volume and container ownership (fake docker)
// ---------------------------------------------------------------------------

func TestEnsureServiceVolumeReuseOrCreate(t *testing.T) {
	fake, state := fakeDocker(t)
	sc := svc("aaa111", ServiceEngineDockerDDB, 9201,
		ServiceStorage{Mode: ServiceStorageManaged, Volume: "redimos-service-aaa111-data"}, nil)

	// absent → created with the full ownership quartet
	if err := ensureServiceVolume(fake, sc); err != nil {
		t.Fatal(err)
	}
	calls := readCalls(t, state)
	if !strings.Contains(calls, "volume inspect redimos-service-aaa111-data") {
		t.Errorf("inspect not attempted: %s", calls)
	}
	createLine := ""
	for _, line := range strings.Split(calls, "\n") {
		if strings.HasPrefix(line, "volume create") {
			createLine = line
		}
	}
	if createLine == "" {
		t.Fatal("volume create not called")
	}
	for _, l := range serviceLabelPairs(sc) {
		if !strings.Contains(createLine, "--label "+l) {
			t.Errorf("create missing label %s: %s", l, createLine)
		}
	}

	// exists and provably ours → accepted, no recreate
	labelsJSON := `{"io.redimos.managed":"true","io.redimos.entity":"service","io.redimos.service-id":"aaa111","io.redimos.engine":"docker"}`
	if err := os.WriteFile(filepath.Join(state, "vol-redimos-service-aaa111-data.inspect"),
		[]byte(`[{"Labels":`+labelsJSON+`}]`), 0o644); err != nil {
		t.Fatal(err)
	}
	before := readCalls(t, state)
	if err := ensureServiceVolume(fake, sc); err != nil {
		t.Fatal(err)
	}
	after := readCalls(t, state)
	if strings.Count(after, "volume create") != strings.Count(before, "volume create") {
		t.Error("owned volume must not be recreated")
	}

	// exists, whatever the labels say → reused (v1.1.5 docker semantics: a
	// user-named volume mounts exactly as `docker run -v` would), no recreate
	stranger := svc("zzz999", ServiceEngineDockerDDB, 9299,
		ServiceStorage{Mode: ServiceStorageManaged, Volume: "redimos-service-aaa111-data"}, nil)
	before = readCalls(t, state)
	if err := ensureServiceVolume(fake, stranger); err != nil {
		t.Fatalf("existing named volume must be reused, got %v", err)
	}
	after = readCalls(t, state)
	if strings.Count(after, "volume create") != strings.Count(before, "volume create") {
		t.Error("existing volume must not be recreated on reuse")
	}
}

func TestInspectServiceContainerProvesOwnership(t *testing.T) {
	fake, state := fakeDocker(t)
	sc := svc("aaa111", ServiceEngineDockerDDB, 9201, ServiceStorage{Mode: ServiceStorageMemory}, nil)

	// absent container
	if exists, owned, running := inspectServiceContainer(fake, "redimos-service-aaa111", sc); exists || owned || running {
		t.Fatal("absent container must report nothing")
	}

	// same name, no labels → stranger
	os.WriteFile(filepath.Join(state, "container-redimos-service-aaa111.inspect"), []byte(`{}|true`), 0o644)
	exists, owned, running := inspectServiceContainer(fake, "redimos-service-aaa111", sc)
	if !exists || owned || !running {
		t.Fatalf("stranger container: exists=%v owned=%v running=%v", exists, owned, running)
	}

	// exact labels + running → ours and running
	out := `{"io.redimos.managed":"true","io.redimos.entity":"service","io.redimos.service-id":"aaa111","io.redimos.engine":"docker"}|true`
	os.WriteFile(filepath.Join(state, "container-redimos-service-aaa111.inspect"), []byte(out), 0o644)
	exists, owned, running = inspectServiceContainer(fake, "redimos-service-aaa111", sc)
	if !exists || !owned || !running {
		t.Fatalf("owned container: exists=%v owned=%v running=%v", exists, owned, running)
	}

	// exact labels but stopped → owned, not running
	out = `{"io.redimos.managed":"true","io.redimos.entity":"service","io.redimos.service-id":"aaa111","io.redimos.engine":"docker"}|false`
	os.WriteFile(filepath.Join(state, "container-redimos-service-aaa111.inspect"), []byte(out), 0o644)
	_, owned, running = inspectServiceContainer(fake, "redimos-service-aaa111", sc)
	if !owned || running {
		t.Fatalf("stopped owned container: owned=%v running=%v", owned, running)
	}
}

func TestRemoveOwnedServiceVolumeRefusesStranger(t *testing.T) {
	fake, state := fakeDocker(t)
	sc := svc("aaa111", ServiceEngineDockerDDB, 9201,
		ServiceStorage{Mode: ServiceStorageManaged, Volume: "vol-a"}, nil)

	// absent → success, nothing removed
	if err := removeOwnedServiceVolume(fake, sc); err != nil {
		t.Fatal(err)
	}
	if readCalls(t, state) != "" && strings.Contains(readCalls(t, state), "volume rm") {
		t.Fatal("absent volume must not be rm'd")
	}

	// stranger labels → refuse
	os.WriteFile(filepath.Join(state, "vol-vol-a.inspect"),
		[]byte(`[{"Labels":{"io.redimos.service-id":"zzz999"}}]`), 0o644)
	if err := removeOwnedServiceVolume(fake, sc); err == nil {
		t.Fatal("stranger volume must be refused")
	}

	// exact labels → removed
	os.WriteFile(filepath.Join(state, "vol-vol-a.inspect"),
		[]byte(`[{"Labels":{"io.redimos.managed":"true","io.redimos.entity":"service","io.redimos.service-id":"aaa111","io.redimos.engine":"docker"}}]`), 0o644)
	if err := removeOwnedServiceVolume(fake, sc); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(state, "vol-removed.log"))
	if strings.TrimSpace(string(b)) != "vol-a" {
		t.Fatalf("volume rm not issued: %q", string(b))
	}
}

// ---------------------------------------------------------------------------
// 4.5 smoke: two Services never share containers, volumes, paths or logs
// ---------------------------------------------------------------------------

func TestTwoDockerServicesFakeSmoke(t *testing.T) {
	sandboxRegistry(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	m := mkManager(t)
	ad, _ := serviceEngineFor(ServiceEngineDockerDDB)

	a := svc("aaa111", ServiceEngineDockerDDB, 9401,
		ServiceStorage{Mode: ServiceStorageManaged, Volume: serviceVolumeName("aaa111")}, nil)
	b := svc("bbb222", ServiceEngineDockerDDB, 9402,
		ServiceStorage{Mode: ServiceStorageManaged, Volume: serviceVolumeName("bbb222")}, nil)

	inA, inB := &instance{status: "stopped"}, &instance{status: "stopped"}
	if err := ad.start(m, a, inA); err != nil {
		t.Fatal(err)
	}
	if err := ad.start(m, b, inB); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "both running", func() bool {
		inA.mu.Lock()
		sa := inA.status
		inA.mu.Unlock()
		inB.mu.Lock()
		sb := inB.status
		inB.mu.Unlock()
		return sa == "running" && sb == "running"
	})

	// Registry carries one role per Service ID.
	roles := map[string]bool{}
	for _, rec := range regSnapshot() {
		roles[rec.Role] = true
	}
	if !roles[serviceRole("aaa111")] || !roles[serviceRole("bbb222")] {
		t.Fatalf("registry roles missing: %v", roles)
	}

	// Ownership check via exact labels: prove both containers ours.
	for _, sc := range []ServiceConfig{a, b} {
		name := serviceContainerName(ServiceEngineDockerDDB, sc.ID)
		out := fmt.Sprintf(`{"io.redimos.managed":"true","io.redimos.entity":"service","io.redimos.service-id":"%s","io.redimos.engine":"docker"}|true`, sc.ID)
		if err := os.WriteFile(filepath.Join(state, "container-"+name+".inspect"), []byte(out), 0o644); err != nil {
			t.Fatal(err)
		}
		if ok, err := ad.inspectOwned(m, sc); err != nil || !ok {
			t.Fatalf("inspectOwned(%s) = %v,%v", sc.ID, ok, err)
		}
	}
	// A container under the same name but labelled for another engine is a
	// stranger: it must not prove ownership of this (docker) Service.
	os.WriteFile(filepath.Join(state, "container-redimos-service-aaa111.inspect"),
		[]byte(`{"io.redimos.managed":"true","io.redimos.entity":"service","io.redimos.service-id":"aaa111","io.redimos.engine":"localstack"}|true`), 0o644)
	if ok, _ := ad.inspectOwned(m, a); ok {
		t.Fatal("engine-mismatched labels must not prove ownership")
	}

	calls := readCalls(t, state)
	// Two distinct volumes were created, each with its own labels.
	if !strings.Contains(calls, "volume create --label io.redimos.managed=true --label io.redimos.entity=service --label io.redimos.service-id=aaa111 --label io.redimos.engine=docker redimos-service-aaa111-data") {
		t.Errorf("volume A create missing/labelled wrong:\n%s", calls)
	}
	if !strings.Contains(calls, "volume create --label io.redimos.managed=true --label io.redimos.entity=service --label io.redimos.service-id=bbb222 --label io.redimos.engine=docker redimos-service-bbb222-data") {
		t.Errorf("volume B create missing/labelled wrong:\n%s", calls)
	}
	// Two distinct containers, ports and label sets.
	for _, want := range []string{
		"--name redimos-service-aaa111",
		"--name redimos-service-bbb222",
		"-p 9401:8000",
		"-p 9402:8000",
		"io.redimos.service-id=aaa111",
		"io.redimos.service-id=bbb222",
	} {
		if !strings.Contains(calls, want) {
			t.Errorf("calls missing %q:\n%s", want, calls)
		}
	}
	if strings.Contains(calls, "--name redimos-service-aaa111 --label") &&
		strings.Count(calls, "--name redimos-service-aaa111") != 1 {
		t.Error("container A launched more than once")
	}

	// Logs are per-instance and carry each Service's own argv.
	la, lb := inA.snapshotLogs(), inB.snapshotLogs()
	if len(la) == 0 || !strings.Contains(strings.Join(la, "\n"), "redimos-service-aaa111") {
		t.Errorf("A logs wrong: %v", la)
	}
	if len(lb) == 0 || !strings.Contains(strings.Join(lb, "\n"), "redimos-service-bbb222") {
		t.Errorf("B logs wrong: %v", lb)
	}

	// Stop both: terminate removes each container, the fake CLI exits, the
	// supervisor records a clean intended stop and clears the registry. Wait
	// for both fakes to have armed their stop channel first, so the stop
	// signals cannot land before the fakes can observe them.
	waitFor(t, "both containers armed", func() bool {
		_, e1 := os.Stat(filepath.Join(state, "container-redimos-service-aaa111.up"))
		_, e2 := os.Stat(filepath.Join(state, "container-redimos-service-bbb222.up"))
		return e1 == nil && e2 == nil
	})
	if err := ad.stop(m, a, inA); err != nil {
		t.Fatal(err)
	}
	if err := ad.stop(m, b, inB); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "both stopped", func() bool {
		inA.mu.Lock()
		sa := inA.status
		inA.mu.Unlock()
		inB.mu.Lock()
		sb := inB.status
		inB.mu.Unlock()
		return sa == "stopped" && sb == "stopped"
	})
	// Join the supervisor goroutines so their terminal registry bookkeeping
	// completes before the test tears down the sandboxed state.
	inA.superviseWG.Wait()
	inB.superviseWG.Wait()
	for _, name := range []string{"redimos-service-aaa111", "redimos-service-bbb222"} {
		if _, err := os.Stat(filepath.Join(state, "container-"+name+".removed")); err != nil {
			t.Errorf("container %s was not removed on stop", name)
		}
	}
	waitFor(t, "registry cleared", func() bool {
		for _, rec := range regSnapshot() {
			if rec.Role == serviceRole("aaa111") || rec.Role == serviceRole("bbb222") {
				return false
			}
		}
		return true
	})
}

func TestTwoJavaServicesFakeProcessSmoke(t *testing.T) {
	sandboxRegistry(t)
	// fake java: a real host process we can spawn and kill
	fakeJava := writeScript(t, "#!/bin/bash\nexec sleep 30\n")
	overrideSvcBins(t, "", fakeJava)
	javaDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(javaDir, "DynamoDBLocal.jar"), []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := mkManager(t)
	m.st.Settings.DynamoDbLocalDir = javaDir
	ad, _ := serviceEngineFor(ServiceEngineJava)

	dataA := filepath.Join(t.TempDir(), "a", "ddb-data")
	dataB := filepath.Join(t.TempDir(), "b", "ddb-data")
	a := svc("aaa111", ServiceEngineJava, 9501, ServiceStorage{Mode: ServiceStorageCustom, Path: dataA}, nil)
	b := svc("bbb222", ServiceEngineJava, 9502, ServiceStorage{Mode: ServiceStorageCustom, Path: dataB}, nil)

	inA, inB := &instance{status: "stopped"}, &instance{status: "stopped"}
	if err := ad.start(m, a, inA); err != nil {
		t.Fatal(err)
	}
	if err := ad.start(m, b, inB); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "both running", func() bool {
		inA.mu.Lock()
		sa := inA.status
		inA.mu.Unlock()
		inB.mu.Lock()
		sb := inB.status
		inB.mu.Unlock()
		return sa == "running" && sb == "running"
	})

	// Data directories created per Service, never shared.
	if _, err := os.Stat(dataA); err != nil {
		t.Error("data dir A not created")
	}
	if _, err := os.Stat(dataB); err != nil {
		t.Error("data dir B not created")
	}
	if dataA == dataB {
		t.Fatal("services share a data dir")
	}

	// Registry: distinct roles, each with its own pid.
	recs := map[string]childRec{}
	for _, rec := range regSnapshot() {
		recs[rec.Role] = rec
	}
	ra, rb := recs[serviceRole("aaa111")], recs[serviceRole("bbb222")]
	if ra.PID == 0 || rb.PID == 0 || ra.PID == rb.PID {
		t.Fatalf("registry entries wrong: %+v / %+v", ra, rb)
	}
	if strings.Contains(ra.Comm, "bbb") || strings.Contains(rb.Comm, "aaa") {
		t.Error("cross-service comm contamination")
	}

	// Per-Service logs carry the owning sentinel; inspectOwned sees them.
	la := strings.Join(inA.snapshotLogs(), "\n")
	if !strings.Contains(la, "-Dredimos.service.id=aaa111") {
		t.Errorf("A logs lack its sentinel: %s", la)
	}
	if ok, _ := ad.inspectOwned(m, a); !ok {
		t.Error("A must be inspect-owned while running")
	}
	if ok, _ := ad.inspectOwned(m, b); !ok {
		t.Error("B must be inspect-owned while running")
	}

	// Stop both: host processes are killed, registry entries removed.
	if err := ad.stop(m, a, inA); err != nil {
		t.Fatal(err)
	}
	if err := ad.stop(m, b, inB); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "both stopped", func() bool {
		inA.mu.Lock()
		sa := inA.status
		inA.mu.Unlock()
		inB.mu.Lock()
		sb := inB.status
		inB.mu.Unlock()
		return sa == "stopped" && sb == "stopped"
	})
	// Join the supervisor goroutines so their terminal registry bookkeeping
	// completes before the test tears down the sandboxed state.
	inA.superviseWG.Wait()
	inB.superviseWG.Wait()
	for _, rec := range regSnapshot() {
		if strings.HasPrefix(rec.Role, "service:") {
			t.Fatalf("registry still holds %s", rec.Role)
		}
	}
	if ok, _ := ad.inspectOwned(m, a); ok {
		t.Error("stopped service must not be owned")
	}
}
