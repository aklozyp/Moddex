#!/usr/bin/env bash
set -Eeuo pipefail

# Issue #108: parallel installation and update processes must not change the
# same artifacts, environment files, unit, and service at the same time.
# install.sh and update.sh hold a host-wide flock on MODDEX_LOCK_FILE for
# their mutating phases. This suite proves, against isolated fixture hosts
# with a closed PATH:
#   1. a completed installation records the holder PID, UTC start time, and
#      operation in the lock file, and the success path is unchanged;
#   2. a second run while a first one is mutating fails fast with the running
#      operation's ID and performs no second mutation (spy log);
#   3. a holder killed with SIGKILL leaves no permanent lock: the next run
#      acquires the lock and completes (the kernel releases it; the EXIT trap
#      of the killed process never runs);
#   4. the top-level update flow reenters the held lock through the recorded
#      operation PID (same operation), while a foreign operation PID, the PID
#      of a dead process, and every run without a token fail fast;
#   5. a relative MODDEX_LOCK_FILE and a non-regular file at the lock path
#      abort before any change with a safe next action.
# The lock file lives inside the fixture (MODDEX_LOCK_FILE); the production
# paths of the machine running the tests are never touched. flock is linked
# from the host when available (Linux/util-linux); otherwise a small perl
# stub provides the same kernel-lock semantics on the inherited descriptor
# (macOS), including automatic release on SIGKILL.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.install-host-lock-test.$$"
BASH_BIN="$(command -v bash)"
CP_BIN="$(command -v cp)"
MKDIR_BIN="$(command -v mkdir)"
CHMOD_BIN="$(command -v chmod)"
SED_BIN="$(command -v sed)"
MV_BIN="$(command -v mv)"
RM_BIN="$(command -v rm)"
SLEEP_BIN="$(command -v sleep)"
TAIL_BIN="$(command -v tail)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ ! -e "$TEST_DIR" ]] || fail "Test directory already exists: $TEST_DIR"
mkdir "$TEST_DIR"
cleanup() {
  local pid
  for pid in ${BACKGROUND_HOLDERS[@]+"${BACKGROUND_HOLDERS[@]}"}; do
    [[ -n "$pid" ]] || continue
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.install-host-lock-test.* &&
    -d "$TEST_DIR" && ! -L "$TEST_DIR" ]]; then
    "$RM_BIN" -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT

mkdir "$TEST_DIR/bin"

# A closed PATH and guarded mutation spies prevent access to host commands
# and paths beyond the fixture.
for command in bash cat dirname sleep date; do
  ln -s "$(command -v "$command")" "$TEST_DIR/bin/$command"
done

# Links the real util-linux flock when the host provides one (CI, Linux);
# otherwise installs a perl stub with identical kernel-lock semantics for
# hosts without the binary (macOS).
provide_flock() {
  local dest="$1"
  if command -v flock >/dev/null 2>&1; then
    ln -s "$(command -v flock)" "$dest/flock"
    return 0
  fi
  cat > "$dest/flock" <<'PERL'
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
  chmod +x "$dest/flock"
}
provide_flock "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/install" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'install %s\n' "$*" >> "$TEST_CASE_DIR/commands"
directory=no
mode=""
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -d) directory=yes; shift ;;
    -m) mode="$2"; shift 2 ;;
    -o|-g) [[ "$2" == moddex ]] || exit 91; shift 2 ;;
    *) exit 91 ;;
  esac
done
if [[ "$directory" == yes ]]; then
  [[ "$#" -eq 1 && "$1" == "$TEST_CASE_DIR/host/"* ]] || exit 91
  "$MKDIR_BIN" -p "$1"
  target="$1"
else
  [[ "$#" -eq 2 && "$1" == "$TEST_CASE_DIR/bundle/"* &&
    "$2" == "$TEST_CASE_DIR/host/"* ]] || exit 91
  "$CP_BIN" "$1" "$2"
  target="$2"
fi
"$CHMOD_BIN" "$mode" "$target"
SH

