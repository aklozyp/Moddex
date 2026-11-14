#!/usr/bin/env bash
set -Eeuo pipefail

# Issue #186: local regression for the release gate core (scripts/release-gate.sh).
# The digest verification, the archive staging and the failure paths run against
# real fixture files; the virtual-machine part (downloader invocation, systemd
# service, HTTP probe) is replaced by controlled stubs over a closed PATH. The
# real installer, service manager and backend are never started here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.release-gate-test.$$"
BASH_BIN="$(command -v bash)"
TAR_BIN="$(command -v tar)"
SHA256SUM_BIN="$(command -v sha256sum)"
RM_BIN="$(command -v rm)"

TEST_TAG="v0.1.2-gate-fixture"
TEST_STUB_PORT="18099"
# Case-local switches; every case sets exactly what it needs and resets the rest.
TEST_SYSTEMCTL_ACTIVE=1
TEST_CURL_BODY=""
TEST_GATE_TIMEOUT=180

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ ! -e "$TEST_DIR" ]] || fail "Test directory already exists: $TEST_DIR"
mkdir "$TEST_DIR"
cleanup() {
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.release-gate-test.* &&
    -d "$TEST_DIR" && ! -L "$TEST_DIR" ]]; then
    "$RM_BIN" -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT

# --- Stub host: closed PATH with real read/build tools and VM stubs ----------

# gzip is deliberately part of the closed PATH: GNU tar shells out to the gzip
# binary for -z operations, while macOS bsdtar decompresses in-process. The
# gate's tar -tzf/-tvzf/-xzf calls would fail under a closed PATH without it
# on GNU/Linux; the same helper is allowed in the downloader regression.
mkdir "$TEST_DIR/bin"
for command in bash cat cp dirname gzip grep mkdir mktemp rm sed sleep tail tar sha256sum; do
  ln -s "$(command -v "$command")" "$TEST_DIR/bin/$command"
done

# The VM stubs record every call, so the tests can assert that the gate stops
# before any installation or service interaction.
cat > "$TEST_DIR/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'systemctl %s\n' "$*" >> "$TEST_CASE_DIR/commands"
case "$*" in
  "is-active moddex-backend.service")
    if [[ "${TEST_SYSTEMCTL_ACTIVE:-1}" == 1 ]]; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
  "cat moddex-backend.service")
    cat "$MODDEX_GATE_UNIT_FILE"
    exit 0
    ;;
  "status moddex-backend.service")
    printf '%s\n' 'moddex-backend.service - Moddex Backend API'
    printf '%s\n' '     Loaded: loaded (/etc/systemd/system/moddex-backend.service; enabled)'
    printf '%s\n' "     Active: ${TEST_SYSTEMD_STATUS_STATE:-active} (running)"
    printf '%s\n' '   Main PID: 4711 (java)'
    exit 0
    ;;
  *) exit 91 ;;
esac
SH

cat > "$TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'curl %s\n' "$*" >> "$TEST_CASE_DIR/commands"
if [[ "$1" == "-v" ]]; then
  printf '%s\n' "*   Trying 127.0.0.1:${TEST_STUB_PORT}..."
  printf '%s\n' "curl: (7) Failed to connect to 127.0.0.1 port ${TEST_STUB_PORT} after 0 ms: Connection refused"
  exit 7
fi
[[ "$1" == "-fsS" ]] || exit 91
body="${TEST_CURL_BODY:-}"
if [[ -z "$body" ]]; then
  body='{"setupRequired":true}'
fi
printf '%s\n' "$body"
exit "${TEST_CURL_EXIT:-0}"
SH

# The diagnosis dump calls journalctl and ss; both are stubbed so the dump
# output is deterministic on every host (the gate's unavailable-source branch
# is defensive code for hosts without these tools).
cat > "$TEST_DIR/bin/journalctl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'journalctl %s\n' "$*" >> "$TEST_CASE_DIR/commands"
printf '%s\n' 'moddex-backend[4711]: simulated journal line for the diagnosis dump'
exit 0
SH

cat > "$TEST_DIR/bin/ss" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ss %s\n' "$*" >> "$TEST_CASE_DIR/commands"
printf '%s\n' 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port'
printf '%s\n' 'LISTEN 0      128        127.0.0.1:22      0.0.0.0:*'
exit 0
SH

