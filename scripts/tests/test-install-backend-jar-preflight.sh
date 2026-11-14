#!/usr/bin/env bash
set -Eeuo pipefail

# Issue #109: an explicitly set --backend-jar path must be validated in the
# preflight, before the installer changes packages, accounts, directories,
# service files, or the service itself.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.install-jar-preflight-test.$$"
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
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.install-jar-preflight-test.* &&
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
' "$3" > "$3.preflight-fixture"
"$MV_BIN" "$3.preflight-fixture" "$3"
SH

chmod +x "$TEST_DIR/bin/install" "$TEST_DIR/bin/host-command" "$TEST_DIR/bin/sed"
for command in apt-get apt dpkg id useradd userdel chown chmod rsync systemctl \
  ufw firewall-cmd java curl wget rm cp mv; do
  ln -s host-command "$TEST_DIR/bin/$command"
done

case_count=0
prepare_case() {
  local name="$1" case_dir
  case_dir="$TEST_DIR/$name"
  mkdir -p "$case_dir/bundle/scripts" "$case_dir/bundle/backend/bin" \
    "$case_dir/bundle/jars" "$case_dir/bundle/packaging/systemd" \
    "$case_dir/host/opt/moddex" "$case_dir/host/var/lib/moddex/ui" \
    "$case_dir/host/etc/moddex" "$case_dir/host/etc/systemd/system" \
    "$case_dir/host/run/systemd/system" "$case_dir/host/usr/local/bin"
  printf 'fixture backend\n' > "$case_dir/bundle/backend/Moddex-Backend.jar"
  printf 'v0.1.2-jar-preflight-fixture\n' > "$case_dir/bundle/VERSION"
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

  # Keep the production preflight order intact. Only privilege gating, Bash 3's
  # missing lowercase operator and task-owned fixture paths differ from the
  # real script.
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
  # Runs the staged installer with the closed PATH and records the status.
  local case_dir="$1" jar_path="$2"
  (
    unset PORT MODDEX_PORT MODE MODDEX_MODE BACKEND_JAR MODDEX_BACKEND_JAR \
      FRONTEND_DIR MODDEX_FRONTEND_DIR MODDEX_INSTALL_REEXEC MODDEX_LOCK_PID
    export PATH="$TEST_DIR/bin" TEST_CASE_DIR="$case_dir" TEST_NONROOT=0 \
      TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=127.0.0.1 \
      MODDEX_LOCK_FILE="$case_dir/host/run/moddex/install.lock" \
      BASH_BIN CP_BIN MKDIR_BIN CHMOD_BIN MV_BIN RM_BIN AWK_BIN
    "$BASH_BIN" "$case_dir/bundle/scripts/install.sh" \
      --mode local --backend-jar "$jar_path" > "$case_dir/output" 2>&1
  )
}

assert_rejected_before_mutation() {
  # A failing preflight must abort with an actionable message before any
  # privileged host command runs and without changing any fixture file.
  local name="$1" jar_path="$2" expected_message="$3" case_dir status=0
  case_dir="$TEST_DIR/$name"
  run_installer "$case_dir" "$jar_path" || status=$?
  [[ "$status" -ne 0 ]] ||
    fail "$name: installer unexpectedly accepted the backend JAR."
  grep -Fq "$expected_message" "$case_dir/output" ||
    fail "$name: error message misses the safe next action."
  [[ ! -s "$case_dir/commands" ]] ||
    fail "$name: invalid backend JAR reached a mutation/privilege spy."
  diff -r "$case_dir/before" "$case_dir/host" ||
    fail "$name: invalid backend JAR changed installation, environment or service files."
  case_count=$((case_count + 1))
}

# --- Case 1: a missing JAR path is rejected before any host change ---------
prepare_case jar-missing-fails
assert_rejected_before_mutation jar-missing-fails \
  "$TEST_DIR/jar-missing-fails/bundle/jars/absent.jar" \
  "does not exist or is not a regular file"

# --- Case 2: an empty (0 bytes) JAR is rejected before any host change -----
prepare_case jar-empty-fails
: > "$TEST_DIR/jar-empty-fails/bundle/jars/empty.jar"
assert_rejected_before_mutation jar-empty-fails \
  "$TEST_DIR/jar-empty-fails/bundle/jars/empty.jar" \
  "is empty (0 bytes)"