cat > "$TEST_DIR/bin/host-command" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
command="${0##*/}"
printf '%s %s\n' "$command" "$*" >> "$TEST_CASE_DIR/commands"
case "$command:$*" in
  'apt-get:update -y'|'apt-get:install -y --no-install-recommends openjdk-17-jre-headless rsync') ;;
  'id:-u moddex') exit 1 ;;
  "useradd:-r -M -s /usr/sbin/nologin -d $TEST_CASE_DIR/host/opt/moddex moddex") ;;
  "chown:moddex:moddex $TEST_CASE_DIR/host/opt/moddex/app.jar") ;;
  "chmod:0644 $TEST_CASE_DIR/host/opt/moddex/VERSION") "$CHMOD_BIN" "$@" ;;
  "rsync:-a --delete --chown=moddex:moddex $TEST_CASE_DIR/bundle/frontend/ $TEST_CASE_DIR/host/var/lib/moddex/ui/")
    "$CP_BIN" "$TEST_CASE_DIR/bundle/frontend/index.html" "$TEST_CASE_DIR/host/var/lib/moddex/ui/index.html"
    ;;
  'systemctl:daemon-reload'|'systemctl:enable --now moddex-backend.service') ;;
  *)
    printf 'Unexpected host command blocked.\n' >&2
    exit 91
    ;;
esac
SH

# The installer edits the unit with "sed -i"; this stub performs exactly the
# two known substitutions portably (BSD and GNU) inside the fixture host.
cat > "$TEST_DIR/bin/sed" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'sed %s\n' "$*" >> "$TEST_CASE_DIR/commands"
[[ "$1" == "-i" && "$#" -eq 3 ]] || exit 91
[[ "$3" == "$TEST_CASE_DIR/host/etc/systemd/system/moddex-backend.service" ]] || exit 91
case "$2" in
  "s/^Environment=SERVER_ADDRESS=.*/Environment=SERVER_ADDRESS=$TEST_EXPECTED_ADDRESS/")
    key=SERVER_ADDRESS value="$TEST_EXPECTED_ADDRESS" ;;
  "s/^Environment=SERVER_PORT=.*/Environment=SERVER_PORT=$TEST_EXPECTED_PORT/")
    key=SERVER_PORT value="$TEST_EXPECTED_PORT" ;;
  *) exit 91 ;;
esac
"$SED_BIN" "$2" "$3" > "$3.host-lock-fixture"
"$MV_BIN" "$3.host-lock-fixture" "$3"
SH

chmod +x "$TEST_DIR/bin/install" "$TEST_DIR/bin/host-command" "$TEST_DIR/bin/sed"
# apt-get is not part of this link list: it has its own stub below (writing
# through a link would clobber the shared host-command stub).
for command in apt dpkg id useradd userdel chown chmod rsync systemctl \
  ufw firewall-cmd java curl wget rm cp mv; do
  ln -s host-command "$TEST_DIR/bin/$command"
done

# Dedicated apt-get stub: logs its call and never blocks. The blocking
# behavior (installed per case via APT_BLOCK) holds the first installer
# inside its mutating phase (after the lock, at the package step) until the
# sentinel file appears, so another run can race against a live holder
# deterministically.
cat > "$TEST_DIR/bin/apt-get" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'apt-get %s\n' "$*" >> "$TEST_CASE_DIR/commands"
if [[ "${1:-}" == update && "${APT_BLOCK:-0}" == 1 ]]; then
  i=0
  while [[ ! -f "$APT_RELEASE" && $i -lt 600 ]]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
case "${1:-}" in
  update) [[ "${APT_FAILURE:-}" == update ]] && exit 41 ;;
  install) [[ "${APT_FAILURE:-}" == install ]] && exit 42 ;;
  *) exit 99 ;;
esac
exit 0
SH
chmod +x "$TEST_DIR/bin/apt-get"