# Java, sudo, apt-get and update-alternatives stubs for the gate-host java
# preparation. Two different javas simulate the run 43512932003 split: the
# SHELL java on the PATH (temurin-21 on the runner) must never be probed by
# the gate, while the UNIT java (passed as MODDEX_GATE_UNIT_JAVA) reports the
# version recorded in the case's unit-java-version state file (default 17, a
# clean host); the alternatives stub --set switches that state to 17,
# simulating the real correction of /usr/bin/java.
cat > "$TEST_DIR/bin/java" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'java %s\n' "$*" >> "$TEST_CASE_DIR/commands"
state="$TEST_CASE_DIR/shell-java-version"
if [[ ! -f "$state" ]]; then
  printf '21\n' > "$state"
fi
printf 'openjdk version "%s.0.28" 2026-01-20\n' "$(cat "$state")" >&2
printf '%s\n' 'OpenJDK Runtime Environment (fixture)'
exit 0
SH

cat > "$TEST_DIR/unit-java" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'unit-java %s\n' "$*" >> "$TEST_CASE_DIR/commands"
if [[ "${TEST_UNIT_JAVA_MISSING:-0}" == 1 ]]; then
  exit 127
fi
state="$TEST_CASE_DIR/unit-java-version"
if [[ ! -f "$state" ]]; then
  printf '17\n' > "$state"
fi
printf 'openjdk version "%s.0.28" 2026-01-20\n' "$(cat "$state")" >&2
printf '%s\n' 'OpenJDK Runtime Environment (fixture)'
exit 0
SH

cat > "$TEST_DIR/bin/sudo" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'sudo %s\n' "$*" >> "$TEST_CASE_DIR/commands"
# Simulates passwordless sudo by running the command through the stub PATH:
# sudo's own flags (-n, ...) are dropped and leading VAR=value arguments are
# exported for the command, matching sudo's environment handling.
while [[ "${1:-}" == -* ]]; do
  shift
done
while [[ "${1:-}" == *"="* && "$1" != -* ]]; do
  export "$1"
  shift
done
exec "$@"
SH

cat > "$TEST_DIR/bin/apt-get" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'apt-get %s\n' "$*" >> "$TEST_CASE_DIR/commands"
[[ "${1:-}" == "install" ]] || exit 91
exit "${TEST_APT_EXIT:-0}"
SH

cat > "$TEST_DIR/bin/update-alternatives" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'update-alternatives %s\n' "$*" >> "$TEST_CASE_DIR/commands"
case "${1:-}" in
  --list)
    printf '%s\n' '/usr/lib/jvm/java-11-openjdk/bin/java'
    if [[ "${TEST_ALTERNATIVES_NO_CANDIDATE:-0}" != 1 ]]; then
      printf '%s\n' '/usr/lib/jvm/java-17-openjdk/bin/java'
    fi
    ;;
  --set)
    [[ "$2" == "java" && "$3" == /usr/lib/jvm/java-17-openjdk/bin/java ]] || exit 91
    printf '17\n' > "$TEST_CASE_DIR/unit-java-version"
    ;;
  *) exit 91 ;;
esac
exit 0
SH

chmod +x "$TEST_DIR/bin/systemctl" "$TEST_DIR/bin/curl" \
  "$TEST_DIR/bin/journalctl" "$TEST_DIR/bin/ss" \
  "$TEST_DIR/bin/java" "$TEST_DIR/bin/sudo" \
  "$TEST_DIR/bin/apt-get" "$TEST_DIR/bin/update-alternatives" \
  "$TEST_DIR/unit-java"

# Replaces the published downloader for the installation step. It performs the
# assertions the gate relies on downstream (pinned VERSION env, staged bundle
# present), writes the systemd unit the gate reads afterwards, and marks the
# host as installed.
cat > "$TEST_DIR/stub-install.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'install-script %s\n' "$*" >> "$TEST_CASE_DIR/commands"
[[ "${1:-}" == "--install-staged" && "${3:-}" == "--mode" && "${4:-}" == "local" ]] || {
  printf 'unexpected install arguments: %s\n' "$*" >&2
  exit 91
}
[[ "${VERSION:-}" == "$TEST_EXPECTED_TAG" ]] || {
  printf 'unexpected VERSION environment\n' >&2
  exit 91
}
[[ -f "$2/bundle/VERSION" ]] || {
  printf 'staged bundle is missing VERSION\n' >&2
  exit 91
}
cat "$2/bundle/VERSION" > "$TEST_CASE_DIR/staged-version"
mkdir -p "$(dirname "$MODDEX_GATE_UNIT_FILE")"
printf 'Environment=SERVER_ADDRESS=127.0.0.1\nEnvironment=SERVER_PORT=%s\n' \
  "$TEST_STUB_PORT" > "$MODDEX_GATE_UNIT_FILE"
