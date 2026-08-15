package main

// Service is a first-class local server entity, peer to Instance and Endpoint.
// It manages ONE local DynamoDB-compatible process or container. Services are
// strictly independent of Endpoints (which are client-connection concepts): no
// auto-create, prefill, binding, or port-based inference ties the two.
//
// Identity is an immutable UUID assigned by the manager; every cross-layer call
// (FFI, registry role, container name, managed data path, volume) is keyed by
// that ID so many Services can coexist without colliding.

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// ServiceEngine selects how a Service runs locally.
type ServiceEngine string

const (
	ServiceEngineJava       ServiceEngine = "java"       // java -jar DynamoDBLocal.jar
	ServiceEngineDockerDDB  ServiceEngine = "docker"     // docker run amazon/dynamodb-local
	ServiceEngineLocalStack ServiceEngine = "localstack" // docker run localstack/localstack
)

// ServiceStorageMode controls where a Service keeps its data.
type ServiceStorageMode string

const (
	// memory keeps data only in-process (the dev-table default); no managed data
	// is written, so there is nothing to auto-clean on delete.
	ServiceStorageMemory ServiceStorageMode = "memory"
	// managed writes data under the app's own root, keyed by Service ID — the
	// only mode whose data the app may delete automatically.
	ServiceStorageManaged ServiceStorageMode = "managed"
	// custom uses a user-supplied external location; auto-deletion is always
	// refused for custom storage.
	ServiceStorageCustom ServiceStorageMode = "custom"
)

// ServiceStorage is the data-location block of a ServiceConfig.
type ServiceStorage struct {
	Mode   ServiceStorageMode `json:"mode"`
	Path   string             `json:"path,omitempty"`   // java: data directory
	Volume string             `json:"volume,omitempty"` // docker/localstack: volume name
}

// ServiceConfig is the persisted, user-visible shape of a Service. It deliberately
// does NOT carry transient runtime state (pid, container id, metrics) — those are
// rebuilt by reconcile/probes and belong to ServiceRuntime, not the store.
type ServiceConfig struct {
	ID             string         `json:"id"`
	Name           string         `json:"name"`
	Engine         ServiceEngine  `json:"engine"`
	Port           int            `json:"port"` // 0 = engine default (8000 / 4566)
	Storage        ServiceStorage `json:"storage"`
	EngineOptions  map[string]any `json:"engineOptions,omitempty"`
	DesiredRunning bool           `json:"desiredRunning"`
}

// GlobalStopSnapshot is the typed Stop All / Restore All snapshot: Instance IDs
// and Service IDs are kept in separate namespaces so restore never confuses the
// two. Persisted under the new key stopAllSnapshotV2 (the legacy string-array
// stopAllSnapshot stays a read-only, never-written field).
type GlobalStopSnapshot struct {
	Instances []string `json:"instances,omitempty"`
	Services  []string `json:"services,omitempty"`
}

// empty reports whether the snapshot carries nothing to restore.
func (s GlobalStopSnapshot) empty() bool { return len(s.Instances) == 0 && len(s.Services) == 0 }

// ---------------------------------------------------------------------------
// ID-scoped resource naming. Every derived name embeds the Service ID so two
// Services cannot collide on a container, volume, or data path. The ID is the
// authoritative ownership token; names are only a convenience layer on top.
// ---------------------------------------------------------------------------

// serviceManagedRootForTest redirects the managed root into a test sandbox so
// unit tests never touch the live ~/.redimos state.
var serviceManagedRootForTest string

// serviceManagedRoot is the directory under which managed Service data lives.
func serviceManagedRoot() string {
	if serviceManagedRootForTest != "" {
		return serviceManagedRootForTest
	}
	return filepath.Join(filepath.Dir(defaultStorePath()), "services")
}

// serviceDataDir is the default managed data directory for a java Service.
func serviceDataDir(id string) string {
	return filepath.Join(serviceManagedRoot(), id, "ddb-data")
}

// serviceVolumeName is the default managed volume for a docker/localstack Service.
func serviceVolumeName(id string) string {
	return "redimos-service-" + id + "-data"
}

// serviceContainerName is the ID-scoped container name. The container's labels
// (not its name) are the ownership proof, but the name keeps `docker ps` legible.
func serviceContainerName(engine ServiceEngine, id string) string {
	if engine == ServiceEngineLocalStack {
		return "redimos-service-ls-" + id
	}
	return "redimos-service-" + id
}