prepare_case() {
  local name="$1" case_dir
  case_dir="$TEST_DIR/$name"
  mkdir -p "$case_dir/bundle/scripts" "$case_dir/bundle/backend/bin" \
    "$case_dir/bundle/frontend" "$case_dir/bundle/packaging/systemd" \
    "$case_dir/host/opt/moddex" "$case_dir/host/var/lib/moddex/ui" \
    "$case_dir/host/etc/moddex" "$case_dir/host/etc/systemd/system" \
    "$case_dir/host/run/systemd/system" "$case_dir/host/usr/local/bin"
  printf 'fixture backend\n' > "$case_dir/bundle/backend/Moddex-Backend.jar"
  printf 'fixture frontend\n' > "$case_dir/bundle/frontend/index.html"
  printf 'v0.1.2-host-lock-fixture\n' > "$case_dir/bundle/VERSION"
  cp "$PROJECT_ROOT/backend/bin/moddex" "$case_dir/bundle/backend/bin/moddex"
  cp "$PROJECT_ROOT/packaging/systemd/moddex-backend.service" \
    "$case_dir/bundle/packaging/systemd/moddex-backend.service"
  printf 'previous backend\n' > "$case_dir/host/opt/moddex/app.jar"
  printf 'previous version\n' > "$case_dir/host/opt/moddex/VERSION"
  printf 'previous frontend\n' > "$case_dir/host/var/lib/moddex/ui/index.html"
  printf 'provider-key=unexpected-token-secret\n' > "$case_dir/host/etc/moddex/config.env"
  printf 'previous unit\n' > "$case_dir/host/etc/systemd/system/moddex-backend.service"
  printf 'previous cli\n' > "$case_dir/host/usr/local/bin/moddex"
  : > "$case_dir/commands"

  # Keep the production flow intact. Only privilege gating, Bash 3's missing
  # lowercase operator and task-owned fixture paths differ from the real
  # script; the runtime marker and the lock file are redirected into the
  # fixture host.
  TEST_CASE_DIR="$case_dir" awk '
    $0 == "if [[ \"${EUID:-$(id -u)}\" -ne 0 ]]; then" {
      print "if [[ \"${TEST_NONROOT:-0}\" == 1 ]]; then"
      root_replaced = 1
      next
    }
    $0 == "MODE=\"${MODE,,}\"" {
      print "MODE=\"${MODE}\""
      mode_replaced = 1
      next
    }
    {
      gsub("/opt/moddex", ENVIRON["TEST_CASE_DIR"] "/host/opt/moddex")
      gsub("/var/lib/moddex", ENVIRON["TEST_CASE_DIR"] "/host/var/lib/moddex")
      gsub("/etc/moddex", ENVIRON["TEST_CASE_DIR"] "/host/etc/moddex")
      gsub("/etc/systemd/system", ENVIRON["TEST_CASE_DIR"] "/host/etc/systemd/system")
      gsub("/run/systemd/system", ENVIRON["TEST_CASE_DIR"] "/host/run/systemd/system")
      gsub("/usr/local/bin", ENVIRON["TEST_CASE_DIR"] "/host/usr/local/bin")
      print
    }
    END { if (!root_replaced || !mode_replaced) exit 1 }
  ' "$PROJECT_ROOT/scripts/install.sh" > "$case_dir/bundle/scripts/install.sh"
}

lock_file_of() { printf '%s/host/run/moddex/install.lock' "$1"; }
lock_dir_of() { printf '%s/host/run/moddex' "$1"; }

