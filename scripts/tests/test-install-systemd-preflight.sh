#!/usr/bin/env bash
set -Eeuo pipefail

# Issue #111: systemd must be verified as the RUNNING service manager before
# the installer changes anything on the host. `command -v systemctl` alone
# also succeeds in containers and WSL without systemd, where the installation
# would only fail at the later `systemctl daemon-reload`, after packages, the
# service account, and directories have already been changed. These cases
# simulate the host environments over the fixture runtime marker, a
# controlled ps stub, and the closed PATH; no real service manager is used.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.install-systemd-preflight-test.$$"
BASH_BIN="$(command -v bash)"
CP_BIN="$(command -v cp)"
MKDIR_BIN="$(command -v mkdir)"
CHMOD_BIN="$(command -v chmod)"
MV_BIN="$(command -v mv)"
RM_BIN="$(command -v rm)"
AWK_BIN="$(command -v awk)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ ! -e "$TEST_DIR" ]] || fail "Test directory already exists: $TEST_DIR"
mkdir "$TEST_DIR"
cleanup() {
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.install-systemd-preflight-test.* &&
    -d "$TEST_DIR" && ! -L "$TEST_DIR" ]]; then
    "$RM_BIN" -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT
mkdir "$TEST_DIR/bin"

# A closed PATH and guarded mutation spies prevent access to host commands/paths.
for command in bash cat dirname; do
  ln -s "$(command -v "$command")" "$TEST_DIR/bin/$command"
done

# The host lock (issue #108) is acquired before the package steps: the closed
# fixture PATH needs flock (real where available, otherwise a perl stub with
# the same kernel-lock semantics) and the metadata timestamp.
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
"$AWK_BIN" -v key="$key" -v line="Environment=$key=$value" '
  index($0, "Environment=" key "=") == 1 { print line; next }
  { print }
' "$3" > "$3.systemd-preflight-fixture"
"$MV_BIN" "$3.systemd-preflight-fixture" "$3"
SH

# Read-only probe for the PID 1 corroboration: it is deliberately not logged
# to the mutation spy, so the pre-mutation assertions stay strict about
# mutating and privileged commands only.
cat > "$TEST_DIR/bin/ps" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == "-p" && "${2:-}" == "1" && "${3:-}" == "-o" &&
  "${4:-}" == "comm=" ]] || exit 91
if [[ "${TEST_PS_FAIL:-0}" == 1 ]]; then
  exit 1
fi
printf '%s\n' "$TEST_PS_COMM"
SH

chmod +x "$TEST_DIR/bin/install" "$TEST_DIR/bin/host-command" \
  "$TEST_DIR/bin/sed" "$TEST_DIR/bin/ps"
for command in apt-get apt dpkg id useradd userdel chown chmod rsync systemctl \
  ufw firewall-cmd java curl wget rm cp mv; do
  ln -s host-command "$TEST_DIR/bin/$command"
done

# Builds a closed PATH variant that hides the named commands, so the suite
# can simulate hosts without ps (minimal containers) or without systemctl.
make_bin_variant() {
  local dest="$1"; shift
  local name
  "$MKDIR_BIN" "$dest"
  for name in bash cat dirname date flock install host-command sed ps \
    apt-get apt dpkg id useradd userdel chown chmod rsync systemctl \
    ufw firewall-cmd java curl wget rm cp mv; do
    if [[ " $* " == *" $name "* ]]; then
      continue
    fi
    ln -s "$TEST_DIR/bin/$name" "$dest/$name"
  done
}

