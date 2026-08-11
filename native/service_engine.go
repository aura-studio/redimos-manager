package main

// Service engine adapters.
//
// One adapter per Service engine (Java DynamoDB Local, Docker DynamoDB Local,
// LocalStack) sits behind a single interface so the ID-addressed lifecycle
// state machine stays engine-blind. Every derived resource — container name,
// labels, port mapping, volume, data directory, argv, working directory, and
// registry role — comes from the immutable Service ID; two Services never
// share any of them.
//
// Ownership proof: containerised resources are owned only when all four
// io.redimos.* labels match exactly. A matching name or name prefix is never
// proof of ownership.

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Tool discovery is indirected through vars so tests can substitute fakes.
var (
	svcDockerBin = dockerBin
	svcJavaBin   = javaBin
)

// ---------------------------------------------------------------------------
// Ownership labels
// ---------------------------------------------------------------------------

// serviceLabelPairs are the ownership labels stamped on every container and
// volume a Service owns.
func serviceLabelPairs(sc ServiceConfig) []string {
	return []string{
		"io.redimos.managed=true",
		"io.redimos.entity=service",
		"io.redimos.service-id=" + sc.ID,
		"io.redimos.engine=" + string(sc.Engine),
	}
}

// serviceLabelsMatch reports whether labels carry the exact ownership quartet
// for sc. A missing or differing key fails closed.
func serviceLabelsMatch(labels map[string]string, sc ServiceConfig) bool {
	for _, kv := range serviceLabelPairs(sc) {
		i := strings.IndexByte(kv, '=')
		if labels[kv[:i]] != kv[i+1:] {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Adapter interface
// ---------------------------------------------------------------------------

// serviceLaunch is the fully resolved launch spec for one Service: binary,
// argv, working directory, and (docker engines only) the container name the
// foreground CLI runs.
type serviceLaunch struct {
	bin       string
	args      []string
	dir       string // working directory for the child ("" = inherit)
	container string // docker engines only
}

// serviceEngine adapts one engine to the generic lifecycle. Implementations
// must derive every resource from the Service ID — never from name or port.
type serviceEngine interface {
	engine() ServiceEngine
	buildLaunch(m *manager, sc ServiceConfig) (serviceLaunch, error)
	start(m *manager, sc ServiceConfig, in *instance) error
	inspectOwned(m *manager, sc ServiceConfig) (bool, error)
	stop(m *manager, sc ServiceConfig, in *instance) error
	logs(m *manager, sc ServiceConfig, in *instance) ([]string, error)
	sample(m *manager, sc ServiceConfig, in *instance) error
	deleteManagedData(m *manager, sc ServiceConfig) error
}

// serviceEngineFor resolves the adapter for an engine. Unknown engines fail
// closed: the validator rejects them at the config boundary, but persisted
// data can carry anything, so the dispatch must not trust it.
func serviceEngineFor(e ServiceEngine) (serviceEngine, error) {
	switch e {
	case ServiceEngineJava:
		return javaServiceEngine{}, nil
	case ServiceEngineDockerDDB:
		return dockerServiceEngineBase{kind: ServiceEngineDockerDDB, build: buildDockerDdbLaunch}, nil
	case ServiceEngineLocalStack:
		return dockerServiceEngineBase{kind: ServiceEngineLocalStack, build: buildLocalstackLaunch}, nil
	}
	return nil, fmt.Errorf("unknown engine %q", e)
}

// armLaunch writes the resolved launch spec into the instance so spawn() runs
// it verbatim. Service children are detached (they survive manager death so
// the next session can adopt them) and auto-restart under supervision. A
// fresh user-initiated run supersedes any prior stop and starts with clean
// supervisor counters (an old crash-loop history must not poison a new run).
func armLaunch(in *instance, spec serviceLaunch, sc ServiceConfig) {
	in.mu.Lock()
	in.bin, in.launchArgs, in.launchEnv = spec.bin, spec.args, os.Environ()
	in.wd = spec.dir
	in.port = sc.Port
	in.role = serviceRole(sc.ID)
	in.container = spec.container
	in.detached = true
	in.autoRestart = true
	in.intendedStop = false
	in.failCount = 0
	in.restarts = 0
	in.mu.Unlock()
}

// ---------------------------------------------------------------------------
// Docker helpers shared by the container engines
// ---------------------------------------------------------------------------

// parseVolumeLabels extracts the Labels map of the first volume from
// `docker volume inspect` output.
func parseVolumeLabels(out []byte) (map[string]string, error) {
	var vs []struct {
		Labels map[string]string `json:"Labels"`
	}
	if err := json.Unmarshal(out, &vs); err != nil || len(vs) == 0 {
		return nil, fmt.Errorf("unparsable volume inspect output")
	}
	return vs[0].Labels, nil
}

// ensureServiceVolume guarantees the Service's volume exists AND is provably
// ours. An existing volume whose labels don't match exactly is a hard error —
// mounting an unproven volume could expose another workload's data.
func ensureServiceVolume(dockerPath string, sc ServiceConfig) error {
	name := sc.Storage.Volume
	inspectCmd := exec.Command(dockerPath, "volume", "inspect", name)
	hideWindow(inspectCmd)
	out, err := inspectCmd.Output()
	if err == nil {
		labels, perr := parseVolumeLabels(out)
		if perr == nil && serviceLabelsMatch(labels, sc) {
			return nil // exists and provably ours
		}
		return fmt.Errorf("volume %q exists without matching ownership labels", name)
	}
	args := []string{"volume", "create"}
	for _, l := range serviceLabelPairs(sc) {
		args = append(args, "--label", l)
	}
	args = append(args, name)
	createCmd := exec.Command(dockerPath, args...)
	hideWindow(createCmd)
	if err := createCmd.Run(); err != nil {
		return fmt.Errorf("create volume %s: %w", name, err)
	}
	return nil
}

// removeOwnedServiceVolume deletes the Service's volume, refusing when
// ownership cannot be proven (10.5): the exact label quartet must match AND
// no container may still mount the volume (cross-mount check). An absent
// volume is success (nothing to clean).
func removeOwnedServiceVolume(dockerPath string, sc ServiceConfig) error {
	name := sc.Storage.Volume
	inspectCmd := exec.Command(dockerPath, "volume", "inspect", name)
	hideWindow(inspectCmd)
	out, err := inspectCmd.Output()
	if err != nil {
		return nil // already gone
	}
	labels, perr := parseVolumeLabels(out)
	if perr != nil || !serviceLabelsMatch(labels, sc) {
		return fmt.Errorf("%w: volume %q exists without matching ownership labels; clean it up manually", errUnownedVolume, name)
	}
	mounts, merr := volumeMountedBy(dockerPath, name)
	if merr != nil {
		return fmt.Errorf("verify mounts of volume %q: %w", name, merr)
	}
	if len(mounts) > 0 {
		return fmt.Errorf("%w: volume %q is still mounted by %s; stop them or clean it up manually",
			errUnownedVolume, name, strings.Join(mounts, ", "))
	}
	rmCmd := exec.Command(dockerPath, "volume", "rm", name)
	hideWindow(rmCmd)
	if err := rmCmd.Run(); err != nil {
		return fmt.Errorf("remove volume %s: %w", name, err)
	}
	return nil
}

// volumeMountedBy lists the containers that still mount the named volume
// (`docker ps -a --filter volume=NAME`). Failing to list is an error, not an
// empty answer: the cross-mount proof must not fail open.
func volumeMountedBy(dockerPath, name string) ([]string, error) {
	psCmd := exec.Command(dockerPath, "ps", "-a", "--filter", "volume="+name, "--format", "{{.Names}}")
	hideWindow(psCmd)
	out, err := psCmd.Output()
	if err != nil {
		return nil, err
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if s := strings.TrimSpace(line); s != "" {
			names = append(names, s)
		}
	}
	return names, nil
}

// inspectServiceContainer reports (exists, owned, running) for a named
// container. Ownership requires the exact label quartet; a same-name container
// without it is treated as a stranger's.
func inspectServiceContainer(dockerPath, name string, sc ServiceConfig) (exists, owned, running bool) {
	inspectCmd := exec.Command(dockerPath, "inspect", "-f",
		`{{json .Config.Labels}}|{{.State.Running}}`, name)
	hideWindow(inspectCmd)
	out, err := inspectCmd.Output()
	if err != nil {
		return false, false, false
	}
	s := strings.TrimSpace(string(out))
	i := strings.LastIndex(s, "|")
	if i < 0 {
		return true, false, false
	}
	var labels map[string]string
	if json.Unmarshal([]byte(s[:i]), &labels) != nil {
		return true, false, false
	}
	return true, serviceLabelsMatch(labels, sc), strings.TrimSpace(s[i+1:]) == "true"
}

// ---------------------------------------------------------------------------
// Java DynamoDB Local
// ---------------------------------------------------------------------------

type javaServiceEngine struct{}

func (javaServiceEngine) engine() ServiceEngine { return ServiceEngineJava }

// buildLaunch resolves the java argv for one Service. ID-specific: the JVM
// carries a -D sentinel naming the owning Service so ps-level inspection can
// tell two Services apart, and managed data lives under the Service's own
// directory in the managed root.
func (javaServiceEngine) buildLaunch(m *manager, sc ServiceConfig) (serviceLaunch, error) {
	java, ok := svcJavaBin()
	if !ok {
		return serviceLaunch{}, fmt.Errorf("java not available (install a JRE, or switch to a Docker engine)")
	}
	dir := m.ddbJavaDir()
	a := []string{
		// cmdline sentinels visible in `ps`: session tag + owning Service ID.
		"-Dredimos.manager.session=" + mgr.sessionID,
		"-Dredimos.service.id=" + sc.ID,
	}
	if heap, ok := sc.EngineOptions["heap"].(string); ok {
		if h := strings.TrimSpace(heap); h != "" {
			a = append(a, "-Xmx"+h)
		}
	}
	a = append(a,
		"-Djava.library.path="+filepath.Join(dir, "DynamoDBLocal_lib"),
		"-jar", filepath.Join(dir, "DynamoDBLocal.jar"),
		"-port", strconv.Itoa(sc.Port),
	)
	if sc.Storage.Mode == ServiceStorageMemory {
		a = append(a, "-inMemory", "-sharedDb")
	} else {
		a = append(a, "-dbPath", sc.Storage.Path, "-sharedDb")
	}
	return serviceLaunch{bin: java, args: a, dir: dir}, nil
}

// start arms the instance and spawns it. When the DynamoDBLocal package is not
// yet downloaded the download runs first (legacy provisioning path); progress
// lands in this Service's own log and a stop request during provisioning is
// honoured through intendedStop.
func (e javaServiceEngine) start(m *manager, sc ServiceConfig, in *instance) error {
	spec, err := e.buildLaunch(m, sc)
	if err != nil {
		return err
	}
	if sc.Storage.Mode != ServiceStorageMemory {
		if err := os.MkdirAll(sc.Storage.Path, 0o755); err != nil {
			return fmt.Errorf("create data dir: %w", err)
		}
	}
	armLaunch(in, spec, sc)

	dir := m.ddbJavaDir()
	if ddbJarReady(dir) {
		return in.spawn()
	}
	in.mu.Lock()
	in.status = "preparing"
	in.mu.Unlock()
	go func() {
		if err := ensureDdbJar(in, dir); err != nil {
			in.appendLog("[service: " + err.Error() + "]")
			in.mu.Lock()
			if !in.intendedStop {
				in.status = "error"
				in.exitMsg = err.Error()
			}
			in.mu.Unlock()
			return
		}
		in.mu.Lock()
		stopped := in.intendedStop
		in.mu.Unlock()
		if stopped {
			return
		}
		if err := in.spawn(); err != nil {
			in.mu.Lock()
			if !in.intendedStop {
				in.status = "error"
				in.exitMsg = err.Error()
			}
			in.mu.Unlock()
		}
	}()
	return nil
}

// inspectOwned checks the children registry for this Service's role and
// re-verifies the recorded process identity (PID-reuse guard).
func (javaServiceEngine) inspectOwned(m *manager, sc ServiceConfig) (bool, error) {
	role := serviceRole(sc.ID)
	for _, rec := range regSnapshot() {
		if rec.Role != role || rec.PID <= 0 {
			continue
		}
		if rec.StartUnixMicro == 0 || identityMatches(rec.PID, rec.StartUnixMicro) {
			return true, nil
		}
	}
	return false, nil
}

func (javaServiceEngine) stop(m *manager, sc ServiceConfig, in *instance) error {
	if in != nil {
		in.terminate()
	}
	return nil
}

func (javaServiceEngine) logs(m *manager, sc ServiceConfig, in *instance) ([]string, error) {
	if in == nil {
		return []string{}, nil
	}
	return in.snapshotLogs(), nil
}

// sample refreshes CPU/memory/disk for a host-process Service, mirroring the
// samplerLoop's plain-process branch (Services are not in m.running, so the
// lifecycle layer drives their sampling through the adapter).
func (javaServiceEngine) sample(m *manager, sc ServiceConfig, in *instance) error {
	if in == nil {
		return nil
	}
	in.mu.Lock()
	pid, running := in.pid, in.status == "running"
	in.mu.Unlock()
	if !running || pid <= 0 {
		return nil
	}
	busy, mem, disk, err := sampleProcess(pid)
	if err != nil {
		return nil
	}
	now := time.Now()
	in.mu.Lock()
	defer in.mu.Unlock()
	if in.pid != pid {
		return nil
	}
	in.memBytes = mem
	if !in.prevSampleAt.IsZero() {
		wall := now.Sub(in.prevSampleAt)
		if busy >= in.prevBusy && wall > 0 {
			in.cpuPercent = float64(busy-in.prevBusy) / float64(wall) / float64(runtime.NumCPU()) * 100
		}
		if disk >= in.prevDisk && wall > 0 {
			in.diskPerSec = float64(disk-in.prevDisk) / wall.Seconds()
		}
	}
	in.prevBusy, in.prevDisk, in.prevSampleAt = busy, disk, now
	return nil
}

// deleteManagedData removes the Service's managed data directory after the
// full filesystem proof (10.4). Only managed storage is auto-removable:
// memory has nothing on disk, and a custom path is user property.
func (javaServiceEngine) deleteManagedData(m *manager, sc ServiceConfig) error {
	if sc.Storage.Mode != ServiceStorageManaged {
		return nil
	}
	own, err := serviceProveManagedDir(sc)
	if err != nil {
		return err
	}
	if _, serr := os.Stat(own); serr != nil {
		if os.IsNotExist(serr) {
			return nil // nothing left to delete
		}
		return fmt.Errorf("inspect managed data: %w", serr)
	}
	if err := os.RemoveAll(own); err != nil {
		return fmt.Errorf("remove managed data: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Docker-based engines: shared lifecycle, per-engine launch specs
// ---------------------------------------------------------------------------

// dockerServiceEngineBase carries the lifecycle shared by the two docker-based
// engines; each is distinguished only by its launch-spec builder.
type dockerServiceEngineBase struct {
	kind  ServiceEngine
	build func(m *manager, sc ServiceConfig) (serviceLaunch, error)
}

func (b dockerServiceEngineBase) engine() ServiceEngine { return b.kind }

func (b dockerServiceEngineBase) buildLaunch(m *manager, sc ServiceConfig) (serviceLaunch, error) {
	return b.build(m, sc)
}

func (b dockerServiceEngineBase) start(m *manager, sc ServiceConfig, in *instance) error {
	spec, err := b.build(m, sc)
	if err != nil {
		return err
	}
	// Inspect before spawn: only exact labels allow replacing what lives under
	// the name. A stranger container holding our name is a hard error —
	// spawn's pre-cleaning rm would otherwise kill it. An owned-and-running
	// container means the reconcile pass missed nothing WE can start over;
	// fail closed instead of doubling up.
	if exists, owned, running := inspectServiceContainer(spec.bin, spec.container, sc); exists {
		if !owned {
			return fmt.Errorf("%w: container %q exists without matching ownership labels", errResourceUnowned, spec.container)
		}
		if running {
			return fmt.Errorf("invalid transition: container %q is already running", spec.container)
		}
	}
	if sc.Storage.Mode != ServiceStorageMemory {
		if err := ensureServiceVolume(spec.bin, sc); err != nil {
			return err
		}
	}
	armLaunch(in, spec, sc)
	return in.spawn()
}

// inspectOwned proves the container is ours by exact labels, then reports
// whether it runs. A same-name stranger is not ours.
func (b dockerServiceEngineBase) inspectOwned(m *manager, sc ServiceConfig) (bool, error) {
	docker, ok := svcDockerBin()
	if !ok {
		return false, nil
	}
	name := serviceContainerName(b.kind, sc.ID)
	_, owned, running := inspectServiceContainer(docker, name, sc)
	return owned && running, nil
}

// stop removes the container, which makes the foreground `docker run` CLI exit
// on its own; terminate() handles both halves.
func (b dockerServiceEngineBase) stop(m *manager, sc ServiceConfig, in *instance) error {
	if in != nil {
		in.terminate()
	}
	return nil
}

func (b dockerServiceEngineBase) logs(m *manager, sc ServiceConfig, in *instance) ([]string, error) {
	if in == nil {
		return []string{}, nil
	}
	// The foreground docker-run CLI streams container output into our pipes,
	// so the instance log IS the container log.
	return in.snapshotLogs(), nil
}

// sample reads `docker stats` for the Service's container, mirroring
// samplerLoop's container branch.
func (b dockerServiceEngineBase) sample(m *manager, sc ServiceConfig, in *instance) error {
	if in == nil {
		return nil
	}
	in.mu.Lock()
	cont, bin, running := in.container, in.bin, in.status == "running"
	in.mu.Unlock()
	if !running || cont == "" {
		return nil
	}
	cpu, mem, disk, err := sampleContainer(bin, cont)
	if err != nil {
		return nil
	}
	now := time.Now()
	in.mu.Lock()
	defer in.mu.Unlock()
	in.cpuPercent, in.memBytes = cpu/float64(runtime.NumCPU()), mem
	if !in.prevSampleAt.IsZero() && disk >= in.prevDisk {
		if wall := now.Sub(in.prevSampleAt).Seconds(); wall > 0 {
			in.diskPerSec = float64(disk-in.prevDisk) / wall
		}
	}
	in.prevDisk, in.prevSampleAt = disk, now
	return nil
}

// deleteManagedData removes the Service's managed volume, refusing when
// ownership cannot be proven. Custom volumes are user property; memory has no
// volume. Stage 8 adds the cross-mount check.
func (b dockerServiceEngineBase) deleteManagedData(m *manager, sc ServiceConfig) error {
	if sc.Storage.Mode != ServiceStorageManaged {
		return nil
	}
	docker, ok := svcDockerBin()
	if !ok {
		return fmt.Errorf("docker not available: cannot prove volume ownership")
	}
	return removeOwnedServiceVolume(docker, sc)
}

// ---------------------------------------------------------------------------
// Docker DynamoDB Local launch spec
// ---------------------------------------------------------------------------

const dockerDdbImage = "amazon/dynamodb-local"

// buildDockerDdbLaunch resolves the `docker run` argv for one Service:
// ID-scoped name, the ownership quartet as labels, host port → container 8000,
// and (non-memory storage) the Service's own volume mounted at /data.
func buildDockerDdbLaunch(m *manager, sc ServiceConfig) (serviceLaunch, error) {
	docker, ok := svcDockerBin()
	if !ok {
		return serviceLaunch{}, fmt.Errorf("docker not available (install Docker, or switch to the Java engine)")
	}
	if sc.Storage.Mode == ServiceStorageCustom && sc.Storage.Volume == "" {
		return serviceLaunch{}, fmt.Errorf("docker services need a volume name for custom storage")
	}
	name := serviceContainerName(ServiceEngineDockerDDB, sc.ID)
	a := []string{"run", "--rm", "--name", name}
	for _, l := range serviceLabelPairs(sc) {
		a = append(a, "--label", l)
	}
	a = append(a, "-p", fmt.Sprintf("%d:8000", sc.Port))
	if sc.Storage.Mode != ServiceStorageMemory {
		// DynamoDB Local runs as a non-root user in the image; writing to a
		// mounted volume needs -u root (same as the legacy singleton path).
		a = append(a, "-v", sc.Storage.Volume+":/data", "-u", "root")
	}
	a = append(a, dockerDdbImage, "-jar", "DynamoDBLocal.jar")
	if sc.Storage.Mode != ServiceStorageMemory {
		a = append(a, "-dbPath", "/data", "-sharedDb")
	} else {
		a = append(a, "-inMemory", "-sharedDb")
	}
	return serviceLaunch{bin: docker, args: a, container: name}, nil
}

// ---------------------------------------------------------------------------
// LocalStack launch spec
// ---------------------------------------------------------------------------

// localstackFixedServices is the ONLY service set this feature may enable.
// Broadening it would expand the app's AWS surface beyond the feature's scope,
// so overriding it via engine options is rejected at build time.
const localstackFixedServices = "dynamodb"

// buildLocalstackLaunch resolves the `docker run` argv for one LocalStack
// Service: ls-prefixed ID-scoped name, ownership labels, host port → container
// 4566, SERVICES pinned to dynamodb, remaining engine options as env in
// deterministic order, and (non-memory storage) the Service's own volume with
// PERSISTENCE=1.
func buildLocalstackLaunch(m *manager, sc ServiceConfig) (serviceLaunch, error) {
	docker, ok := svcDockerBin()
	if !ok {
		return serviceLaunch{}, fmt.Errorf("docker not available")
	}
	if _, ok := sc.EngineOptions["SERVICES"]; ok {
		return serviceLaunch{}, fmt.Errorf("engine option SERVICES is fixed to %q and cannot be overridden", localstackFixedServices)
	}
	if sc.Storage.Mode == ServiceStorageCustom && sc.Storage.Volume == "" {
		return serviceLaunch{}, fmt.Errorf("localstack services need a volume name for custom storage")
	}
	name := serviceContainerName(ServiceEngineLocalStack, sc.ID)
	a := []string{"run", "--rm", "--name", name}
	for _, l := range serviceLabelPairs(sc) {
		a = append(a, "--label", l)
	}
	a = append(a, "-p", fmt.Sprintf("%d:4566", sc.Port))
	a = append(a, "-e", "SERVICES="+localstackFixedServices)
	keys := make([]string, 0, len(sc.EngineOptions))
	for k := range sc.EngineOptions {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		a = append(a, "-e", fmt.Sprintf("%s=%v", k, sc.EngineOptions[k]))
	}
	if sc.Storage.Mode != ServiceStorageMemory {
		a = append(a, "-v", sc.Storage.Volume+":/var/lib/localstack", "-e", "PERSISTENCE=1")
	}
	a = append(a, localstackImage)
	return serviceLaunch{bin: docker, args: a, container: name}, nil
}