run_installer() {
  # Runs the staged installer with the closed PATH and reports the status.
  # MODDEX_LOCK_FILE_OVERRIDE relocates the lock for the rejection cases.
  local case_dir="$1" status=0
  (
    unset PORT MODDEX_PORT MODE MODDEX_MODE BACKEND_JAR MODDEX_BACKEND_JAR \
      FRONTEND_DIR MODDEX_FRONTEND_DIR MODDEX_INSTALL_REEXEC MODDEX_LOCK_PID \
      APT_BLOCK APT_FAILURE
    export PATH="$TEST_DIR/bin" TEST_CASE_DIR="$case_dir" TEST_NONROOT=0 \
      TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=127.0.0.1 \
      MODDEX_LOCK_FILE="${MODDEX_LOCK_FILE_OVERRIDE:-$(lock_file_of "$case_dir")}" \
      BASH_BIN CP_BIN MKDIR_BIN CHMOD_BIN SED_BIN MV_BIN RM_BIN
    "$BASH_BIN" "$case_dir/bundle/scripts/install.sh" \
      --mode local --backend-jar "$case_dir/bundle/backend/Moddex-Backend.jar" \
      > "$case_dir/output" 2>&1
  ) || status=$?
  return "$status"
}

# Starts an installer that blocks inside its mutating phase (at the package
# step, after acquiring the lock) until the sentinel file appears, and prints
# the holder PID. The background job is tracked for cleanup.
start_blocked_installer() {
  local case_dir="$1" holder_pid lock_file
  lock_file="$(lock_file_of "$case_dir")"
  (
    unset PORT MODDEX_PORT MODE MODDEX_MODE BACKEND_JAR MODDEX_BACKEND_JAR \
      FRONTEND_DIR MODDEX_FRONTEND_DIR MODDEX_INSTALL_REEXEC MODDEX_LOCK_PID \
      APT_FAILURE
    export PATH="$TEST_DIR/bin" TEST_CASE_DIR="$case_dir" TEST_NONROOT=0 \
      TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=127.0.0.1 \
      MODDEX_LOCK_FILE="$lock_file" \
      APT_BLOCK=1 APT_RELEASE="$TEST_DIR/release-sentinel" \
      BASH_BIN CP_BIN MKDIR_BIN CHMOD_BIN SED_BIN MV_BIN RM_BIN
    exec "$BASH_BIN" "$case_dir/bundle/scripts/install.sh" \
      --mode local --backend-jar "$case_dir/bundle/backend/Moddex-Backend.jar" \
      > "$case_dir/output" 2>&1
  ) &
  holder_pid=$!
  BACKGROUND_HOLDERS+=("$holder_pid")
  printf '%s\n' "$holder_pid"
}

# Waits until the blocked holder has acquired the lock and logged its first
# mutating command, so the racing run starts strictly after the holder took
# the lock and entered its mutation window.
await_holder_in_mutation() {
  local case_dir="$1" tries=0
  while (( tries < 400 )); do
    if grep -Fxq 'apt-get update -y' "$case_dir/commands" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    tries=$((tries + 1))
  done
  return 1
}

# Unblocks the stubbed package step, kills the holder and reaps it.
stop_holder() {
  local holder_pid="$1"
  : > "$TEST_DIR/release-sentinel"
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}

# Waits until the kernel lock is actually free. After a SIGKILLed holder, a
# still-live child that inherited the lock descriptor (here: the stubbed
# package call, in production: a real apt-get) keeps the lock until it ends,
# exactly like the production tool; the sentinel makes it exit promptly.
await_lock_free() {
  local lock_file="$1" tries=0
  while (( tries < 400 )); do
    if (
      exec 9>>"$lock_file"
      "$TEST_DIR/bin/flock" -n 9 || exit 1
      "$TEST_DIR/bin/flock" -u 9
    ) 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    tries=$((tries + 1))
  done
  return 1
}

lock_metadata_line() {
  local lock_file="$1" line=""
  IFS= read -r line < "$lock_file" 2>/dev/null || line=""
  printf '%s\n' "$line"
}

lock_pid_from_output() {
  local output="$1" pid=""
  pid="$(sed -n 's/.*operation PID \([0-9][0-9]*\)).*/\1/p' "$output" | "$TAIL_BIN" -n 1)"
  [[ -n "$pid" ]] || fail "Could not extract the operation PID from $output."
  printf '%s\n' "$pid"
}