: > "$TEST_CASE_DIR/installed"
SH
chmod +x "$TEST_DIR/stub-install.sh"

# --- Fixture helpers ---------------------------------------------------------

# Builds a release artifact set exactly like the release workflow's preparation
# step: tar.gz with "./"-relative entries, the zip artifact with the published
# name, the downloader copy, the per-asset checksums and the summary SHA256SUMS.
# The gate digest-verifies the published zip but never unpacks it, so the
# fixture ships deterministic placeholder bytes instead of depending on a zip
# implementation being installed on the test host (Debian test runners have no
# zip binary; macOS and GNU/Linux coreutils both provide everything else).
make_release_fixture() {
  local case_dir="$1" src release archive_name
  src="$case_dir/bundle-src"
  release="$case_dir/release"
  archive_name="moddex-${TEST_TAG}-linux-amd64"
  mkdir -p "$src/backend/bin" "$src/frontend" "$src/scripts" "$src/packaging/systemd"
  printf '%s\n' "$TEST_TAG" > "$src/VERSION"
  printf 'backend:%s\n' "$TEST_TAG" > "$src/backend/Moddex-Backend.jar"
  printf 'backend-cli\n' > "$src/backend/bin/moddex"
  printf '<html></html>\n' > "$src/frontend/index.html"
  printf '#!/usr/bin/env bash\n' > "$src/scripts/install.sh"
  cp "$PROJECT_ROOT/packaging/systemd/moddex-backend.service" \
    "$src/packaging/systemd/moddex-backend.service"
  cp "$PROJECT_ROOT/scripts/download.sh" "$release/download.sh"
  "$TAR_BIN" -C "$src" -czf "$release/$archive_name.tar.gz" .
  printf 'Moddex release fixture: the zip payload is never unpacked by the gate.\n' \
    > "$release/$archive_name.zip"
  (
    cd "$release"
    "$SHA256SUM_BIN" "$archive_name.tar.gz" > "$archive_name.tar.gz.sha256"
    "$SHA256SUM_BIN" "$archive_name.zip" > "$archive_name.zip.sha256"
    "$SHA256SUM_BIN" "download.sh" > "download.sh.sha256"
    "$SHA256SUM_BIN" "$archive_name.tar.gz" "$archive_name.zip" download.sh > SHA256SUMS
  )
  : > "$case_dir/commands"
}

# Replaces the bundle payload and recomputes every checksum for the real
# artifact names, so the case exercises exactly one gate phase.
rebuild_archive_from_payload() {
  local case_dir="$1" release archive_name
  release="$case_dir/release"
  archive_name="moddex-${TEST_TAG}-linux-amd64"
  "$TAR_BIN" -C "$case_dir/bundle-src" -czf "$release/$archive_name.tar.gz" .
  refresh_checksums "$case_dir"
}

# Recomputes every per-asset checksum and the summary from the existing
# artifacts, mirroring the release workflow's preparation step.
refresh_checksums() {
  local case_dir="$1" release archive_name
  release="$case_dir/release"
  archive_name="moddex-${TEST_TAG}-linux-amd64"
  (
    cd "$release"
    "$SHA256SUM_BIN" "$archive_name.tar.gz" > "$archive_name.tar.gz.sha256"
    "$SHA256SUM_BIN" "$archive_name.zip" > "$archive_name.zip.sha256"
    "$SHA256SUM_BIN" "download.sh" > "download.sh.sha256"
    "$SHA256SUM_BIN" "$archive_name.tar.gz" "$archive_name.zip" download.sh > SHA256SUMS
  )
}

