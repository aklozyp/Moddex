#!/usr/bin/env bash
# Offline regression: bash scripts/tests/test-update-script-path.sh
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TEST_DIR="$PROJECT_ROOT/.update-script-path-test.$$"
ACTUAL_HOME="${HOME:-}"
RM_BIN="$(command -v rm)"
STAGE_DIR="$TEST_DIR/update stage"

if [[ -e "$TEST_DIR" || -L "$TEST_DIR" ]]; then
  printf 'Test directory already exists: %s\n' "$TEST_DIR" >&2
  exit 1
fi

mkdir "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/bundle with spaces/scripts" \
  "$TEST_DIR/arbitrary cwd" "$TEST_DIR/fake home" "$TEST_DIR/install state"
UPDATER="$TEST_DIR/bundle with spaces/scripts/update.sh"
DOWNLOADER="$TEST_DIR/bundle with spaces/scripts/download.sh"

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

for cmd in awk tail tr sed grep mkdir; do
  ln -s "$(command -v "$cmd")" "$TEST_DIR/bin/$cmd"
done

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

# Only the exact fixture updater shebang and sibling downloader may reach Bash.
cat > "$TEST_DIR/bin/bash" <<'SH'
#!/bin/sh
set -eu
if [ "$#" -ge 1 ] && [ "$1" = "$EXPECTED_DOWNLOADER" ]; then
  exec "$TEST_BASH" "$@"
fi
if [ "$#" -ge 1 ] && [ "$UPDATER_LAUNCH_MODE" = executable ] &&
  [ "$1" = "$EXPECTED_UPDATER" ]; then
  printf 'shebang\n' >> "$SHEBANG_LOG"
  exec "$TEST_BASH" "$@"
fi
printf 'blocked\n' >> "$CHILD_GUARD_LOG"
printf 'Rejected unexpected child Bash invocation.\n' >&2
exit 96
SH

cat > "$TEST_DIR/bin/dirname" <<'SH'
#!/bin/sh
if [ "${UNRESOLVABLE_DIR:-0}" = 1 ]; then
  printf '%s\n' "$TEST_INSTALL_DIR/nonexistent updater directory"
  exit 0