# Runs the installer as a child of a subshell that holds the real kernel lock
# with update metadata, simulating the top-level update operation. The
# subshell exits with the installer's status; holder_pid is the PID the update
# wrote into the lock metadata, token_pid the PID it passes as
# MODDEX_LOCK_PID (the same operation in the real flow).
run_installer_inside_update_lock() {
  local case_dir="$1" holder_pid="$2" token_pid="$3"
  local lock_file
  lock_file="$(lock_file_of "$case_dir")"
  # The real updater finds the lock directory from the installer's earlier
  # run; the simulation creates it directly.
  "$MKDIR_BIN" -p "$(lock_dir_of "$case_dir")"
  (
    exec 9>>"$lock_file"
    "$TEST_DIR/bin/flock" -n 9 || exit 97
    : > "$lock_file"
    printf 'pid=%s start=%s op=update\n' "$holder_pid" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&9
    export PATH="$TEST_DIR/bin" TEST_CASE_DIR="$case_dir" TEST_NONROOT=0 \
      TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=127.0.0.1 \
      MODDEX_LOCK_FILE="$lock_file" MODDEX_LOCK_PID="$token_pid" \
      BASH_BIN CP_BIN MKDIR_BIN CHMOD_BIN SED_BIN MV_BIN RM_BIN
    "$BASH_BIN" "$case_dir/bundle/scripts/install.sh" \
      --mode local --backend-jar "$case_dir/bundle/backend/Moddex-Backend.jar" \
      > "$case_dir/output" 2>&1
  )
}

BACKGROUND_HOLDERS=()

# --- Case 1: a completed installation records PID, time, and operation ------
prepare_case metadata-and-success
case_dir="$TEST_DIR/metadata-and-success"
run_installer "$case_dir" || fail "metadata-and-success: installer failed on an unoccupied lock."
grep -Fxq '[moddex-install] Installation complete' "$case_dir/output" ||
  fail "metadata-and-success: installation did not complete."
cmp "$case_dir/bundle/backend/Moddex-Backend.jar" "$case_dir/host/opt/moddex/app.jar" ||
  fail "metadata-and-success: backend was not deployed."
cmp "$case_dir/bundle/VERSION" "$case_dir/host/opt/moddex/VERSION" ||
  fail "metadata-and-success: version was not persisted."
lock_line="$(lock_metadata_line "$(lock_file_of "$case_dir")")"
[[ "$lock_line" =~ ^pid=([0-9]+)\ start=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\ op=install$ ]] ||
  fail "metadata-and-success: lock file does not carry PID, UTC start time and operation (line: $lock_line)."
[[ "${BASH_REMATCH[1]}" == "$(lock_pid_from_output "$case_dir/output")" ]] ||
  fail "metadata-and-success: lock file PID does not match the reported operation PID."
printf 'PASS: metadata-and-success\n'

# --- Case 2: a second run fails fast with the running operation's ID --------
prepare_case second-run-rejected
case_dir="$TEST_DIR/second-run-rejected"
holder_pid="$(start_blocked_installer "$case_dir")"
await_holder_in_mutation "$case_dir" ||
  fail "second-run-rejected: the holder never reached its mutating phase."
status=0
run_installer "$case_dir" || status=$?
[[ "$status" -ne 0 ]] ||
  fail "second-run-rejected: the second run succeeded against a live holder."
grep -Fq "Another Moddex installation or update is currently running (operation PID $holder_pid, started " \
  "$case_dir/output" ||
  fail "second-run-rejected: the error does not name the running operation's PID."
grep -Fq "Wait for it to finish, then rerun this installer; nothing was changed by this run." \
  "$case_dir/output" ||
  fail "second-run-rejected: the error does not provide a safe next action."
if grep -Fq 'unexpected-token-secret' "$case_dir/output"; then
  fail "second-run-rejected: installer exposed unrelated environment file contents."
