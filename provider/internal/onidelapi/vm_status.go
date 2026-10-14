package onidelapi

// IsSettling reports whether a VM in status s settles into active on its own, so a
// caller waits on it instead of failing.
func (s VMStatus) IsSettling() bool {
	switch s {
	case VMStatusBuilding, VMStatusRestoring, VMStatusMigrating, VMStatusTakingSnaphot, VMStatusTakingSnapshot:
		return true
	}
	return false
}

// IsGone reports whether status s means the VM is destroyed, should the API keep
// listing it. The spec documents none of these; the overlay adds them.
func (s VMStatus) IsGone() bool {
	switch s {
	case VMStatusTerminated, VMStatusDeleted, VMStatusDestroyed:
		return true
	}
	return false
}
