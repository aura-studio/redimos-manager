package main

// v1.2 data model: a former Config is two things — a redimos proxy Instance and
// the DynamoDB Endpoint (backend) it targets. The manager still keeps []Config
// in memory (so all launch / DDB-client / table-ops code is unchanged); only the
// ON-DISK shape splits into endpoints[]+instances[], with endpoints deduplicated
// by their backend tuple so many instances can share one backend. A legacy
// pre-1.2 configs[] file is read once on upgrade and rewritten in the new shape.

import (
	"fmt"
	"hash/fnv"
	"net/url"
	"strings"
)

// Endpoint is the DynamoDB-target half of a former Config: connection +
// credentials, shared across instances pointing at the same backend.
type Endpoint struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Kind         string `json:"kind"` // "local" | "aws" | "url"
	Endpoint     string `json:"endpoint"`
	PartitionID  string `json:"partitionID"`
	Region       string `json:"region"`
	AccessKeyID  string `json:"accessKeyId"`
	SecretKey    string `json:"secretKey"`
	SessionToken string `json:"sessionToken"`
	Source       string `json:"source"`
}

// Instance is the redimos-proxy half of a former Config: process/redis settings,
// the table it serves, and a reference to its Endpoint.
type Instance struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	Version         string   `json:"version"`
	Port            int      `json:"port"`
	Table           string   `json:"table"`
	EndpointID      string   `json:"endpointId"`
	MultiDB         bool     `json:"multiDb"`
	AutoCreateTable bool     `json:"autoCreateTable"`
	AutoRestart     bool     `json:"autoRestart"`
	RunMode         string   `json:"runMode"`
	Requirepass     string   `json:"requirepass"`
	ExtraFlags      []FlagKV `json:"extraFlags"`
}

// diskStore is the on-disk shape. load/persist translate between it and the
// in-memory store (which keeps []Config). Legacy configs[] is a read-only
// fallback for upgrading a pre-1.2 store.json.
type diskStore struct {
	Endpoints       []Endpoint     `json:"endpoints,omitempty"`
	Instances       []Instance     `json:"instances,omitempty"`
	Configs         []Config       `json:"configs,omitempty"` // legacy (pre-1.2) fallback
	Settings        Settings       `json:"settings"`
	LocalDdb        LocalDdbConfig `json:"localDdb"`
	Formatters      []Formatter    `json:"formatters,omitempty"`
	AutoStart       []string       `json:"autoStart"`
	DdbAutoStart    bool           `json:"ddbAutoStart"`
	StopAllSnapshot []string       `json:"stopAllSnapshot"`
}

// endpointKind classifies a backend by its endpoint URL: no URL => online AWS;
// a loopback URL => the local DynamoDB; any other URL => a custom endpoint.
func endpointKind(endpoint string) string {
	if strings.TrimSpace(endpoint) == "" {
		return "aws"
	}
	if isLoopbackEndpoint(endpoint) {
		return "local"
	}
	return "url"
}

func isLoopbackEndpoint(endpoint string) bool {
	host := endpoint
	if u, err := url.Parse(endpoint); err == nil && u.Host != "" {
		host = u.Hostname()
	}
	host = strings.ToLower(strings.TrimSpace(host))
	return strings.Contains(host, "localhost") || strings.HasPrefix(host, "127.") ||
		host == "::1" || host == "[::1]"
}

// endpointTuple identifies a backend for deduplication: two configs with the
// same tuple map to one Endpoint.
func endpointTuple(c *Config) string {
	return strings.Join([]string{
		c.Endpoint, c.PartitionID, c.Region, c.AccessKeyID, c.SecretKey, c.SessionToken, c.Source,
	}, "\x00")
}

func endpointDisplayName(c *Config, kind string) string {
	switch kind {
	case "aws":
		if strings.TrimSpace(c.Region) != "" {
			return c.Region
		}
		return "aws"
	case "local":
		return "local"
	default:
		if u, err := url.Parse(c.Endpoint); err == nil && u.Host != "" {
			return u.Host
		}
		return c.Endpoint
	}
}

// splitConfigs derives the endpoints[]+instances[] form from the in-memory
// Configs, deduplicating endpoints by their backend tuple. Endpoint IDs are a
// deterministic hash of the tuple, so the same backend keeps the same id across
// saves.
func splitConfigs(configs []Config) ([]Endpoint, []Instance) {
	var eps []Endpoint
	byTuple := map[string]string{} // tuple -> endpoint id
	usedName := map[string]bool{}
	insts := make([]Instance, 0, len(configs))
	for i := range configs {
		c := &configs[i]
		tuple := endpointTuple(c)
		epID, ok := byTuple[tuple]
		if !ok {
			kind := endpointKind(c.Endpoint)
			h := fnv.New32a()
			_, _ = h.Write([]byte(tuple))
			epID = fmt.Sprintf("ep-%08x", h.Sum32())
			eps = append(eps, Endpoint{
				ID:           epID,
				Name:         uniqueName(endpointDisplayName(c, kind), usedName),
				Kind:         kind,
				Endpoint:     c.Endpoint,
				PartitionID:  c.PartitionID,
				Region:       c.Region,
				AccessKeyID:  c.AccessKeyID,
				SecretKey:    c.SecretKey,
				SessionToken: c.SessionToken,
				Source:       c.Source,
			})
			byTuple[tuple] = epID
		}
		insts = append(insts, Instance{
			ID:              c.ID,
			Name:            c.Name,
			Version:         c.Version,
			Port:            c.Port,
			Table:           c.Table,
			EndpointID:      epID,
			MultiDB:         c.MultiDB,
			AutoCreateTable: c.AutoCreateTable,
			AutoRestart:     c.AutoRestart,
			RunMode:         c.RunMode,
			Requirepass:     c.Requirepass,
			ExtraFlags:      c.ExtraFlags,
		})
	}
	return eps, insts
}

func uniqueName(base string, used map[string]bool) string {
	if strings.TrimSpace(base) == "" {
		base = "endpoint"
	}
	name := base
	for n := 2; used[name]; n++ {
		name = fmt.Sprintf("%s-%d", base, n)
	}
	used[name] = true
	return name
}

// mergeToConfigs reconstructs the in-memory Config list from the split form. An
// instance whose endpoint is missing falls back to the zero (online-AWS) backend.
func mergeToConfigs(eps []Endpoint, insts []Instance) []Config {
	byID := make(map[string]Endpoint, len(eps))
	for _, e := range eps {
		byID[e.ID] = e
	}
	out := make([]Config, 0, len(insts))
	for _, in := range insts {
		e := byID[in.EndpointID]
		out = append(out, Config{
			ID:              in.ID,
			Name:            in.Name,
			Version:         in.Version,
			Port:            in.Port,
			Table:           in.Table,
			Endpoint:        e.Endpoint,
			PartitionID:     e.PartitionID,
			Region:          e.Region,
			AccessKeyID:     e.AccessKeyID,
			SecretKey:       e.SecretKey,
			SessionToken:    e.SessionToken,
			Source:          e.Source,
			MultiDB:         in.MultiDB,
			AutoCreateTable: in.AutoCreateTable,
			AutoRestart:     in.AutoRestart,
			RunMode:         in.RunMode,
			Requirepass:     in.Requirepass,
			ExtraFlags:      in.ExtraFlags,
		})
	}
	return out
}
