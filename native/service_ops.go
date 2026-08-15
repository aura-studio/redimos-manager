package main

// Mutation layer for the persisted Service collection: create/update behind the
// Core-side validation boundary, with atomic persist and rollback on write
// failure so an invalid or unwritable save leaves ZERO side effects.

import (
	"fmt"
	"reflect"
)

// createServiceConfig validates, normalizes, assigns the immutable ID, and
// atomically persists a new Service. The manager — never the caller — chooses
// the ID; any ID present in the request payload is discarded.
func (m *manager) createServiceConfig(c ServiceConfig) (ServiceConfig, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c.ID = newServiceID()
	c = normalizeService(c)
	if err := validateServiceConfig(&c, m.st.Services); err != nil {
		return ServiceConfig{}, err
	}
	m.st.Services = append(m.st.Services, c)
	if err := m.persist(); err != nil {
		// Roll back the in-memory append so a failed write has zero side effects.
		m.st.Services = m.st.Services[:len(m.st.Services)-1]
		return ServiceConfig{}, err
	}
	// The new Service immediately owns a runtime carrier so lifecycle ops can
	// address it by ID.
	m.svcEnsureRuntime(c.ID)
	return c, nil
}

// updateServiceConfig replaces the configuration of the Service addressed by
// id. Identity rules:
//
//   - the ID is immutable — a payload carrying a different id is rejected;
//   - while the Service is running, the fields that define its process or
//     container identity (engine, port, storage) cannot change until it is
//     stopped; display name and options may change.
//
// The caller supplies isRunning from the runtime registry (unknown until the
// Service runtime lands; the check is wired to the live state at that point).
func (m *manager) updateServiceConfig(id string, c ServiceConfig, isRunning bool) (ServiceConfig, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if c.ID != "" && c.ID != id {
		return ServiceConfig{}, fmt.Errorf("service id is immutable: cannot change %q to %q", id, c.ID)
	}
	prev, idx := findService(m.st.Services, id)
	if prev == nil {
		return ServiceConfig{}, fmt.Errorf("service %s not found", id)
	}
	c.ID = id
	c = normalizeService(c)
	if isRunning {
		if c.Engine != prev.Engine {
			return ServiceConfig{}, fmt.Errorf("service %s is running: stop it before changing the engine", id)
		}
		if c.Port != prev.Port {
			return ServiceConfig{}, fmt.Errorf("service %s is running: stop it before changing the port", id)
		}
		if !reflect.DeepEqual(c.Storage, prev.Storage) {
			return ServiceConfig{}, fmt.Errorf("service %s is running: stop it before changing storage", id)
		}
	}
	if err := validateServiceConfig(&c, m.st.Services); err != nil {
		return ServiceConfig{}, err
	}
	saved := m.st.Services[idx]
	m.st.Services[idx] = c
	if err := m.persist(); err != nil {
		m.st.Services[idx] = saved // roll back: no partial configuration survives
		return ServiceConfig{}, err
	}
	return c, nil
}