run_gate() {
  local case_dir="$1"
  (
    export PATH="$TEST_DIR/bin"
    export TEST_CASE_DIR="$case_dir" TEST_EXPECTED_TAG="$TEST_TAG" TEST_STUB_PORT
    export MODDEX_GATE_STAGE_ROOT="$case_dir/stage"
    export MODDEX_GATE_INSTALL_SCRIPT="$TEST_DIR/stub-install.sh"
    export MODDEX_GATE_UNIT_FILE="$case_dir/unit/moddex-backend.service"
    export MODDEX_GATE_UNIT_JAVA="$TEST_DIR/unit-java"
    export MODDEX_GATE_SERVICE_TIMEOUT="$TEST_GATE_TIMEOUT"
    export TEST_SYSTEMCTL_ACTIVE="$TEST_SYSTEMCTL_ACTIVE"
    export TEST_CURL_BODY="$TEST_CURL_BODY" TEST_CURL_EXIT="${TEST_CURL_EXIT:-0}"
    export TEST_ALTERNATIVES_NO_CANDIDATE="${TEST_ALTERNATIVES_NO_CANDIDATE:-0}"
    "$BASH_BIN" "$PROJECT_ROOT/scripts/release-gate.sh" \
      "$case_dir/release" "$TEST_TAG" > "$case_dir/output" 2>&1
  )
}

assert_gate_failed() {
  # The gate must fail with the expected reason, name a safe next action and
  # never reach the installation or the service probe. Digest and archive
  # validation failures additionally leave nothing unpacked.
  local name="$1" expected_reason="$2" case_dir="$3" expect_no_extraction="${4:-yes}" status=0
  run_gate "$case_dir" || status=$?
  [[ "$status" -ne 0 ]] || fail "$name: gate unexpectedly passed."
  grep -Fq "$expected_reason" "$case_dir/output" ||
    { cat "$case_dir/output" >&2; fail "$name: error message misses the reason."; }
  grep -Fq "Do not publish this release" "$case_dir/output" ||
    fail "$name: error message misses the safe next action."
  [[ ! -e "$case_dir/installed" ]] ||
    fail "$name: gate reached the installation despite the expected failure."
  if [[ "$expect_no_extraction" == "yes" && -e "$case_dir/stage/bundle" ]]; then
    fail "$name: gate extracted the archive despite the expected failure."
  fi
  if [[ -e "$case_dir/unit/moddex-backend.service" ]]; then
    fail "$name: a systemd unit was written despite the expected failure."
  fi
  if grep -Fq "install-script" "$case_dir/commands"; then
    fail "$name: the stub installer ran despite the expected failure."
  fi
  if grep -Fq "curl" "$case_dir/commands"; then
    fail "$name: the service probe ran despite the expected failure."
  fi
  return 0
}

case_count=0

# --- Case 1: success path ----------------------------------------------------
# Digests match, the archive stages and installs through the stubbed
# downloader, and the stubbed service is active and reachable with setup
# pending; the gate reports published == computed and the probed URL.
case_dir="$TEST_DIR/gate-success"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
run_gate "$case_dir" ||
  { cat "$case_dir/output" >&2; fail "gate-success: gate failed on a complete, matching release."; }
digest="$("$SHA256SUM_BIN" "$case_dir/release/moddex-${TEST_TAG}-linux-amd64.tar.gz")"
digest="${digest%% *}"
grep -Fq "published == computed == $digest" "$case_dir/output" ||
  fail "gate-success: output does not document the matching digest."
grep -Fq "SHA256SUMS verification passed" "$case_dir/output" ||
  fail "gate-success: output does not document the summary checksum verification."
grep -Fq "Staged bundle VERSION matches the release tag" "$case_dir/output" ||
  fail "gate-success: output does not document the staged VERSION check."
[[ "$(cat "$case_dir/staged-version")" == "$TEST_TAG" ]] ||
  fail "gate-success: installed bundle carries an unexpected VERSION."
[[ -e "$case_dir/installed" ]] ||
  fail "gate-success: the stub installer never ran."
grep -Fq "install-script --install-staged" "$case_dir/commands" ||
  fail "gate-success: the downloader was not invoked in staged-install mode."
grep -Fq "Service moddex-backend.service is active" "$case_dir/output" ||
  fail "gate-success: output does not document the service state."
