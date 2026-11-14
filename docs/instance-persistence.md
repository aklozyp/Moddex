# Instance configuration persistence

Instance creation (including `/api/v1/instance/bootstrap`) and instance updates
save `instance.json` through the same writer. The directory layout, JSON format,
instance ID, and lookup behavior are unchanged; renaming an instance still does
not move its directory. Creation assigns the instance ID server-side and ignores
any client-supplied ID; the generated ID is checked against already persisted
IDs, and the instance directory is reserved by an atomic create so concurrent
creations with the same name never share a directory.

The backend serializes into a uniquely created pending file next to the live
configuration, closes the output, then atomically replaces `instance.json`.
Readers therefore see either the previous complete configuration or the new
complete configuration, never the pending serialization. A failed serialization,
write, close, or atomic replacement leaves the previous file byte-for-byte
unchanged. If no configuration existed, the failure leaves it absent. The
installer is not invoked when the initial configuration cannot be saved.

The writer removes only its own pending file on success or failure. If cleanup
itself fails, a safe warning is logged. A process interruption can also leave a
pending `.instance.json-*.pending` file, which is not read as an instance
configuration. Check directory permissions and remove such leftovers only while
the backend is stopped.

A failed initial creation rolls back instead of leaving a half-built instance:
the reserved instance directory is removed (its configuration first), so it can
neither be listed, resolved, nor started, and the reserved name is free for a
retry. Before the removal, a diagnosis record with the instance identity, the
failed phase, and the safe guided failure detail is written under
`instance-creation-failures/` in the backend logs directory, so the failed job
stays diagnosable even after the directory is gone; raw exception details are
never recorded. Rollback problems are logged with a safe next action and never
mask the original creation failure. Instance updates never roll back: their
failure handling keeps the previous configuration unchanged.

On POSIX filesystems, overwrites preserve the previous configuration's owner,
group, and POSIX permission bits. These attributes are applied to the pending
file before publication; failure to preserve them aborts the save without
replacing the old file. On non-POSIX filesystems, the owner is preserved when a
file-owner attribute view is available; portable group preservation is not
available there. This does not copy custom ACLs or extended attributes: use
backend-owned instance configurations and directory-inherited access policies.
New files use the platform's temporary-file ownership and permissions (owner-only
permissions on POSIX). The backend service account needs permission to read the
old file, preserve its ownership and permissions, and create, remove, and replace
files in the instance directory. Do not grant elevated backend privileges merely
to override an ownership error; repair the instance's ownership while stopped.

An existing final-component `instance.json` symbolic link is readable as before,
but saves now reject it with HTTP 500 rather than silently replacing the link or
modifying its referent. The link, its destination, and the destination's contents
remain unchanged. While the backend is stopped, migrate such configurations to
an ordinary `instance.json` file before saving. Parent-directory symbolic links
remain supported: the pending file and destination are in the same resolved
directory, and the directory link itself is not replaced.

Filesystems must support atomic replacement; there is no non-atomic/direct-write
fallback.
Atomic publication is not a promise of power-loss durability: files and
directories are not explicitly fsynced. Concurrent updates are not serialized or
merged, and separate backend processes/external editors are not coordinated.

Persistence failures return HTTP 500, not a successful create/update. Logs give
safe guidance to check the instance directory, permissions, ownership, symbolic
links, and filesystem atomic-replacement support before retrying. Raw
serialization/I/O exception messages and their potentially sensitive configuration
values are not exposed in these failures. Repair malformed configurations from a known-good backup
while the backend is stopped.

## Regression tests

From `backend`, run:

```sh
bash ./mvnw -Dtest=InstanceServiceTest,InstanceConfigPersistenceTest,SetupControllerTest test
```

The persistence tests use explicitly owned fixtures under `backend/target`,
real JSON and file writes, and production service/controller entrypoints.
Coverage includes initial creation and overwrite, partial serialization/output
and close failures, denied and unsupported atomic replacement, a real failed
replacement, byte-for-byte preservation or absent targets, controlled cleanup,
safe HTTP failures, POSIX permissions/ownership and failed attribute preservation,
final-component symlink rejection, parent-directory symlinks, readers during
paused serialization, and the creation rollback with its diagnosis records. A
supplementary-group test exercises a different group
when the test account can assign one, otherwise that test is explicitly skipped.
Setup tests also cover the shared pending-file lifecycle without changing
first-admin locking, strict reads, stale-settings protection, or HTTP contracts.