fi
[ "${1:-}" = -- ] && shift
case "$1" in
  */*) printf '%s\n' "${1%/*}" ;;
  *) printf '.\n' ;;
esac
SH

cat > "$TEST_DIR/bin/curl" <<'SH'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = -fsSLI ] || exit 98
printf 'HTTP/2 302\r\nLocation: https://example.invalid/releases/tag/v9.8.7\r\n'
SH

cat > "$TEST_DIR/bin/systemctl" <<'SH'
#!/bin/sh
[ "$*" = 'list-units --type=service --all' ] || exit 98
exit 0
SH

cat > "$TEST_DIR/bin/sudo" <<'SH'
#!/bin/sh
[ "$*" = 'systemctl stop moddex-backend' ] || exit 98
printf 'stop\n' >> "$EVENT_LOG"
SH

for cmd in sha256sum tar; do
  cat > "$TEST_DIR/bin/$cmd" <<'SH'
#!/bin/sh
printf 'Unexpected command execution.\n' >&2
exit 98
SH
done

# The updater stages into exactly one directory it creates with mktemp and
# removes only that directory again; every other use must fail.
cat > "$TEST_DIR/bin/mktemp" <<'SH'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = -d ] && [ "$2" = -t ] && [ "$3" = moddex-update.XXXXXX ] || exit 91
mkdir "$TEST_STAGE_DIR"
printf '%s\n' "$TEST_STAGE_DIR"
SH

cat > "$TEST_DIR/bin/rm" <<'SH'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = -rf ] && [ "$2" = -- ] && [ "$3" = "$TEST_STAGE_DIR" ] || exit 91
exec "$TEST_RM_BIN" "$@"
SH
chmod +x "$TEST_DIR/bin/"*

cat > "$DOWNLOADER" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$#" -eq 0 ]]; then
  printf 'download\n' >> "$EVENT_LOG"
  printf 'AUTO_RUN=%s\nVERSION=%s\nOWNER=%s\nREPO=%s\nASSET_SUFFIX=%s\nargc=0\ncwd=%s\nHOME=%s\n' \
    "${AUTO_RUN:-}" "${VERSION:-}" "$OWNER" "$REPO" "$ASSET_SUFFIX" "$PWD" "$HOME" \
    > "$DOWNLOAD_LOG"
  exit "$DOWNLOAD_STATUS"
fi
[[ "$#" -eq 2 && "$2" == "$EXPECTED_STAGE_DIR" ]] || exit 98
case "$1" in
  --stage-only)
    printf 'stage\n' >> "$EVENT_LOG"
    mkdir -p "$2/bundle"
    printf 'staged\n' > "$2/bundle/STAGED"
    status="$STAGE_STATUS"
    ;;
  --install-staged)
    [[ -f "$2/bundle/STAGED" ]] || exit 98
    printf 'install-staged\n' >> "$EVENT_LOG"
    status="$INSTALL_STATUS"
    ;;
  *) exit 98 ;;
esac
printf 'mode=%s\ntarget=%s\nAUTO_RUN=%s\nVERSION=%s\nOWNER=%s\nREPO=%s\nASSET_SUFFIX=%s\nargc=%s\ncwd=%s\nHOME=%s\n' \
  "$1" "$2" "${AUTO_RUN:-}" "${VERSION:-}" "$OWNER" "$REPO" "$ASSET_SUFFIX" "$#" "$PWD" "$HOME" \
  >> "$DOWNLOAD_LOG"
exit "$status"
SH

for cwd in "$TEST_DIR/arbitrary cwd" "$TEST_DIR/fake home"; do
  cat > "$cwd/download.sh" <<'SH'
#!/usr/bin/env bash
printf 'Caller downloader must never run.\n' > "$DECOY_LOG"
exit 97
SH
done

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  cat "$TEST_DIR/output" >&2
  exit 1
}

DOWNLOAD_STATUS=0
STAGE_STATUS=0
INSTALL_STATUS=0
UNRESOLVABLE_DIR=0
CALL_PATH="$UPDATER"
LAUNCH_MODE=interpreter
RUN_HOME="$TEST_DIR/fake home"

run_updater() {
  local cwd="$1" expected_status="$2" answer="${3:-}" status
  local -a updater_command
  case "$LAUNCH_MODE" in
    interpreter) updater_command=("$BASH" "$CALL_PATH") ;;
    executable)
      [[ "$CALL_PATH" == "$UPDATER" ]] || fail "Executable launch must target the exact fixture updater."
      updater_command=("$UPDATER")
      ;;
    *) fail "Unknown updater launch mode." ;;
  esac
  : > "$TEST_DIR/download.log"
  : > "$TEST_DIR/events.log"
  : > "$TEST_DIR/bash-guard.log"
  : > "$TEST_DIR/shebang.log"
  if (
    cd -- "$cwd" || exit 95
    printf '%s\n' "$answer" | env -i \
      PATH="$TEST_DIR/bin" HOME="$RUN_HOME" \
      TEST_INSTALL_DIR="$TEST_DIR/install state" \
      MODDEX_LOCK_FILE="$TEST_DIR/lock/install.lock" \
      OWNER="fixture owner" REPO="fixture repo" ASSET_SUFFIX="fixture suffix" \
      VERSION="v1.2.3" DOWNLOAD_STATUS="$DOWNLOAD_STATUS" \
      STAGE_STATUS="$STAGE_STATUS" INSTALL_STATUS="$INSTALL_STATUS" \
      TEST_STAGE_DIR="$STAGE_DIR" EXPECTED_STAGE_DIR="$STAGE_DIR" TEST_RM_BIN="$RM_BIN" \
      UNRESOLVABLE_DIR="$UNRESOLVABLE_DIR" \
      EXPECTED_DOWNLOADER="$DOWNLOADER" EXPECTED_UPDATER="$UPDATER" TEST_BASH="$BASH" \
      UPDATER_LAUNCH_MODE="$LAUNCH_MODE" SHEBANG_LOG="$TEST_DIR/shebang.log" \
      CHILD_GUARD_LOG="$TEST_DIR/bash-guard.log" \
      EVENT_LOG="$TEST_DIR/events.log" DOWNLOAD_LOG="$TEST_DIR/download.log" \
      DECOY_LOG="$TEST_DIR/decoy.log" PRIVATE_TOKEN="fixture-secret-do-not-print" \
      "${updater_command[@]}"
  ) > "$TEST_DIR/output" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq "$expected_status" ]] ||
    fail "Expected status $expected_status, received $status. ($LAUNCH_MODE launch)"
  [[ ! -e "$STAGE_DIR" ]] ||
    fail "Updater left the staging directory behind. ($LAUNCH_MODE launch)"
  if [[ "$LAUNCH_MODE" == executable ]]; then
    printf 'shebang\n' > "$TEST_DIR/expected"
    cmp -s "$TEST_DIR/expected" "$TEST_DIR/shebang.log" ||
      fail "Executable updater did not pass through its guarded Bash shebang exactly once."
  else
    [[ ! -s "$TEST_DIR/shebang.log" ]] || fail "Interpreter launch unexpectedly used the updater shebang."
  fi
  [[ ! -s "$TEST_DIR/bash-guard.log" ]] || fail "Updater attempted an unapproved child Bash invocation."
  [[ ! -e "$TEST_DIR/decoy.log" ]] || fail "Executed the caller's decoy download.sh."
  if grep -Fq 'fixture-secret-do-not-print' "$TEST_DIR/output"; then
    fail "Output exposed an unrelated environment secret."
  fi
}

assert_download() {
  local version="$1" cwd="$2"
  printf 'AUTO_RUN=1\nVERSION=%s\nOWNER=fixture owner\nREPO=fixture repo\nASSET_SUFFIX=fixture suffix\nargc=0\ncwd=%s\nHOME=%s\n' \
    "$version" "$cwd" "$RUN_HOME" > "$TEST_DIR/expected"
  cmp -s "$TEST_DIR/expected" "$TEST_DIR/download.log" ||
    fail "Downloader invocation did not preserve the expected environment and working directory."
}

phase_block() {
  local mode="$1" version="$2" cwd="$3"
  printf 'mode=%s\ntarget=%s\nAUTO_RUN=1\nVERSION=%s\nOWNER=fixture owner\nREPO=fixture repo\nASSET_SUFFIX=fixture suffix\nargc=2\ncwd=%s\nHOME=%s\n' \
    "$mode" "$STAGE_DIR" "$version" "$cwd" "$RUN_HOME"
}

assert_update_phases() {
  local version="$1" cwd="$2"
  { phase_block --stage-only "$version" "$cwd"; phase_block --install-staged "$version" "$cwd"; } \
    > "$TEST_DIR/expected"
  cmp -s "$TEST_DIR/expected" "$TEST_DIR/download.log" ||
    fail "Staged update did not run exactly one --stage-only and one --install-staged invocation with the expected environment and working directory."
}

assert_stage_only() {
  local version="$1" cwd="$2"
  phase_block --stage-only "$version" "$cwd" > "$TEST_DIR/expected"
  cmp -s "$TEST_DIR/expected" "$TEST_DIR/download.log" ||
    fail "Failed staging did not record exactly one --stage-only invocation with the expected environment and working directory."
}

assert_event_order() {
  local expected="$1" label="$2"
  printf '%s' "$expected" > "$TEST_DIR/expected"
  cmp -s "$TEST_DIR/expected" "$TEST_DIR/events.log" || fail "$label"
}

assert_no_download() {
  [[ ! -s "$TEST_DIR/download.log" && ! -s "$TEST_DIR/events.log" ]] ||
    fail "Downloader or service stop ran unexpectedly."
}

for rejected_script in ./download.sh ./update.sh "$TEST_DIR/arbitrary cwd/download.sh" -c; do
  if env -i EXPECTED_DOWNLOADER="$DOWNLOADER" EXPECTED_UPDATER="$UPDATER" TEST_BASH="$BASH" \
    UPDATER_LAUNCH_MODE=executable SHEBANG_LOG="$TEST_DIR/shebang.log" \
    CHILD_GUARD_LOG="$TEST_DIR/bash-guard.log" DECOY_LOG="$TEST_DIR/decoy.log" \
    "$TEST_DIR/bin/bash" "$rejected_script" > "$TEST_DIR/output" 2>&1; then
    fail "Child Bash guard accepted an unapproved invocation."
  else
    status=$?
  fi
  [[ "$status" -eq 96 && ! -e "$TEST_DIR/decoy.log" ]] ||
    fail "Child Bash guard did not safely reject an unapproved invocation."
done

check_real_cwd() {
  local cwd="$1" label="$2" physical_cwd
  [[ -n "$cwd" ]] || fail "Required $label is unset; real-cwd checks cannot run."
  physical_cwd="$(CDPATH="" cd -- "$cwd" 2>/dev/null && pwd -P)" ||
    fail "Required $label is inaccessible; real-cwd checks cannot run."

  printf 'v0.0.1\n' > "$TEST_DIR/install state/VERSION"
  : > "$TEST_DIR/install state/app.jar"
  STAGE_STATUS=0 INSTALL_STATUS=0
  run_updater "$cwd" 0
  assert_update_phases v9.8.7 "$physical_cwd"
  assert_event_order $'stage\nstop\ninstall-staged\n' \
    "Real-cwd update did not stage and verify the bundle before stopping the service, or did not install after the stop."
  grep -Fq '[INFO] Update complete.' "$TEST_DIR/output" ||
    fail "Real-cwd update success was not reported."

  STAGE_STATUS=37
  run_updater "$cwd" 37
  assert_stage_only v9.8.7 "$physical_cwd"
  if grep -Eqx 'stop|install-staged' "$TEST_DIR/events.log"; then
    fail "Real-cwd download failure stopped the service or installed anyway."
  fi
  if grep -Fq 'Update complete.' "$TEST_DIR/output"; then
    fail "Real-cwd download failure was reported as a successful update."
  fi
  grep -Fq 'the installed version keeps running' "$TEST_DIR/output" ||
    fail "Real-cwd download failure did not report that the previous version keeps running."
  grep -Fq 'rerun scripts/update.sh' "$TEST_DIR/output" ||
    fail "Real-cwd download failure did not provide an actionable next step."

  rm "$TEST_DIR/install state/app.jar"
  STAGE_STATUS=0
  run_updater "$cwd" 0 Y
  assert_download v1.2.3 "$physical_cwd"
  assert_event_order $'download\n' \
    "Real-cwd first installation unexpectedly stopped a service."

  DOWNLOAD_STATUS=42
  run_updater "$cwd" 42 yes
  assert_download v1.2.3 "$physical_cwd"
  DOWNLOAD_STATUS=0
  printf 'Real-cwd %s update/install success and failure checks passed: %s (no files written there).\n' \
    "$LAUNCH_MODE" "$label"
}

# Real cwd cases use only absolute fixture paths; neither directory is modified.
# Inaccessible required directories fail explicitly instead of skipping acceptance.
RUN_HOME="$ACTUAL_HOME"
for LAUNCH_MODE in interpreter executable; do
  check_real_cwd /tmp /tmp
  check_real_cwd "$ACTUAL_HOME" 'actual HOME'
done
RUN_HOME="$TEST_DIR/fake home"
LAUNCH_MODE=executable

printf 'v0.0.1\n' > "$TEST_DIR/install state/VERSION"
: > "$TEST_DIR/install state/app.jar"
STAGE_STATUS=0 INSTALL_STATUS=0
run_updater "$TEST_DIR/arbitrary cwd" 0
assert_update_phases v9.8.7 "$TEST_DIR/arbitrary cwd"
assert_event_order $'stage\nstop\ninstall-staged\n' \
  "Update did not stage and verify the bundle before stopping the service, or did not install after the stop."
grep -Fq '[INFO] Update complete.' "$TEST_DIR/output" || fail "Update success was not reported."

STAGE_STATUS=37
run_updater "$TEST_DIR/fake home" 37
assert_stage_only v9.8.7 "$TEST_DIR/fake home"
if grep -Eqx 'stop|install-staged' "$TEST_DIR/events.log"; then
  fail "Failed staging stopped the service or installed anyway."
fi
if grep -Fq 'Update complete.' "$TEST_DIR/output"; then
  fail "Failed download was reported as a successful update."
fi
STAGE_STATUS=0

INSTALL_STATUS=42
run_updater "$TEST_DIR/arbitrary cwd" 42
assert_update_phases v9.8.7 "$TEST_DIR/arbitrary cwd"
assert_event_order $'stage\nstop\ninstall-staged\n' \
  "Failed installation did not record the staged update order."
grep -Fq 'after Moddex was stopped' "$TEST_DIR/output" ||
  fail "Failed installation did not report that the service was stopped."
grep -Fq 'Rerun scripts/update.sh' "$TEST_DIR/output" ||
  fail "Failed installation did not provide an actionable next step."
INSTALL_STATUS=0

CALL_PATH=update.sh
LAUNCH_MODE=interpreter
run_updater "$TEST_DIR/bundle with spaces/scripts" 0
assert_update_phases v9.8.7 "$TEST_DIR/bundle with spaces/scripts"
CALL_PATH="$UPDATER"
LAUNCH_MODE=executable

rm "$TEST_DIR/install state/app.jar"
run_updater "$TEST_DIR/fake home" 0 Y
assert_download v1.2.3 "$TEST_DIR/fake home"
printf 'download\n' > "$TEST_DIR/expected"
cmp -s "$TEST_DIR/expected" "$TEST_DIR/events.log" ||
  fail "First installation unexpectedly stopped a service."

DOWNLOAD_STATUS=42
run_updater "$TEST_DIR/arbitrary cwd" 42 yes
assert_download v1.2.3 "$TEST_DIR/arbitrary cwd"
DOWNLOAD_STATUS=0

mv "$DOWNLOADER" "$TEST_DIR/bundled-download.sh"
run_updater "$TEST_DIR/fake home" 0 n
assert_no_download
grep -Fq 'Aborted.' "$TEST_DIR/output" || fail "Declining installation changed behavior."

run_updater "$TEST_DIR/fake home" 1 y
assert_no_download
grep -Fq 'keep download.sh beside update.sh' "$TEST_DIR/output" ||
  fail "Missing downloader did not provide an actionable recovery step."

: > "$TEST_DIR/install state/app.jar"
run_updater "$TEST_DIR/arbitrary cwd" 1
assert_no_download
grep -Fq 'keep download.sh beside update.sh' "$TEST_DIR/output" ||
  fail "Missing update downloader did not provide an actionable recovery step."

mkdir "$DOWNLOADER"
run_updater "$TEST_DIR/fake home" 1
assert_no_download
rmdir "$DOWNLOADER"
ln -s "$TEST_DIR/nonexistent downloader" "$DOWNLOADER"
run_updater "$TEST_DIR/arbitrary cwd" 1
assert_no_download
rm "$DOWNLOADER"
mv "$TEST_DIR/bundled-download.sh" "$DOWNLOADER"

UNRESOLVABLE_DIR=1
run_updater "$TEST_DIR/fake home" 1
assert_no_download
grep -Fq 'Extract the complete Moddex bundle again and run its scripts/update.sh' "$TEST_DIR/output" ||
  fail "Unresolvable updater directory did not provide an actionable recovery step."
UNRESOLVABLE_DIR=0

printf 'v9.8.7\n' > "$TEST_DIR/install state/VERSION"
run_updater "$TEST_DIR/arbitrary cwd" 0
assert_no_download
grep -Fq 'Already up-to-date.' "$TEST_DIR/output" || fail "Up-to-date behavior changed."

printf 'Updater path checks passed (interpreter and executable launches, offline fixtures, real /tmp and HOME, arbitrary cwd, fake HOME, spaces, guarded decoys, and failures).\n'