grep -Fq "Backend reachable at http://127.0.0.1:$TEST_STUB_PORT/api/v1/setup/status" "$case_dir/output" ||
  fail "gate-success: output does not document the probed backend URL."
grep -Fq '"setupRequired":true' "$case_dir/output" ||
  fail "gate-success: output does not document the fresh-host setup status."
grep -Fq "Release gate passed" "$case_dir/output" ||
  fail "gate-success: gate does not report success."
grep -Fq "no preparation needed" "$case_dir/output" ||
  fail "gate-success: preparation does not report the clean-host skip."
if grep -Fq "update-alternatives" "$case_dir/commands"; then
  fail "gate-success: the gate changed java alternatives although the unit java is already >= 17."
fi
if grep -Fq "apt-get" "$case_dir/commands"; then
  fail "gate-success: the gate ran apt although the unit java is already >= 17."
fi
if grep -Eq '(^| )java -version' "$case_dir/commands"; then
  fail "gate-success: the gate probed the shell java instead of the unit java."
fi
case_count=$((case_count + 1))

# --- Case 2: digest mismatch against the per-asset checksum ------------------
# The archive changes after its per-asset checksum was written (the summary is
# regenerated, so exactly the published per-asset record is stale).
case_dir="$TEST_DIR/digest-mismatch"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
printf 'corrupted\n' >> "$case_dir/release/moddex-${TEST_TAG}-linux-amd64.tar.gz"
(
  cd "$case_dir/release"
  "$SHA256SUM_BIN" "moddex-${TEST_TAG}-linux-amd64.tar.gz" \
    "moddex-${TEST_TAG}-linux-amd64.zip" download.sh > SHA256SUMS
)
assert_gate_failed digest-mismatch "Digest mismatch for" "$case_dir"
grep -Fq "computed" "$case_dir/output" &&
  grep -Fq "published" "$case_dir/output" ||
  fail "digest-mismatch: output does not name both digests."
case_count=$((case_count + 1))

# --- Case 3: summary checksum verification fails -----------------------------
# The archive is corrupted and no checksum is updated: sha256sum -c SHA256SUMS
# must fail before any extraction.
case_dir="$TEST_DIR/checksum-summary-failure"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
printf 'corrupted\n' >> "$case_dir/release/moddex-${TEST_TAG}-linux-amd64.tar.gz"
assert_gate_failed checksum-summary-failure \
  "Published checksum verification failed" "$case_dir"
case_count=$((case_count + 1))

# --- Case 4: per-asset checksum names a different file ------------------------
case_dir="$TEST_DIR/checksum-wrong-name"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
"$SHA256SUM_BIN" "$case_dir/release/download.sh" \
  > "$case_dir/release/moddex-${TEST_TAG}-linux-amd64.tar.gz.sha256"
assert_gate_failed checksum-wrong-name \
  "does not contain exactly one SHA-256 record" "$case_dir"
case_count=$((case_count + 1))

# --- Case 5: traversal entry in the archive ----------------------------------
# GNU tar sanitizes member names at create time; -P keeps "../" verbatim
# (bsdtar stores them as typed either way). The payload keeps the core
# entries, so exactly the traversal rejection fires.
case_dir="$TEST_DIR/traversal-entry"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
payload="$case_dir/malcontent/payload"
mkdir -p "$payload"
cp -R "$case_dir/bundle-src/." "$payload/"
printf 'outside the extraction root\n' > "$case_dir/malcontent/escape-target"
"$TAR_BIN" -P -C "$payload" -czf \
  "$case_dir/release/moddex-${TEST_TAG}-linux-amd64.tar.gz" . ../escape-target
refresh_checksums "$case_dir"
assert_gate_failed traversal-entry \
  "contains a parent-directory path component" "$case_dir"
case_count=$((case_count + 1))

# --- Case 6: escaping link target in the archive ------------------------------
# Symlink targets are stored verbatim by GNU tar and bsdtar. The gate must run
# the same link-target check as the published downloader (which
# --install-staged deliberately skips) and reject a link that points outside
# the bundle directory before anything is unpacked or installed.
case_dir="$TEST_DIR/escaping-link"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
ln -s /etc/moddex/moddex.env "$case_dir/bundle-src/escaping-link"
rebuild_archive_from_payload "$case_dir"
assert_gate_failed escaping-link \
  "points outside the bundle directory" "$case_dir"