prepare_case() {
  local name="$1" marker="${2:-with-systemd}" case_dir
  case_dir="$TEST_DIR/$name"
  mkdir -p "$case_dir/bundle/scripts" "$case_dir/bundle/backend/bin" \
    "$case_dir/bundle/packaging/systemd" \
    "$case_dir/host/opt/moddex" "$case_dir/host/var/lib/moddex/ui" \
    "$case_dir/host/etc/moddex" "$case_dir/host/etc/systemd/system" \
    "$case_dir/host/run/systemd/system" "$case_dir/host/usr/local/bin"
  if [[ "$marker" == without-systemd ]]; then
    # Simulates a container or WSL without systemd: no runtime marker. rmdir
    # fails loudly on anything unexpected instead of deleting recursively.
    rmdir "$case_dir/host/run/systemd/system" "$case_dir/host/run/systemd" \
      "$case_dir/host/run" ||
      fail "$name: could not remove the systemd runtime marker fixture."
  fi
  printf 'fixture backend\n' > "$case_dir/bundle/backend/Moddex-Backend.jar"
  printf 'v0.1.2-systemd-preflight-fixture\n' > "$case_dir/bundle/VERSION"
  cp "$PROJECT_ROOT/backend/bin/moddex" "$case_dir/bundle/backend/bin/moddex"
  cp "$PROJECT_ROOT/packaging/systemd/moddex-backend.service" \
    "$case_dir/bundle/packaging/systemd/moddex-backend.service"
  printf 'previous backend\n' > "$case_dir/host/opt/moddex/app.jar"
  printf 'previous version\n' > "$case_dir/host/opt/moddex/VERSION"
  printf 'previous unit\n' > "$case_dir/host/etc/systemd/system/moddex-backend.service"
  printf 'previous cli\n' > "$case_dir/host/usr/local/bin/moddex"
  printf 'provider-key=unexpected-token-secret\n' > "$case_dir/host/etc/moddex/config.env"
  cp -R "$case_dir/host" "$case_dir/before"
  : > "$case_dir/commands"

  # Keep the production preflight order intact. Only privilege gating, Bash
  # 3's missing lowercase operator and task-owned fixture paths differ from
  # the real script; the runtime marker is redirected into the fixture host.
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

run_installer() {
  # Runs the staged installer with the requested closed PATH and records the
  # status. TEST_PS_COMM controls the simulated PID 1 name.
  local case_dir="$1" bin_dir="$2"
  (
    unset PORT MODDEX_PORT MODE MODDEX_MODE BACKEND_JAR MODDEX_BACKEND_JAR \
      FRONTEND_DIR MODDEX_FRONTEND_DIR MODDEX_INSTALL_REEXEC MODDEX_LOCK_PID
    export PATH="$bin_dir" TEST_CASE_DIR="$case_dir" TEST_NONROOT=0 \
      TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=127.0.0.1 \
      TEST_PS_COMM="${TEST_PS_COMM:-}" TEST_PS_FAIL="${TEST_PS_FAIL:-0}" \
      MODDEX_LOCK_FILE="$case_dir/host/run/moddex/install.lock" \
      BASH_BIN CP_BIN MKDIR_BIN CHMOD_BIN MV_BIN RM_BIN AWK_BIN
    "$BASH_BIN" "$case_dir/bundle/scripts/install.sh" \
      --mode local --backend-jar "$case_dir/bundle/backend/Moddex-Backend.jar" \
      > "$case_dir/output" 2>&1
  )
}

assert_output_has_no_secrets() {
  local name="$1" case_dir="$2"
  if grep -Fq 'unexpected-token-secret' "$case_dir/output"; then
    fail "$name: installer exposed unrelated environment file contents."
  fi
}

case_count=0

assert_systemd_install_completed() {
  # A supported systemd host must complete the installation and name the
  # native systemd operation in its log (issue #111 acceptance criterion 1).
  local name="$1" case_dir="$2" bin_dir="$3" status=0
  run_installer "$case_dir" "$bin_dir" || status=$?
  [[ "$status" -eq 0 ]] ||
    { cat "$case_dir/output" >&2; fail "$name: installer rejected a supported systemd environment."; }
  grep -Fxq '[moddex-install] Systemd is running as the service manager; installing the native systemd service.' \
    "$case_dir/output" ||
    fail "$name: successful run did not name the native systemd operation."
  grep -Fxq '[moddex-install] Installation complete' "$case_dir/output" ||
    fail "$name: installation did not complete."
  grep -Fxq 'apt-get update -y' "$case_dir/commands" ||
    fail "$name: supported environment never reached package update."
  grep -Fxq 'systemctl enable --now moddex-backend.service' "$case_dir/commands" ||
    fail "$name: supported environment never completed the mocked installation."
  cmp "$case_dir/bundle/backend/Moddex-Backend.jar" "$case_dir/host/opt/moddex/app.jar" ||
    fail "$name: backend was not deployed."
  cmp "$case_dir/bundle/VERSION" "$case_dir/host/opt/moddex/VERSION" ||
    fail "$name: version was not persisted."
  cmp "$case_dir/bundle/backend/bin/moddex" "$case_dir/host/usr/local/bin/moddex" ||
    fail "$name: CLI helper was not deployed."
  cmp "$case_dir/before/etc/moddex/config.env" "$case_dir/host/etc/moddex/config.env" ||
    fail "$name: unrelated environment configuration changed."
  assert_output_has_no_secrets "$name" "$case_dir"
  case_count=$((case_count + 1))
}

assert_rejected_before_mutation() {
  # An unsupported environment must abort with the reason and a safe next
  # action before any privileged host command runs and without changing any
  # fixture file (issue #111 acceptance criteria 1 and 3).
  local name="$1" expected_reason="$2" expected_action="$3" case_dir="$4" bin_dir="$5" status=0
  run_installer "$case_dir" "$bin_dir" || status=$?
  [[ "$status" -ne 0 ]] ||
    fail "$name: installer unexpectedly accepted the unsupported environment."
  grep -Fq "$expected_reason" "$case_dir/output" ||
    fail "$name: error message misses the unsupported-environment reason."
  grep -Fq "$expected_action" "$case_dir/output" ||
    fail "$name: error message misses the safe next action."
  [[ ! -s "$case_dir/commands" ]] ||
    fail "$name: unsupported environment reached a mutation/privilege spy."
  diff -r "$case_dir/before" "$case_dir/host" ||
    fail "$name: unsupported environment changed installation, environment or service files."
  assert_output_has_no_secrets "$name" "$case_dir"
  case_count=$((case_count + 1))
}

# --- Case 1: a systemd host (PID 1 systemd) installs and names the mode ----
make_bin_variant "$TEST_DIR/bin-no-ps" ps
make_bin_variant "$TEST_DIR/bin-no-systemctl" systemctl

prepare_case systemd-host-installs
TEST_PS_COMM=systemd
assert_systemd_install_completed systemd-host-installs \
  "$TEST_DIR/systemd-host-installs" "$TEST_DIR/bin"

# --- Case 2: the runtime marker stays decisive when ps is unavailable ------
prepare_case marker-without-ps-installs
assert_systemd_install_completed marker-without-ps-installs \
  "$TEST_DIR/marker-without-ps-installs" "$TEST_DIR/bin-no-ps"

# --- Case 3: a failing ps probe does not reject a systemd host -------------
prepare_case ps-failure-marker-decides
TEST_PS_FAIL=1
assert_systemd_install_completed ps-failure-marker-decides \
  "$TEST_DIR/ps-failure-marker-decides" "$TEST_DIR/bin"
TEST_PS_FAIL=0

# --- Case 4: a container without systemd is rejected before mutations ------
prepare_case container-without-systemd without-systemd
assert_rejected_before_mutation container-without-systemd \
  "systemd is not running as this system's service manager" \
  "run the bundled backend JAR directly" \
  "$TEST_DIR/container-without-systemd" "$TEST_DIR/bin-no-ps"

# --- Case 5: WSL without systemd is rejected before mutations --------------
prepare_case wsl-without-systemd without-systemd
TEST_PS_COMM=init
assert_rejected_before_mutation wsl-without-systemd \
  "systemd is not running as this system's service manager" \
  "run the bundled backend JAR directly" \
  "$TEST_DIR/wsl-without-systemd" "$TEST_DIR/bin"

# --- Case 6: a stale marker with foreign PID 1 is rejected -----------------
prepare_case stale-marker-foreign-pid1
TEST_PS_COMM=bash
assert_rejected_before_mutation stale-marker-foreign-pid1 \
  "PID 1 is 'bash', not systemd" \
  "systemd is the running service manager" \
  "$TEST_DIR/stale-marker-foreign-pid1" "$TEST_DIR/bin"

# --- Case 7: missing systemctl is rejected before mutations ----------------
prepare_case systemctl-missing-rejected
TEST_PS_COMM=systemd
assert_rejected_before_mutation systemctl-missing-rejected \
  "systemctl is not available" \
  "run this installer on a systemd-based host" \
  "$TEST_DIR/systemctl-missing-rejected" "$TEST_DIR/bin-no-systemctl"

printf 'Installer systemd preflight checks passed (%s cases; supported systemd hosts install, containers, WSL without systemd, stale markers and missing systemctl abort before any host change).\n' "$case_count"