fi
# The spy log proves exactly what both runs did: the holder's preflight id
# probe, its lock directory, its blocked package call, then the second run's
# id probe and lock directory - and no second mutation anywhere.
printf 'id -u moddex\ninstall -d -m 0755 %s\napt-get update -y\nid -u moddex\ninstall -d -m 0755 %s\n' \
  "$(lock_dir_of "$case_dir")" "$(lock_dir_of "$case_dir")" > "$case_dir/expected.commands"
cmp "$case_dir/expected.commands" "$case_dir/commands" ||
  fail "second-run-rejected: the second run mutated beyond the lock attempt."
stop_holder "$holder_pid"
printf 'PASS: second-run-rejected\n'

# --- Case 3: a SIGKILLed holder leaves no permanent lock --------------------
prepare_case crashed-holder-releases
case_dir="$TEST_DIR/crashed-holder-releases"
holder_pid="$(start_blocked_installer "$case_dir")"
await_holder_in_mutation "$case_dir" ||
  fail "crashed-holder-releases: the holder never reached its mutating phase."
kill -9 "$holder_pid" 2>/dev/null ||
  fail "crashed-holder-releases: could not kill the holder."
wait "$holder_pid" 2>/dev/null || true
: > "$TEST_DIR/release-sentinel"
# The holder's EXIT trap never runs after SIGKILL; the kernel releases the
# lock as soon as the killed holder and the child that inherited its lock
# descriptor are gone (the stubbed package call exits on the sentinel).
await_lock_free "$(lock_file_of "$case_dir")" ||
  fail "crashed-holder-releases: the lock was still held after the holder died."
status=0
run_installer "$case_dir" || status=$?
[[ "$status" -eq 0 ]] ||
  { cat "$case_dir/output" >&2; fail "crashed-holder-releases: the next run did not recover after the crash."; }
grep -Fxq '[moddex-install] Installation complete' "$case_dir/output" ||
  fail "crashed-holder-releases: the recovering run did not complete."
replacement_pid="$(lock_pid_from_output "$case_dir/output")"
lock_line="$(lock_metadata_line "$(lock_file_of "$case_dir")")"
[[ "$lock_line" == "pid=$replacement_pid "* ]] ||
  fail "crashed-holder-releases: the lock metadata was not refreshed by the new holder (line: $lock_line)."
cmp "$case_dir/bundle/backend/Moddex-Backend.jar" "$case_dir/host/opt/moddex/app.jar" ||
  fail "crashed-holder-releases: the recovering run did not deploy the backend."
printf 'PASS: crashed-holder-releases\n'

# --- Case 4: the update flow reenters the lock via its operation PID --------
# The simulated update ($$ of this suite, alive) holds the real kernel lock
# with op=update metadata; the bundled installer it runs must reenter through
# the recorded PID instead of failing against its own update.
prepare_case update-reentry
case_dir="$TEST_DIR/update-reentry"
if run_installer_inside_update_lock "$case_dir" "$$" "$$"; then
  grep -Fq "The running update (operation PID $$) already holds the Moddex host lock; continuing the staged installation inside it." \
    "$case_dir/output" ||
    fail "update-reentry: the installer did not report the reentry into the update lock."
  grep -Fxq '[moddex-install] Installation complete' "$case_dir/output" ||
    fail "update-reentry: the reentering installer did not complete."
  lock_line="$(lock_metadata_line "$(lock_file_of "$case_dir")")"
  [[ "$lock_line" =~ ^pid=[0-9]+\ start=[0-9T:Z-]+\ op=update$ ]] ||
    fail "update-reentry: the update holder's metadata was overwritten (line: $lock_line)."
else
  cat "$TEST_DIR/update-reentry/output" >&2
  fail "update-reentry: the update flow's installer failed against its own update lock."
fi
printf 'PASS: update-reentry\n'

# --- Case 5: a foreign operation PID never reenters the lock ----------------
prepare_case foreign-token-rejected
case_dir="$TEST_DIR/foreign-token-rejected"
"$SLEEP_BIN" 30 &
foreign_pid=$!
BACKGROUND_HOLDERS+=("$foreign_pid")
# The recorded holder is the simulated update ($$), but the token names the
# unrelated live sleep process: the PIDs do not match, so the run must fail
# fast against the alive holder.
if run_installer_inside_update_lock "$case_dir" "$$" "$foreign_pid"; then
  fail "foreign-token-rejected: a foreign operation PID reentered the lock."