case_count=$((case_count + 1))

# --- Case 7: incomplete bundle (missing frontend entry) ----------------------
case_dir="$TEST_DIR/missing-required-entry"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
"$RM_BIN" "$case_dir/bundle-src/frontend/index.html"
rebuild_archive_from_payload "$case_dir"
assert_gate_failed missing-required-entry \
  "required entry frontend/index.html is missing" "$case_dir"
case_count=$((case_count + 1))

# --- Case 8: staged VERSION does not match the release tag --------------------
# The archive is complete and matches its checksums; the mismatch is detected
# after extraction, so the bundle directory exists, but nothing is installed.
case_dir="$TEST_DIR/version-mismatch"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
printf 'v9.9.9-other\n' > "$case_dir/bundle-src/VERSION"
rebuild_archive_from_payload "$case_dir"
assert_gate_failed version-mismatch \
  "does not match the release tag" "$case_dir" no
[[ -e "$case_dir/stage/bundle/VERSION" ]] ||
  fail "version-mismatch: the bundle was not staged although the failure happens after extraction."
case_count=$((case_count + 1))

# --- Case 9: service never becomes active ------------------------------------
# The stubbed service stays inactive; the gate must time out without running
# the HTTP probe loop, name the diagnostic next actions and dump the diagnosis
# sources (state, unit, environment keys, listeners, logs, journal, probe
# verdict) with the stable "diag:" prefix into the workflow log.
case_dir="$TEST_DIR/service-never-active"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
TEST_SYSTEMCTL_ACTIVE=0
TEST_GATE_TIMEOUT=2
status=0
run_gate "$case_dir" || status=$?
TEST_SYSTEMCTL_ACTIVE=1
TEST_GATE_TIMEOUT=180
[[ "$status" -ne 0 ]] || fail "service-never-active: gate passed with an inactive service."
grep -Fq "did not become active" "$case_dir/output" ||
  fail "service-never-active: error message misses the inactive service reason."
grep -Fq "The diagnosis above shows the service state" "$case_dir/output" ||
  fail "service-never-active: error message does not point at the dumped diagnosis."
grep -Fq "diag: service state: inactive" "$case_dir/output" ||
  fail "service-never-active: diagnosis misses the service state."
grep -Fq "diag: unit: Environment=SERVER_PORT=$TEST_STUB_PORT" "$case_dir/output" ||
  fail "service-never-active: diagnosis misses the installed unit."
grep -Fq "diag: env: /etc/moddex/moddex.env not present" "$case_dir/output" ||
  fail "service-never-active: diagnosis misses the environment file report."
grep -Fq "diag: listener: nothing listening on port $TEST_STUB_PORT" "$case_dir/output" ||
  fail "service-never-active: diagnosis misses the listener report."
grep -Fq "diag: listener(all): LISTEN" "$case_dir/output" ||
  fail "service-never-active: diagnosis misses the full listener table."
grep -Fq "diag: journal: moddex-backend[4711]: simulated journal line" "$case_dir/output" ||
  fail "service-never-active: diagnosis misses the journal dump."
grep -Fq "diag: curl: curl: (7) Failed to connect" "$case_dir/output" ||
  fail "service-never-active: diagnosis misses the verbose probe verdict."
grep -Fq "diag: --- end of backend diagnosis ---" "$case_dir/output" ||
  fail "service-never-active: diagnosis dump is incomplete."
if grep -Fq "curl -fsS" "$case_dir/commands"; then
  fail "service-never-active: the HTTP probe loop ran although the service was inactive."
fi
case_count=$((case_count + 1))

# --- Case 10: backend reachable but setup not pending --------------------------
# A fresh installation must report setupRequired=true; anything else fails.
case_dir="$TEST_DIR/setup-not-required"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
TEST_CURL_BODY='{"setupRequired":false}'
status=0
run_gate "$case_dir" || status=$?
TEST_CURL_BODY=""
[[ "$status" -ne 0 ]] || fail "setup-not-required: gate passed with a configured host."
grep -Fq "setupRequired must be true on a fresh installation" "$case_dir/output" ||
  fail "setup-not-required: error message misses the setup-status reason."
case_count=$((case_count + 1))