// serviceRolePrefix heads every Service children-registry role; the full role
// is serviceRolePrefix + immutable Service ID.
const serviceRolePrefix = "service:"

// serviceRole is the children-registry role for a Service child.
func serviceRole(id string) string { return serviceRolePrefix + id }

// ---------------------------------------------------------------------------
// Normalization and validation
// ---------------------------------------------------------------------------

// normalizeServiceName canonicalizes a display name for uniqueness comparison:
// trim + case-fold (Unicode-aware).
func normalizeServiceName(name string) string {
	return strings.ToLower(strings.TrimSpace(name))
}

// normalizeService fills in engine/storage/port defaults and resolves managed
// locations keyed by the Service ID. It never invents an ID — the caller must
// have assigned one (create) or preserved it (update).
func normalizeService(c ServiceConfig) ServiceConfig {
	if c.Engine == "" {
		c.Engine = ServiceEngineDockerDDB
	}
	if c.Storage.Mode == "" {
		c.Storage.Mode = ServiceStorageMemory
	}
	if c.Port == 0 {
		if c.Engine == ServiceEngineLocalStack {
			c.Port = 4566
		} else {
			c.Port = 8000
		}
	}
	if c.Storage.Mode == ServiceStorageManaged {
		switch c.Engine {
		case ServiceEngineJava:
			if strings.TrimSpace(c.Storage.Path) == "" {
				c.Storage.Path = serviceDataDir(c.ID)
			}
		default: // docker / localstack
			if strings.TrimSpace(c.Storage.Volume) == "" {
				c.Storage.Volume = serviceVolumeName(c.ID)
			}
		}
	}
	return c
}

// validateServiceConfig enforces the Core-side safety boundary. Client-side form
// validation only gives instant feedback; this is the authoritative check. [all]
// is the full Service collection the candidate would live among.
func validateServiceConfig(c *ServiceConfig, all []ServiceConfig) error {
	if strings.TrimSpace(c.Name) == "" {
		return fmt.Errorf("name is required")
	}
	switch c.Engine {
	case ServiceEngineJava, ServiceEngineDockerDDB, ServiceEngineLocalStack:
	default:
		return fmt.Errorf("engine must be java|docker|localstack")
	}
	if c.Port < 0 || c.Port > 65535 {
		return fmt.Errorf("port must be 0..65535")
	}
	switch c.Storage.Mode {
	case ServiceStorageMemory, ServiceStorageManaged, ServiceStorageCustom:
	default:
		return fmt.Errorf("storage mode must be memory|managed|custom")
	}
	// Custom storage must actually point somewhere.
	if c.Storage.Mode == ServiceStorageCustom {
		switch c.Engine {
		case ServiceEngineJava:
			if strings.TrimSpace(c.Storage.Path) == "" {
				return fmt.Errorf("custom storage requires a data path")
			}
		default:
			if strings.TrimSpace(c.Storage.Volume) == "" {
				return fmt.Errorf("custom storage requires a volume name")
			}
		}
	}
	// Engine options must be flat scalars: they become argv/env/label material
	// downstream, so nested structures and empty keys are rejected here.
	for k, v := range c.EngineOptions {
		if strings.TrimSpace(k) == "" {
			return fmt.Errorf("engine option key must not be empty")
		}
		switch v.(type) {
		case string, float64, bool:
		default:
			return fmt.Errorf("engine option %q must be a string, number, or boolean", k)
		}
	}
	norm := normalizeServiceName(c.Name)
	for i := range all {
		o := &all[i]
		if o.ID == c.ID {
			continue // same Service: not a conflict with itself
		}
		if normalizeServiceName(o.Name) == norm {
			return fmt.Errorf("name %q is already in use by Service %s", c.Name, o.ID)
		}
		if o.Port != 0 && c.Port != 0 && o.Port == c.Port {
			return fmt.Errorf("port %d is already configured by Service %s", c.Port, o.ID)
		}
	}
	return nil
}

// findService locates a ServiceConfig by ID in the collection.
func findService(all []ServiceConfig, id string) (*ServiceConfig, int) {
	for i := range all {
		if all[i].ID == id {
			return &all[i], i
		}
	}
	return nil, -1
}

// newServiceID assigns the immutable Service identity. It comes from the
// manager's random ID pool and is deliberately NOT derived from the display
// name, port, path, or engine — renames and reconfiguration never change it.
func newServiceID() string { return newID() }

