# Initial administrator setup

The backend stores the administrator password hash in `serversettings.json`
inside its configured configuration directory. Setup is required only when the
stored hash is missing, empty, or whitespace. An existing nonblank hash is never
replaced by the setup endpoint.

## One-time bootstrap proof

Setup additionally requires a local, one-time bootstrap proof (issue #265), so
the first client that reaches a fresh installation can no longer claim the
administrator account from a remote machine. While the stored hash is missing,
empty, or whitespace, the backend keeps a random 256-bit proof in
`setup-bootstrap-token.json` inside its configuration directory with
owner-only POSIX permissions (`rw-------`). The proof is only available
locally: it is never logged, never returned by any endpoint, and never included
in error responses.

Rules:

- The proof is regenerated at every startup while setup is still required, so a
  proof from an earlier session never works. A configured installation issues
  no proof; a leftover proof file is removed at startup.
- A proof older than 24 hours is rejected as expired. If setup takes longer,
  restart the backend to generate a fresh proof.
- The proof is consumed atomically with the first-admin commit under the same
  settings monitor: parallel setup requests with the same proof produce one
  success and conflicts, and a replay after a successful setup is blocked by
  the installed-administrator check. A failed persistence attempt does not
  consume the proof, so the documented retry can succeed with the same proof.
- The pre-existing rule is unchanged: setup still runs only when no nonblank
  administrator hash is installed, and the proof never affects sign-in of an
  existing administrator.

## Concurrency and persistence

Within the backend process, the first-admin check and settings commit share the
same lock as other settings writes and default-settings initialization. Parallel
`POST /api/v1/setup/complete` requests with different valid passwords therefore
produce one success and one conflict; only the successful request's password can
authenticate.

Ordinary settings updates reread the current settings under that lock and retain
any installed nonblank administrator hash. A snapshot read before setup, or a
settings PUT with an omitted, blank, or different hash, cannot undo or replace
the winning credential. Other settings changes still apply normally. If the
existing settings cannot be read, writes fail closed rather than persisting a
fallback/default snapshot over the installed state.

Settings are serialized to a pending file in the configuration directory before
an atomic replacement of `serversettings.json`. A failed serialization or atomic
replacement does not truncate the previous settings or install a partial
password hash. Filesystems must support atomic replacement; there is deliberately
no non-atomic fallback. Run a single backend process per configuration directory:
the in-process lock does not coordinate separate JVMs or external file editors.

## HTTP contract and recovery

- `GET /api/v1/setup/status` returns `{"setupRequired": true|false}`.
- Successful completion returns HTTP 200 with `{"message":"Setup completed"}`.
  `POST /api/v1/setup/complete` requires `{"password": "...", "bootstrapToken":
  "<one-time proof>"}`.
- A password shorter than eight characters returns HTTP 400 with
  `{"error":"Password must be at least 8 characters"}`.
- A missing, wrong, expired, or already used bootstrap proof returns HTTP 403
  with a message that names the problem and the safe next action: read the
  current proof from `setup-bootstrap-token.json` in the configuration
  directory on the server host, enter it in the setup form, and retry; if the
  file is missing or the proof is expired or already used, restart the backend
  to generate a new proof. The response never contains the proof itself.
- An already configured administrator returns HTTP 409 with
  `{"error":"Setup already completed"}`. Sign in with the password that won
  setup instead of retrying another password. This response is also used for
  repeated setup after a restart.
- Unreadable/malformed settings or failed persistence return HTTP 500, not 409,
  with a safe instruction to check the configuration and directory permissions
  before retrying. Setup status also returns HTTP 500 when existing settings
  cannot be read; it must not report a configured installation as a new one.

If the proof file cannot be written (for example because the configuration
directory is not writable), the backend logs a warning and setup requests fail
closed with HTTP 403 until the directory is repaired and the backend is
restarted. On platforms without POSIX permissions, ensure the configuration
directory itself is access-restricted.

Check that the backend service account can read the existing settings and create
and replace files in the configuration directory. Repair malformed settings from
a known-good backup while the backend is stopped. Do not delete an installed
password hash to work around an I/O error. Error responses and setup logs do not
include submitted passwords, password hashes, provider keys, or raw serialization
errors.

## Password change and session revocation

`POST /api/v1/auth/change-password` changes the administrator credential and
revokes sessions issued before the change (issue #267). The route sits under
`/api/v1/auth` but is explicitly authenticated: requests without a valid bearer
token are rejected by the security chain, not by controller logic. The request
carries `currentPassword` and `newPassword`. A successful change verifies the
current password, then stores the new hash and bumps a persistent
`passwordRevision` in `serversettings.json` under the settings write lock in
one atomic replacement. Newly issued tokens embed that revision as a claim;
token validation rejects tokens whose revision is older than the persisted one,
so previously issued sessions stop working immediately. The revision is a
counter rather than a comparison against JWT `iat`, because `iat` only has
second granularity and would misjudge a login issued in the same second as the
change. The revision survives restarts and keeps enforcing in a restarted
process; process-bound signing keys already invalidate all tokens across
restarts. The response contains no new token; clients sign in again.

- New password shorter than eight characters: HTTP 400.
- Wrong current password: HTTP 401 with a safe instruction. Nothing is revoked
  and the previous credential stays valid.
- No installed credential: HTTP 403 ("Setup required"). If the installed
  credential changed between verification and commit, the change is refused
  with HTTP 409 instead of overwriting a credential the caller never saw.
- Unreadable or unwritable settings: HTTP 500 with a safe instruction; token
  validation fails closed while settings cannot be read.

Ordinary settings updates preserve the installed hash and revision and never
revoke sessions; a settings snapshot sent by a client cannot move either value.
Every successful credential change (including initial setup) logs a structured
`AUTH_SESSIONS_REVOKED` event with reason, the pseudonymous actor, and the new
revision. This timestamped log line is the revocation record; no dedicated
audit subsystem exists yet. Protected routes answer unauthenticated or revoked
requests with HTTP 401 and a body naming the safe next action
(`errorKind: AUTH_REQUIRED`, "sign in again"). Permit-all routes such as login
and setup stay reachable with an attached revoked token, so signing in with the
new password works. No password, hash, or token ever appears in these
responses or log lines.

## Native TLS configuration

The backend serves HTTPS natively. TLS stays off unless `MODDEX_TLS_ENABLED`
is set to `true`; plain HTTP remains fully supported. The documented
environment contract:

- `MODDEX_TLS_ENABLED`: `true` or `false` (any other value fails startup with
  a safe instruction).
- PEM variant: `MODDEX_TLS_CERT_FILE` (certificate chain) and
  `MODDEX_TLS_KEY_FILE` (matching private key). Both files are required
  together.
- Keystore variant: `MODDEX_TLS_KEYSTORE` plus `MODDEX_TLS_KEYSTORE_PASSWORD`
  and `MODDEX_TLS_KEYSTORE_TYPE` (default `PKCS12`).

Enabling TLS without usable key material, or pointing a variable at a missing
or unreadable file, aborts the startup before the server binds; there is no
silent fallback to HTTP. The effective port is `SERVER_PORT` in both modes.
The mapping runs as an early environment post-processor, so the values are
checked before any listener opens.

The `install.sh` installer manages these settings in
`/etc/moddex/moddex.env`, which the systemd unit reads via
`EnvironmentFile=-/etc/moddex/moddex.env` (mode 0600). Activating TLS writes
the file; reinstalling without TLS options preserves it; `--no-tls` removes
it. A reinstall without an explicit port keeps the effective port of the
existing installation. Ensure the `moddex` service account can read the
referenced certificate, key, and keystore files. Values are double quoted;
avoid double quotes inside paths and the keystore password.

The Moddex CLI (`backend/bin/moddex`) derives its backend URL from the same
configuration: it uses HTTPS when `MODDEX_TLS_ENABLED=true` is stored in
`/etc/moddex/moddex.env` and plain HTTP otherwise. The port comes from
`SERVER_PORT` in the systemd unit (default 8080). HTTPS requests verify
against the certificate chain configured as `MODDEX_TLS_CERT_FILE`, or against
a CA file set via `MODDEX_CLI_CA_FILE`; verification is never disabled, and a
missing or untrusted CA fails with a safe instruction instead of an insecure
fallback. Reading the TLS configuration requires permission to read the
environment file (mode 0600); the CLI never guesses the URL scheme silently.

## Regression tests

From `backend`, run `bash ./mvnw -Dtest=SetupControllerTest,SetupBootstrapProofServiceTest test`.
The tests use isolated state under `backend/target`, real settings serialization
and BCrypt hashing, and Spring MVC request handling without starting a live
service. Barriers coordinate competing requests with different passwords.
Coverage includes the winning persisted password, HTTP 409 for the loser and
repeated setup, blank legacy hashes, stale-snapshot and settings-PUT credential
preservation, corrupt-file write refusal, safe read/I/O/partial-write failures,
atomic-move failure cleanup with unchanged live settings, unchanged installed
credentials, and successful retry after repairing a failure.
Atomic-move failures are injected at the replacement call after real
serialization; pending-file cleanup and unchanged live settings are verified on
disk.

The bootstrap proof contract is covered by `SetupBootstrapProofServiceTest`
(proof file with owner-only permissions, fresh randomness per issuance,
invalidation of a previous proof, missing/corrupt/expired rejection, safe
invalid-proof guidance without the proof, startup issuance only while setup is
required, proof consumption with the first-admin commit, proof survival across
a failed persistence attempt) and by `SetupControllerTest` (HTTP 403 with
guided message and no stored hash for missing, blank, wrong, expired, and
absent-field proofs; consumption and blocked replay after a successful setup;
proof regeneration after a simulated restart; unchanged HTTP 409 blocking for a
configured installation).

Session revocation (issue #267) is covered by
`bash ./mvnw -Dtest=PasswordRevocationStampTest,AuthSessionRevocationTest test`.
`PasswordRevocationStampTest` checks the revision stamp: credential changes
bump it, previously issued tokens stop validating, ordinary settings updates
never revoke and never trust a client-supplied revision, the compare-and-set
refuses concurrent changes, a simulated restart keeps enforcing the persisted
stamp, and the audit event never contains secret material.
`AuthSessionRevocationTest` drives the HTTP contract end to end over a real
server: setup with the current local bootstrap proof, login, change with
revocation and guided 401, re-login with the new password, failed changes
revoking nothing, and the audit entries in the log file.

The TLS contract is covered by `TlsEnvironmentPostProcessorTest` (mapping of
the `MODDEX_TLS_*` variables onto the native `server.ssl` properties, missing
or invalid key material failing with safe instructions) and by the CI-tagged
`NativeTlsStartTest`, which starts the backend natively over HTTPS with a
generated certificate and serves the setup status endpoint. From `scripts`,
the installer side is covered by `bash tests/test-install-tls.sh` (env-file
contract, preservation on reinstall, `--no-tls` removal, safe failure paths,
port preservation) alongside `bash tests/test-install-port.sh`. The CLI URL
and CA behavior is covered by `bash tests/test-cli-tls-url.sh` (plain HTTP
mode unchanged, verified HTTPS with status and login against a fixture server
with a generated self-signed certificate, missing CA, keystore variant with
the `MODDEX_CLI_CA_FILE` override, safe failure messages without secrets).