# --- Case 11: relative release directory and default downloader path ----------
# The release workflow invokes the gate from the repository root as
# `bash gate-src/scripts/release-gate.sh release "${TARGET_REF}"`. A previous
# version resolved the downloader path relative to the starting directory
# only and then cd-ed into the release directory before invoking it, so the
# installer step failed on the runner ("bash: release/download.sh: No such
# file or directory"). This case reproduces the production call shape: the
# gate runs from another working directory with the RELATIVE release argument
# and WITHOUT the installer-script override, so the gate must use its default
# downloader path (here: the installer stub placed in the release directory).
# The stub marks the host as installed, which the broken resolution never
# reached.
case_dir="$TEST_DIR/downloader-path-independent-of-cwd"
mkdir "$case_dir" "$case_dir/workspace" "$case_dir/workspace/release"
make_release_fixture "$case_dir/workspace"
cp "$TEST_DIR/stub-install.sh" "$case_dir/workspace/release/download.sh"
refresh_checksums "$case_dir/workspace"
(
  cd "$case_dir/workspace"
  export PATH="$TEST_DIR/bin"
  export TEST_CASE_DIR="$case_dir/workspace" TEST_EXPECTED_TAG="$TEST_TAG" TEST_STUB_PORT
  export MODDEX_GATE_STAGE_ROOT="$case_dir/stage"
  export MODDEX_GATE_UNIT_FILE="$case_dir/unit/moddex-backend.service"
  export MODDEX_GATE_UNIT_JAVA="$TEST_DIR/unit-java"
  export MODDEX_GATE_SERVICE_TIMEOUT="$TEST_GATE_TIMEOUT"
  export TEST_SYSTEMCTL_ACTIVE="$TEST_SYSTEMCTL_ACTIVE"
  export TEST_CURL_BODY="$TEST_CURL_BODY" TEST_CURL_EXIT="${TEST_CURL_EXIT:-0}"
  export TEST_ALTERNATIVES_NO_CANDIDATE="${TEST_ALTERNATIVES_NO_CANDIDATE:-0}"
  unset MODDEX_GATE_INSTALL_SCRIPT
  "$BASH_BIN" "$PROJECT_ROOT/scripts/release-gate.sh" release "$TEST_TAG" \
    > "$case_dir/output" 2>&1
) || { cat "$case_dir/output" >&2; fail "downloader-path-independent-of-cwd: gate failed with a relative release directory."; }
[[ -e "$case_dir/workspace/installed" ]] ||
  fail "downloader-path-independent-of-cwd: the default downloader path never reached the installer stub."
grep -Fq "Bundled installer completed" "$case_dir/output" ||
  fail "downloader-path-independent-of-cwd: gate did not complete the installation."
grep -Fq "Release gate passed" "$case_dir/output" ||
  fail "downloader-path-independent-of-cwd: gate does not report success."
grep -Fq "install-script --install-staged" "$case_dir/workspace/commands" ||
  fail "downloader-path-independent-of-cwd: the stub was not invoked in staged-install mode."
case_count=$((case_count + 1))

# --- Case 12: service active, backend never answers ---------------------------
# GitHub run 43504524057 reached exactly this state: systemd reported the
# service as active, but the HTTP probe never received an answer within the
# timeout. The gate must dump the same diagnosis in this path, including the
# verbose probe verdict, so the workflow log shows why the backend stayed
# silent.
case_dir="$TEST_DIR/backend-never-answers"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
TEST_CURL_EXIT=7
TEST_GATE_TIMEOUT=2
status=0
run_gate "$case_dir" || status=$?
TEST_CURL_EXIT=0
TEST_GATE_TIMEOUT=180
[[ "$status" -ne 0 ]] || fail "backend-never-answers: gate passed although the backend never answered."
grep -Fq "The backend did not answer on" "$case_dir/output" ||
  fail "backend-never-answers: error message misses the unanswered backend reason."
grep -Fq "diag: service state: active" "$case_dir/output" ||
  fail "backend-never-answers: diagnosis misses the active service state."
grep -Fq "diag: listener: nothing listening on port $TEST_STUB_PORT" "$case_dir/output" ||
  fail "backend-never-answers: diagnosis misses the listener report."
