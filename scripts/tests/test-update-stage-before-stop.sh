#!/usr/bin/env bash
# Offline regression for issue #105: bash scripts/tests/test-update-stage-before-stop.sh
#
# Proves that the updater downloads, checksum-verifies, and stages the new
# release BEFORE stopping the running service, and that a failed download or
# verification never stops the service nor touches the installed version.
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TEST_DIR="$PROJECT_ROOT/.update-stage-before-stop-test.$$"
RM_BIN="$(command -v rm)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [[ -z "${2:-}" ]] || cat "$2" >&2
  exit 1
}

[[ ! -e "$TEST_DIR" ]] || fail "Test directory already exists: $TEST_DIR"
mkdir "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/bundle/scripts" "$TEST_DIR/install state"
UPDATER="$TEST_DIR/bundle/scripts/update.sh"
DOWNLOADER="$TEST_DIR/bundle/scripts/download.sh"
STAGE_DIR="$TEST_DIR/stage"
INSTALL_DIR="$TEST_DIR/install state"
EVENT_LOG="$TEST_DIR/events.log"
CWD_DIR="$TEST_DIR/arbitrary cwd"
mkdir "$CWD_DIR"

# Only the fixture redirects install paths and adapts the prompt on macOS Bash 3.
awk -v legacy_bash="$((BASH_VERSINFO[0] < 4))" '
  {
    versions += gsub(/\/opt\/moddex\/VERSION/, "\"${TEST_INSTALL_DIR}/VERSION\"")
    jars += gsub(/\/opt\/moddex\/app.jar/, "\"${TEST_INSTALL_DIR}/app.jar\"")
  }
  $0 == "  if [[ \"${a,,}\" == y* ]]; then" {
    if (legacy_bash) print "  if [[ \"$a\" == [yY]* ]]; then"
    else print
    prompt = 1
    next
  }
  { print }
  END { if (versions != 2 || jars != 1 || !prompt) exit 1 }
' "$PROJECT_ROOT/scripts/update.sh" > "$UPDATER"
chmod +x "$UPDATER"

# Real commands that only operate inside this fixture.
for cmd in awk tail tr sed grep mkdir; do
  ln -s "$(command -v "$cmd")" "$TEST_DIR/bin/$cmd"
done
ln -s "$(command -v bash)" "$TEST_DIR/bin/bash"

# The host lock (issue #108) is acquired before the updater stops the service:
# the closed fixture PATH needs flock (real where available, otherwise a perl
# stub with the same kernel-lock semantics) and the metadata timestamp.
if command -v flock >/dev/null 2>&1; then
  ln -s "$(command -v flock)" "$TEST_DIR/bin/flock"
else
  cat > "$TEST_DIR/bin/flock" <<'PERL'
#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(:flock);
my $op = '';
my $fd;
foreach my $arg (@ARGV) {
  if ($arg eq '-n' || $arg eq '-u' || $arg eq '-s' || $arg eq '-x') { $op ||= $arg; }
  elsif ($arg =~ /^\d+$/) { $fd = $arg; }
  else { exit 91; }
}
exit 91 unless defined $fd;
open(my $fh, '+<&=', $fd) or exit 1;
if ($op eq '-u') { flock($fh, LOCK_UN) or exit 1; exit 0; }
exit 0 if flock($fh, LOCK_EX | LOCK_NB);
exit 1;
PERL
  chmod +x "$TEST_DIR/bin/flock"
fi
ln -s "$(command -v date)" "$TEST_DIR/bin/date"