# --- Case 3: a directory instead of a JAR is rejected (root robust) --------
prepare_case jar-directory-fails
mkdir "$TEST_DIR/jar-directory-fails/bundle/jars/directory.jar"
assert_rejected_before_mutation jar-directory-fails \
  "$TEST_DIR/jar-directory-fails/bundle/jars/directory.jar" \
  "does not exist or is not a regular file"

# --- Case 4: an unreadable JAR is rejected before any host change ----------
# A root test user bypasses file permission checks, so the pure readability
# branch cannot fire there; the directory case above covers the same
# preflight rejection root robustly instead.
prepare_case jar-unreadable-fails
printf 'fixture backend\n' > "$TEST_DIR/jar-unreadable-fails/bundle/jars/locked.jar"
chmod 000 "$TEST_DIR/jar-unreadable-fails/bundle/jars/locked.jar"
if [[ -r "$TEST_DIR/jar-unreadable-fails/bundle/jars/locked.jar" ]]; then
  printf 'Skipping the unreadable-JAR case: this test runs with privileges that bypass file permissions (root); the preflight readability branch is exercised in non-root runs.\n'
else
  assert_rejected_before_mutation jar-unreadable-fails \
    "$TEST_DIR/jar-unreadable-fails/bundle/jars/locked.jar" \
    "is not readable"
fi

# --- Case 5: a valid JAR passes the preflight and installs as before -------
prepare_case jar-valid-installs
case_dir="$TEST_DIR/jar-valid-installs"
status=0
run_installer "$case_dir" "$case_dir/bundle/backend/Moddex-Backend.jar" || status=$?
[[ "$status" -eq 0 ]] || { cat "$case_dir/output" >&2; fail "jar-valid-installs: installer rejected a valid backend JAR."; }
grep -Fxq '[moddex-install] Installation complete' "$case_dir/output" ||
  fail "jar-valid-installs: installation did not complete."
grep -Fq 'Backend API reachable at: http://127.0.0.1:8080' "$case_dir/output" ||
  fail "jar-valid-installs: final message does not announce the local HTTP endpoint."
grep -Fxq 'apt-get update -y' "$case_dir/commands" ||
  fail "jar-valid-installs: valid JAR never reached package update."
grep -Fxq 'apt-get install -y --no-install-recommends openjdk-17-jre-headless rsync' "$case_dir/commands" ||
  fail "jar-valid-installs: valid JAR never reached package install."
grep -Fxq 'systemctl enable --now moddex-backend.service' "$case_dir/commands" ||
  fail "jar-valid-installs: valid JAR never completed mocked installation."
if grep -Eq '^(ufw|firewall-cmd) ' "$case_dir/commands"; then
  fail "jar-valid-installs: local install changed firewall rules."
fi
cmp "$case_dir/bundle/backend/Moddex-Backend.jar" "$case_dir/host/opt/moddex/app.jar" ||
  fail "jar-valid-installs: backend was not deployed."
cmp "$case_dir/bundle/VERSION" "$case_dir/host/opt/moddex/VERSION" ||
  fail "jar-valid-installs: version was not persisted."
cmp "$case_dir/bundle/backend/bin/moddex" "$case_dir/host/usr/local/bin/moddex" ||
  fail "jar-valid-installs: CLI helper was not deployed."
grep -Fxq 'Environment=SERVER_ADDRESS=127.0.0.1' "$case_dir/host/etc/systemd/system/moddex-backend.service" ||
  fail "jar-valid-installs: unit does not carry the local server address."
grep -Fxq 'Environment=SERVER_PORT=8080' "$case_dir/host/etc/systemd/system/moddex-backend.service" ||
  fail "jar-valid-installs: unit does not carry the default port."
cmp "$case_dir/before/etc/moddex/config.env" "$case_dir/host/etc/moddex/config.env" ||
  fail "jar-valid-installs: unrelated environment configuration changed."
case_count=$((case_count + 1))

printf 'Installer backend JAR preflight checks passed (%s cases; missing, empty, unreadable and valid JARs verified before any host change).\n' "$case_count"