grep -Fq "diag: curl: curl: (7) Failed to connect" "$case_dir/output" ||
  fail "backend-never-answers: diagnosis misses the verbose probe verdict."
grep -Fq "diag: --- end of backend diagnosis ---" "$case_dir/output" ||
  fail "backend-never-answers: diagnosis dump is incomplete."
case_count=$((case_count + 1))

# --- Case 13: stale UNIT java is corrected before the installation ------------
# GitHub runs 43509195319/43512932003: the runner image keeps /usr/bin/java on
# Java 11 (update-alternatives) while the shell PATH starts with a toolcache
# Java 21, and the freshly installed service crash-looped with
# UnsupportedClassVersionError while systemd kept reporting 'activating'. The
# gate must probe the UNIT java (/usr/bin/java), ensure the Java 17 runtime,
# pin the java-17 alternative and re-verify BEFORE the installer starts the
# service; the command spy proves both the ordering and that the shell java
# was never probed.
case_dir="$TEST_DIR/java-11-corrected"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
printf '11\n' > "$case_dir/unit-java-version"
run_gate "$case_dir" ||
  { cat "$case_dir/output" >&2; fail "java-11-corrected: gate failed although the stale unit java is correctable."; }
grep -Fq "unit-java -version" "$case_dir/commands" ||
  fail "java-11-corrected: the gate did not probe the unit java."
grep -Fq "openjdk-17-jre-headless" "$case_dir/commands" ||
  fail "java-11-corrected: the gate did not ensure the Java 17 runtime."
grep -Fq "update-alternatives --set java /usr/lib/jvm/java-17-openjdk/bin/java" "$case_dir/commands" ||
  fail "java-11-corrected: the gate did not pin the Java 17 alternative."
grep -Fq "Gate host java preparation completed" "$case_dir/output" ||
  fail "java-11-corrected: preparation does not report completion."
grep -Fq "reports version 17" "$case_dir/output" ||
  fail "java-11-corrected: preparation does not report the corrected version."
grep -Fq "Release gate passed" "$case_dir/output" ||
  fail "java-11-corrected: gate does not report success."
set_line="$(grep -n "update-alternatives --set java" "$case_dir/commands" | sed -n '1s/:.*//p')"
install_line="$(grep -n "install-script --install-staged" "$case_dir/commands" | sed -n '1s/:.*//p')"
[[ -n "$set_line" && -n "$install_line" && "$set_line" -lt "$install_line" ]] ||
  fail "java-11-corrected: the java correction did not run before the installation."
if grep -Eq '(^| )java -version' "$case_dir/commands"; then
  fail "java-11-corrected: the gate probed the shell java instead of the unit java."
fi
case_count=$((case_count + 1))

# --- Case 14: impossible java correction aborts with guidance ------------------
# When no java-17 alternative is registered and the unit java stays below 17,
# the preparation must abort with the reason and a safe next action BEFORE the
# installer changes the host.
case_dir="$TEST_DIR/java-correction-impossible"
mkdir "$case_dir" "$case_dir/release"
make_release_fixture "$case_dir"
printf '11\n' > "$case_dir/unit-java-version"
TEST_ALTERNATIVES_NO_CANDIDATE=1
status=0
run_gate "$case_dir" || status=$?
TEST_ALTERNATIVES_NO_CANDIDATE=0
[[ "$status" -ne 0 ]] ||
  fail "java-correction-impossible: gate passed although no Java 17 could be selected."
grep -Fq "could not select a Java 17 (or newer) runtime" "$case_dir/output" ||
  fail "java-correction-impossible: error message misses the unselectable runtime reason."
grep -Fq "update-alternatives --set java" "$case_dir/output" ||
  fail "java-correction-impossible: error message misses the safe next action."
grep -Fq "Do not publish this release" "$case_dir/output" ||
  fail "java-correction-impossible: error message misses the publish guard."
[[ ! -e "$case_dir/installed" ]] ||
  fail "java-correction-impossible: the installer ran although the java correction failed."
[[ ! -e "$case_dir/unit/moddex-backend.service" ]] ||
  fail "java-correction-impossible: a systemd unit was written although the java correction failed."
case_count=$((case_count + 1))

printf 'Release gate checks passed (%s cases; digest verification, staging, stubbed installation, service and setup evidence, and the pre-install failure paths are covered).\n' "$case_count"