# Same hermetic dirname replacement as test-update-script-path.sh.
cat > "$TEST_DIR/bin/dirname" <<'SH'
#!/bin/sh
[ "${1:-}" = -- ] && shift
case "$1" in
  */*) printf '%s\n' "${1%/*}" ;;
  *) printf '.\n' ;;
esac
SH

# The latest-tag probe must resolve; every other curl use must fail.
cat > "$TEST_DIR/bin/curl" <<'SH'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = -fsSLI ] || exit 98
printf 'HTTP/2 302\r\nLocation: https://example.invalid/releases/tag/v9.8.7\r\n'
SH

# systemctl may only answer the installed-unit probe.
cat > "$TEST_DIR/bin/systemctl" <<'SH'
#!/bin/sh
[ "$*" = 'list-units --type=service --all' ] || exit 98
printf 'load5 moddex-backend.service loaded running\n'
SH

# The stop mock: its event position proves the ordering of the update run.
cat > "$TEST_DIR/bin/sudo" <<'SH'
#!/bin/sh
[ "$*" = 'systemctl stop moddex-backend' ] || exit 98
printf 'stop\n' >> "$EVENT_LOG"
SH

# The updater creates exactly one staging directory and removes only that one.
cat > "$TEST_DIR/bin/mktemp" <<'SH'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = -d ] && [ "$2" = -t ] && [ "$3" = moddex-update.XXXXXX ] || exit 91
mkdir "$STAGE_DIR"
printf '%s\n' "$STAGE_DIR"
SH

cat > "$TEST_DIR/bin/rm" <<'SH'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = -rf ] && [ "$2" = -- ] && [ "$3" = "$STAGE_DIR" ] || exit 91
exec "$TEST_RM_BIN" "$@"
SH

# The updater must never download or extract on its own.
for cmd in sha256sum tar wget; do
  cat > "$TEST_DIR/bin/$cmd" <<'SH'
#!/bin/sh
printf 'Unexpected command execution.\n' >&2
exit 98
SH
done
chmod +x "$TEST_DIR/bin/"*

# The staged downloader fixture records every phase in the shared event log:
# "stage" while staging, "stop" comes from the sudo mock, "install-staged"
# only after it finds the marker written by the completed staging phase.
cat > "$DOWNLOADER" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" -eq 2 ]] || exit 98
[[ "$2" == "$EXPECTED_STAGE_DIR" ]] || exit 98
case "$1" in
  --stage-only)
    printf 'stage\n' >> "$EVENT_LOG"
    mkdir -p "$2/bundle"
    printf 'staged-release\n' > "$2/bundle/VERSION"
    printf 'verified\n' > "$2/bundle/VERIFIED"
    exit "$STAGE_STATUS"
    ;;
  --install-staged)
    [[ -f "$2/bundle/VERIFIED" ]] || exit 98
    printf 'install-staged\n' >> "$EVENT_LOG"
    exit "$INSTALL_STATUS"
    ;;
  *) exit 98 ;;
esac
SH
chmod +x "$DOWNLOADER"

run_updater() {
  local expected_status="$1" status
  : > "$EVENT_LOG"
  if (
    cd -- "$CWD_DIR" || exit 95
    env -i \
      PATH="$TEST_DIR/bin" HOME="$TEST_DIR/fake home" \
      TEST_INSTALL_DIR="$INSTALL_DIR" \
      MODDEX_LOCK_FILE="$TEST_DIR/lock/install.lock" \
      OWNER="fixture owner" REPO="fixture repo" ASSET_SUFFIX="fixture suffix" \
      VERSION="v1.2.3" STAGE_STATUS="$STAGE_STATUS" INSTALL_STATUS="$INSTALL_STATUS" \
      EXPECTED_STAGE_DIR="$STAGE_DIR" TEST_RM_BIN="$RM_BIN" \
      STAGE_DIR="$STAGE_DIR" EVENT_LOG="$EVENT_LOG" \
      PRIVATE_TOKEN="fixture-secret-do-not-print" \
      "$UPDATER"
  ) > "$TEST_DIR/output" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq "$expected_status" ]] ||
    fail "Expected updater status $expected_status, received $status." "$TEST_DIR/output"
  if grep -Fq 'fixture-secret-do-not-print' "$TEST_DIR/output"; then
    fail "Output exposed an unrelated environment secret." "$TEST_DIR/output"
  fi
}

assert_event_log() {
  local expected="$1" label="$2"
  printf '%s' "$expected" > "$TEST_DIR/expected-events"
  cmp -s "$TEST_DIR/expected-events" "$EVENT_LOG" || fail "$label"
}

assert_install_untouched() {
  [[ "$(cat "$INSTALL_DIR/VERSION")" == "v0.0.1" ]] ||
    fail "Installed VERSION was modified." "$TEST_DIR/output"
  [[ "$(cat "$INSTALL_DIR/app.jar")" == "installed-backend" ]] ||
    fail "Installed app.jar was modified." "$TEST_DIR/output"
}

prepare_install() {
  printf 'v0.0.1\n' > "$INSTALL_DIR/VERSION"
  printf 'installed-backend\n' > "$INSTALL_DIR/app.jar"
}

# Success path (ordering proof): staging and verification are recorded before
# the stop mock fires, and installation runs only after the stop.
prepare_install
STAGE_STATUS=0 INSTALL_STATUS=0
run_updater 0
assert_event_log $'stage\nstop\ninstall-staged\n' \
  "Update did not stage and verify the bundle before stopping the service, or did not install after the stop."
grep -Fq '[INFO] Update staged and verified; stopping the Moddex service ...' "$TEST_DIR/output" ||
  fail "Updater did not report the verified staging before the stop." "$TEST_DIR/output"
grep -Fq '[INFO] Update complete.' "$TEST_DIR/output" ||
  fail "Updater did not report the completed update." "$TEST_DIR/output"
[[ ! -e "$STAGE_DIR" ]] || fail "Updater left the staging directory behind." "$TEST_DIR/output"
# The host lock (issue #108) covered the stop and the staged installation and
# records the update operation (PID, UTC start time) for concurrent runs; the
# file stays in place as the lock target after the lock was released.
update_lock_line=""
IFS= read -r update_lock_line < "$TEST_DIR/lock/install.lock" || update_lock_line=""
update_lock_re='^pid=[0-9]+ start=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z op=update$'
[[ "$update_lock_line" =~ $update_lock_re ]] ||
  fail "Update did not record its operation (PID, UTC start time) in the host lock (line: $update_lock_line)."

# Download failure before the stop: the stop mock must never have fired, the
# exit status propagates, the message names the safe state and the next
# action, and the installed version stays untouched.
prepare_install
STAGE_STATUS=37 INSTALL_STATUS=0
run_updater 37
if grep -Eqx 'stop|install-staged' "$EVENT_LOG"; then
  fail "Download failure stopped the service or installed anyway." "$TEST_DIR/output"
fi
grep -Fq 'before Moddex was stopped' "$TEST_DIR/output" ||
  fail "Download failure did not report that the service was not stopped." "$TEST_DIR/output"
grep -Fq 'the installed version keeps running' "$TEST_DIR/output" ||
  fail "Download failure did not report that the previous version keeps running." "$TEST_DIR/output"
grep -Fq 'rerun scripts/update.sh' "$TEST_DIR/output" ||
  fail "Download failure did not provide an actionable next step." "$TEST_DIR/output"
if grep -Fq 'Update complete.' "$TEST_DIR/output"; then
  fail "Download failure was reported as a successful update." "$TEST_DIR/output"
fi
assert_install_untouched
[[ ! -e "$STAGE_DIR" ]] || fail "Failed update left the staging directory behind." "$TEST_DIR/output"

# Checksum-style staging failure (exit 1) behaves like any staging failure.
prepare_install
STAGE_STATUS=1 INSTALL_STATUS=0
run_updater 1
if grep -Eqx 'stop|install-staged' "$EVENT_LOG"; then
  fail "Checksum failure stopped the service or installed anyway." "$TEST_DIR/output"
fi
assert_install_untouched

# Installation failure after the verified stop: the message names the stopped
# service and a safe next action, and the failure status propagates.
prepare_install
STAGE_STATUS=0 INSTALL_STATUS=42
run_updater 42
assert_event_log $'stage\nstop\ninstall-staged\n' \
  "Failed installation did not record the staged update order."
grep -Fq 'after Moddex was stopped' "$TEST_DIR/output" ||
  fail "Installation failure did not report that the service was stopped." "$TEST_DIR/output"
grep -Fq 'Rerun scripts/update.sh' "$TEST_DIR/output" ||
  fail "Installation failure did not provide an actionable next step." "$TEST_DIR/output"
grep -Fq 'sudo systemctl start moddex-backend.service' "$TEST_DIR/output" ||
  fail "Installation failure did not explain how to bring the service back." "$TEST_DIR/output"
if grep -Fq 'Update complete.' "$TEST_DIR/output"; then
  fail "Installation failure was reported as a successful update." "$TEST_DIR/output"
fi
assert_install_untouched

# Up-to-date installs never stage and never stop the service.
prepare_install
printf 'v9.8.7\n' > "$INSTALL_DIR/VERSION"
STAGE_STATUS=0 INSTALL_STATUS=0
run_updater 0
assert_event_log '' "Up-to-date check unexpectedly staged or stopped the service."
grep -Fq 'Already up-to-date.' "$TEST_DIR/output" ||
  fail "Up-to-date behavior changed." "$TEST_DIR/output"
[[ "$(cat "$INSTALL_DIR/VERSION")" == "v9.8.7" && "$(cat "$INSTALL_DIR/app.jar")" == "installed-backend" ]] ||
  fail "Up-to-date check modified the installation." "$TEST_DIR/output"

# ---------------------------------------------------------------------------
# Real staged download.sh modes: staging performs the full published-checksum
# verification and extraction without installing; --install-staged installs
# from that staging without any network access.
# ---------------------------------------------------------------------------
DL_TAG="v0.1.3-update"
DL_ASSET="moddex-$DL_TAG-linux-amd64.tar.gz"
DL_CASE="$TEST_DIR/download-case"
mkdir -p "$DL_CASE/release/scripts" "$DL_CASE/release/packaging/systemd" \
  "$DL_CASE/release/backend" "$DL_CASE/release/frontend" \
  "$DL_CASE/caller" "$DL_CASE/stage" "$DL_CASE/stage-tampered" \
  "$DL_CASE/empty-stage" "$DL_CASE/mismatch-stage/bundle"
printf 'backend:%s\n' "$DL_TAG" > "$DL_CASE/release/backend/Moddex-Backend.jar"
printf 'frontend:%s\n' "$DL_TAG" > "$DL_CASE/release/frontend/index.html"
printf 'unit:%s\n' "$DL_TAG" > "$DL_CASE/release/packaging/systemd/moddex-backend.service"
printf '%s\n' "$DL_TAG" > "$DL_CASE/release/VERSION"
cat > "$DL_CASE/release/scripts/install.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
: > "$DL_CASE/installer.entered"
printf '%s\n' "$@" > "$DL_CASE/installer.args"
SH
chmod 0644 "$DL_CASE/release/scripts/install.sh"
tar -C "$DL_CASE/release" -czf "$DL_CASE/$DL_ASSET" .
(cd "$DL_CASE" && sha256sum "$DL_ASSET" > "$DL_ASSET.sha256")
cat > "$DL_CASE/release.json" <<JSON
{
  "tag_name": "$DL_TAG",
  "assets": [
    {
      "name": "$DL_ASSET",
      "browser_download_url": "https://releases.invalid/$DL_TAG/$DL_ASSET"
    },
    {
      "name": "$DL_ASSET.sha256",
      "browser_download_url": "https://releases.invalid/$DL_TAG/$DL_ASSET.sha256"
    }
  ]
}
JSON

for cmd in jq tar sha256sum gzip; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing test dependency: $cmd"
done
DL_BIN="$TEST_DIR/dl-bin"
mkdir "$DL_BIN"
ln -s "$(command -v bash)" "$DL_BIN/bash"
# GNU tar spawns the gzip compressor via PATH, so the stub PATH must carry it
# (same as test-download-bundle-installer.sh) or -xzf cannot run. tar stays
# real so the pre-extraction validation listings (-tzf/-tvzf) and the
# --no-same-owner extraction run unstubbed; grep serves the namelist check.
for cmd in jq tar sha256sum gzip cat chmod mkdir env grep; do
  ln -s "$(command -v "$cmd")" "$DL_BIN/$cmd"
done
cat > "$DL_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -fsSL) shift ;;
    -o) output="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) printf 'Unexpected curl argument: %s\n' "$1" >&2; exit 90 ;;
  esac
done
printf '%s\n' "$url" >> "$DL_CASE/curl.log"
case "$url" in
  "https://api.github.com/repos/fixture-owner/fixture-repo/releases/tags/$DL_TAG")
    [[ -z "$output" ]]
    cat "$DL_CASE/release.json"
    ;;
  "https://releases.invalid/$DL_TAG/$DL_ASSET")
    [[ -n "$output" ]]
    cat "$DL_CASE/$DL_ASSET" > "$output"
    ;;
  "https://releases.invalid/$DL_TAG/$DL_ASSET.sha256")
    [[ -n "$output" ]]
    cat "$DL_CASE/$DL_ASSET.sha256" > "$output"
    ;;
  *)
    printf 'Unexpected URL; network access is disabled: %s\n' "$url" >&2
    exit 90
    ;;
esac
SH
chmod +x "$DL_BIN/curl"

run_downloader() {
  local expected_status="$1" status
  shift
  rm -f "$DL_CASE/installer.entered" "$DL_CASE/installer.args"
  if (
    cd -- "$DL_CASE/caller" || exit 95
    PATH="$DL_BIN" DL_CASE="$DL_CASE" DL_TAG="$DL_TAG" DL_ASSET="$DL_ASSET" \
      "$DL_BIN/bash" "$PROJECT_ROOT/scripts/download.sh" \
      --owner fixture-owner --repo fixture-repo "$@"
  ) > "$DL_CASE/output" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq "$expected_status" ]] ||
    fail "Expected download.sh status $expected_status, received $status." "$DL_CASE/output"
}

# Stage success: the release is verified and extracted into the staging
# directory, and nothing is installed.
run_downloader 0 --stage-only "$DL_CASE/stage" --version "$DL_TAG"
[[ "$(cat "$DL_CASE/stage/bundle/VERSION")" == "$DL_TAG" ]] ||
  fail "Staged bundle VERSION does not match the resolved release." "$DL_CASE/output"
[[ "$(cat "$DL_CASE/stage/bundle/backend/Moddex-Backend.jar")" == "backend:$DL_TAG" ]] ||
  fail "Staged bundle does not contain the verified backend artifact." "$DL_CASE/output"
[[ -x "$DL_CASE/stage/bundle/scripts/install.sh" ]] ||
  fail "Staged bundle installer is missing or not executable." "$DL_CASE/output"
grep -Fq 'Release bundle checksum verified' "$DL_CASE/output" ||
  fail "Staging did not report the verified release checksum." "$DL_CASE/output"
[[ ! -e "$DL_CASE/installer.entered" ]] ||
  fail "Staging ran the installer." "$DL_CASE/output"

# Install from staging: no network access, installer receives the staged
# bundle paths and the staged release tag.
: > "$DL_CASE/curl.log"
run_downloader 0 --install-staged "$DL_CASE/stage" --version "$DL_TAG"
[[ -f "$DL_CASE/installer.entered" ]] || fail "Staged installer did not run." "$DL_CASE/output"
[[ ! -s "$DL_CASE/curl.log" ]] ||
  fail "Installing a staged bundle accessed the network." "$DL_CASE/output"
printf '%s\n' \
  --backend-jar "$DL_CASE/stage/bundle/backend/Moddex-Backend.jar" \
  --frontend-dir "$DL_CASE/stage/bundle/frontend" \
  --version "$DL_TAG" > "$DL_CASE/expected-args"
cmp -s "$DL_CASE/expected-args" "$DL_CASE/installer.args" ||
  fail "Staged installer did not receive the expected bundle arguments." "$DL_CASE/output"

# Tampered bundle: checksum verification fails before anything is staged.
printf 'changed after publication\n' >> "$DL_CASE/$DL_ASSET"
run_downloader 1 --stage-only "$DL_CASE/stage-tampered" --version "$DL_TAG"
grep -Fq 'Release bundle checksum verification failed' "$DL_CASE/output" ||
  fail "Tampered bundle did not fail checksum verification." "$DL_CASE/output"
grep -Eiq 'download a complete matching release again' "$DL_CASE/output" ||
  fail "Checksum failure did not explain how to recover." "$DL_CASE/output"
[[ ! -e "$DL_CASE/stage-tampered/bundle" ]] ||
  fail "Failed verification staged the bundle anyway." "$DL_CASE/output"
[[ ! -e "$DL_CASE/installer.entered" ]] ||
  fail "Failed verification ran the installer." "$DL_CASE/output"

# Installing from an empty staging directory fails with a safe next action.
run_downloader 1 --install-staged "$DL_CASE/empty-stage" --version "$DL_TAG"
grep -Fq 'Staged bundle is missing VERSION' "$DL_CASE/output" ||
  fail "Empty staging did not fail with an actionable error." "$DL_CASE/output"
[[ ! -e "$DL_CASE/installer.entered" ]] ||
  fail "Empty staging ran the installer." "$DL_CASE/output"

# Installing a staged bundle whose VERSION contradicts the requested release
# fails before the installer runs.
printf 'v0.0.9-other\n' > "$DL_CASE/mismatch-stage/bundle/VERSION"
run_downloader 1 --install-staged "$DL_CASE/mismatch-stage" --version "$DL_TAG"
grep -Fq 'does not match the requested release' "$DL_CASE/output" ||
  fail "Staged VERSION mismatch did not fail with an actionable error." "$DL_CASE/output"
[[ ! -e "$DL_CASE/installer.entered" ]] ||
  fail "Staged VERSION mismatch ran the installer." "$DL_CASE/output"

# --stage-only requires an existing staging directory.
run_downloader 1 --stage-only "$DL_CASE/nonexistent-stage" --version "$DL_TAG"
grep -Fq "does not exist or is not a directory" "$DL_CASE/output" ||
  fail "Missing staging directory did not fail with an actionable error." "$DL_CASE/output"
[[ ! -e "$DL_CASE/installer.entered" ]] ||
  fail "Missing staging directory ran the installer." "$DL_CASE/output"

printf 'Update staging-before-stop checks passed (updater ordering, download and install failure paths, real staged download.sh modes; offline fixtures).\n'
