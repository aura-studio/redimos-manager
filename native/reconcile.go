package main

// Boot reconciliation: resolve the children registry a previous session left
// behind. For every record, decide dead / stranger / ours, and kill what
// provably belongs to a dead session. (The adoption pass — keeping an eligible
// Local DynamoDB alive instead of killing it — plugs in here.)
//
// This is the precise replacement for the path-substring heuristic: identity is
// (pid, start-µs, comm) for native children and the container name/label for
// docker ones, so a user's own copy of the same binary can never be hit, and
// none of it depends on PPID semantics (works unchanged on Windows).
//
// Runs once at boot, under the single-instance lock.
func (m *manager) reconcileOnBoot() {
	for _, rec := range regSnapshot() {
		if rec.Container != "" {
			// Container children: the container (not the long-dead CLI pid) is
			// the real process; sweepLabeledContainers removes foreign-session
			// containers by label. Here only the bookkeeping goes.
			regRemove(rec.Role)
			continue
		}
		start, comm, ok := procIdentity(rec.PID)
		if !ok || start != rec.StartUnixMicro || comm != rec.Comm {
			regRemove(rec.Role) // dead, or the pid was recycled by a stranger
			continue
		}
		// Verified orphan of a dead session (were its manager alive, we could
		// not hold the single-instance lock).
		killChildTree(rec.PID)
		regRemove(rec.Role)
	}
}