fi
grep -Fq "Another Moddex installation or update is currently running (operation PID $$, started " \
  "$case_dir/output" ||
  fail "foreign-token-rejected: the rejection did not name the recorded holder."
if grep -Fq 'Installation complete' "$case_dir/output"; then
  fail "foreign-token-rejected: the rejected run completed an installation."
fi
printf 'PASS: foreign-token-rejected\n'

# --- Case 6: the PID of a dead process never reenters the lock --------------
prepare_case dead-token-rejected
case_dir="$TEST_DIR/dead-token-rejected"
"$SLEEP_BIN" 0 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
# The recorded holder and the token are the same, already dead PID: even a
# matching token is denied when its process is gone (kill -0 gate).
if run_installer_inside_update_lock "$case_dir" "$dead_pid" "$dead_pid"; then
  fail "dead-token-rejected: the PID of a dead process reentered the lock."
fi
grep -Fq "recorded for PID $dead_pid" "$case_dir/output" &&
  grep -Fq "which is not running anymore" "$case_dir/output" ||
  fail "dead-token-rejected: the rejection did not explain the stale holder record."
printf 'PASS: dead-token-rejected\n'

# --- Case 7: a relative lock path aborts before any change ------------------
prepare_case relative-lock-path-rejected
case_dir="$TEST_DIR/relative-lock-path-rejected"
status=0
MODDEX_LOCK_FILE_OVERRIDE="relative/lock/path" run_installer "$case_dir" || status=$?
[[ "$status" -ne 0 ]] ||
  fail "relative-lock-path-rejected: a relative lock path was accepted."
grep -Fq "MODDEX_LOCK_FILE must be an absolute file path (received: relative/lock/path)" \
  "$case_dir/output" ||
  fail "relative-lock-path-rejected: the error does not explain the required absolute path."
grep -Fq "nothing was changed" "$case_dir/output" ||
  fail "relative-lock-path-rejected: the error does not state the safe outcome."
# Only the read-only preflight id probe may appear in the spy log.
if [[ -s "$case_dir/commands" ]] && grep -Evq '^id -u moddex$' "$case_dir/commands"; then
  fail "relative-lock-path-rejected: the rejected run reached a mutation spy."
fi
[[ ! -e "$(lock_dir_of "$case_dir")" ]] ||
  fail "relative-lock-path-rejected: a lock directory was created despite the rejection."
printf 'PASS: relative-lock-path-rejected\n'

# --- Case 8: a non-regular file at the lock path aborts ---------------------
prepare_case lock-path-directory-rejected
case_dir="$TEST_DIR/lock-path-directory-rejected"
status=0
MODDEX_LOCK_FILE_OVERRIDE="$case_dir/host/etc/moddex" run_installer "$case_dir" || status=$?
[[ "$status" -ne 0 ]] ||
  fail "lock-path-directory-rejected: a directory at the lock path was accepted."
grep -Fq "exists but is not a regular file" "$case_dir/output" ||
  fail "lock-path-directory-rejected: the error does not identify the invalid lock path."
grep -Fq "Remove or replace it, then rerun the installer" "$case_dir/output" ||
  fail "lock-path-directory-rejected: the error does not provide a safe next action."
# Only the read-only preflight id probe may appear in the spy log.
if [[ -s "$case_dir/commands" ]] && grep -Evq '^id -u moddex$' "$case_dir/commands"; then
  fail "lock-path-directory-rejected: the rejected run reached a mutation spy."
fi
printf 'PASS: lock-path-directory-rejected\n'

printf 'Installer host-lock checks passed (8 cases; parallel runs fail fast with the running operation ID, SIGKILL releases the lock, the update flow reenters via its operation PID, metadata and safe rejections verified).\n'