// sortServices orders a collection for listing: normalized name first, with a
// deterministic ID tie-break so the order is stable across refreshes.
func sortServices(list []ServiceConfig) {
	sort.SliceStable(list, func(i, j int) bool {
		ni, nj := normalizeServiceName(list[i].Name), normalizeServiceName(list[j].Name)
		if ni != nj {
			return ni < nj
		}
		return list[i].ID < list[j].ID
	})
}

// ---------------------------------------------------------------------------
// Fault-tolerant decode of the persisted services collection.
// ---------------------------------------------------------------------------

// decodeServices parses the "services" array out of a store.json payload whose
// non-Service entities have already decoded successfully. A corrupt services
// field — wrong shape, bad entries, duplicate identities — must never wipe the
// rest of the store: readable entries survive, each problem is reported, and
// the caller persists the cleaned collection on the next save.
func decodeServices(b []byte) ([]ServiceConfig, []string) {
	var wrap struct {
		Services []json.RawMessage `json:"services"`
	}
	if err := json.Unmarshal(b, &wrap); err != nil {
		// The surrounding file decoded (the caller only reaches us after a
		// successful diskStore unmarshal), so only the services key itself is
		// unreadable — e.g. a string where an array belongs.
		return nil, []string{"services: field is not a readable array; ignored"}
	}
	entries := make([]ServiceConfig, 0, len(wrap.Services))
	var errs []string
	for i, raw := range wrap.Services {
		var sc ServiceConfig
		if err := json.Unmarshal(raw, &sc); err != nil {
			errs = append(errs, fmt.Sprintf("services[%d]: unreadable entry (%v); skipped", i, err))
			continue
		}
		entries = append(entries, sc)
	}
	clean, sanErrs := sanitizeLoadedServices(entries)
	return clean, append(errs, sanErrs...)
}

// sanitizeLoadedServices rejects persisted Service entries that cannot be
// trusted: missing identity, invalid engine/port/storage, and duplicate IDs,
// normalized names, or ports. The FIRST valid holder of an identity wins; later
// conflicts are dropped with a diagnostic rather than silently merged.
func sanitizeLoadedServices(entries []ServiceConfig) ([]ServiceConfig, []string) {
	var errs []string
	out := make([]ServiceConfig, 0, len(entries))
	seenID := map[string]bool{}
	seenName := map[string]bool{}
	seenPort := map[int]string{} // port -> owning service id
	for _, sc := range entries {
		label := sc.ID
		if strings.TrimSpace(label) == "" {
			label = sc.Name
		}
		if strings.TrimSpace(sc.ID) == "" {
			errs = append(errs, "service entry without an id; skipped")
			continue
		}
		if seenID[sc.ID] {
			errs = append(errs, fmt.Sprintf("service %s: duplicate id; skipped", sc.ID))
			continue
		}
		if strings.TrimSpace(sc.Name) == "" {
			errs = append(errs, fmt.Sprintf("service %s: empty name; skipped", sc.ID))
			continue
		}
		switch sc.Engine {
		case ServiceEngineJava, ServiceEngineDockerDDB, ServiceEngineLocalStack:
		default:
			errs = append(errs, fmt.Sprintf("service %s: unknown engine %q; skipped", sc.ID, sc.Engine))
			continue
		}
		if sc.Port < 0 || sc.Port > 65535 {
			errs = append(errs, fmt.Sprintf("service %s: invalid port %d; skipped", sc.ID, sc.Port))
			continue
		}
		switch sc.Storage.Mode {
		case "", ServiceStorageMemory, ServiceStorageManaged, ServiceStorageCustom:
			// "" predates the storage block; normalization resolves it later.
		default:
			errs = append(errs, fmt.Sprintf("service %s: unknown storage mode %q; skipped", sc.ID, sc.Storage.Mode))
			continue
		}
		nm := normalizeServiceName(sc.Name)
		if seenName[nm] {
			errs = append(errs, fmt.Sprintf("service %s (%s): duplicate name; skipped", sc.ID, label))
			continue
		}
		if sc.Port != 0 {
			if owner, ok := seenPort[sc.Port]; ok {
				errs = append(errs, fmt.Sprintf("service %s: port %d already used by service %s; skipped", sc.ID, sc.Port, owner))
				continue
			}
			seenPort[sc.Port] = sc.ID
		}
		seenID[sc.ID] = true
		seenName[nm] = true
		out = append(out, sc)
	}
	return out, errs
}
