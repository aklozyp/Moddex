#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.install-port-test.$$"
BASH_BIN="$(command -v bash)"
CP_BIN="$(command -v cp)"
MKDIR_BIN="$(command -v mkdir)"
CHMOD_BIN="$(command -v chmod)"
SED_BIN="$(command -v sed)"
MV_BIN="$(command -v mv)"
RM_BIN="$(command -v rm)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ ! -e "$TEST_DIR" ]] || fail "Test directory already exists: $TEST_DIR"
mkdir "$TEST_DIR"
cleanup() {
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.install-port-test.* &&
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
    -o|-g) [[ "$2" == moddex ]]; shift 2 ;;
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
  "rsync:-a --delete --chown=moddex:moddex $TEST_CASE_DIR/bundle/frontend/ $TEST_CASE_DIR/host/var/lib/moddex/ui/")
    "$CP_BIN" "$TEST_CASE_DIR/bundle/frontend/index.html" "$TEST_CASE_DIR/host/var/lib/moddex/ui/index.html"
    ;;
  "chmod:0644 $TEST_CASE_DIR/host/opt/moddex/VERSION") "$CHMOD_BIN" "$@" ;;
  "sed:-i s/^Environment=SERVER_ADDRESS=.*/Environment=SERVER_ADDRESS=$TEST_EXPECTED_ADDRESS/ $TEST_CASE_DIR/host/etc/systemd/system/moddex-backend.service"|\
  "sed:-i s/^Environment=SERVER_PORT=.*/Environment=SERVER_PORT=$TEST_EXPECTED_PORT/ $TEST_CASE_DIR/host/etc/systemd/system/moddex-backend.service")
    "$SED_BIN" "$2" "$3" > "$3.port-fixture"
    "$MV_BIN" "$3.port-fixture" "$3"
    ;;
  'systemctl:daemon-reload'|'systemctl:enable --now moddex-backend.service') ;;
  "ufw:allow $TEST_EXPECTED_PORT/tcp") ;;
  *)
    printf 'Unexpected host command blocked.\n' >&2
    exit 91
    ;;
esac
SH

cat > "$TEST_DIR/bin/sudo" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'sudo %s\n' "$*" >> "$TEST_CASE_DIR/commands"
[[ "$#" -ge 2 && "$1" == -E && "$2" == "$TEST_CASE_DIR/bundle/scripts/install.sh" ]] || exit 91
[[ "${MODDEX_INSTALL_REEXEC:-}" == 1 ]] || exit 91
shift
export TEST_NONROOT=0
exec "$BASH_BIN" "$@"
SH
chmod +x "$TEST_DIR/bin/install" "$TEST_DIR/bin/host-command" "$TEST_DIR/bin/sudo"
for command in apt-get apt dpkg id useradd userdel chown chmod rsync sed systemctl \
  ufw firewall-cmd java curl wget rm cp mv; do
  ln -s host-command "$TEST_DIR/bin/$command"
done

case_count=0
run_case() {
  local name="$1" expected_status="$2" expected_port="$3" source="$4" value="$5"
  local mode="${6:-lan}" nonroot="${7:-1}" status=0 case_dir
  case_dir="$TEST_DIR/$name"
  mkdir -p "$case_dir/bundle/scripts" "$case_dir/bundle/backend/bin" \
    "$case_dir/bundle/frontend" "$case_dir/bundle/packaging/systemd" \
    "$case_dir/host/opt/moddex" "$case_dir/host/var/lib/moddex/ui" \
    "$case_dir/host/etc/moddex" "$case_dir/host/etc/systemd/system" \
    "$case_dir/host/run/systemd/system" "$case_dir/host/usr/local/bin"
  printf 'fixture backend\n' > "$case_dir/bundle/backend/Moddex-Backend.jar"
  printf 'fixture frontend\n' > "$case_dir/bundle/frontend/index.html"
  printf 'v0.1.2-port-fixture\n' > "$case_dir/bundle/VERSION"
  cp "$PROJECT_ROOT/backend/bin/moddex" "$case_dir/bundle/backend/bin/moddex"
  cp "$PROJECT_ROOT/packaging/systemd/moddex-backend.service" \
    "$case_dir/bundle/packaging/systemd/moddex-backend.service"
  printf 'previous backend\n' > "$case_dir/host/opt/moddex/app.jar"
  printf 'previous version\n' > "$case_dir/host/opt/moddex/VERSION"
  printf 'previous frontend\n' > "$case_dir/host/var/lib/moddex/ui/index.html"
  printf 'provider-key=unexpected-token-secret\n' > "$case_dir/host/etc/moddex/config.env"
  printf 'previous unit\n' > "$case_dir/host/etc/systemd/system/moddex-backend.service"
  printf 'previous cli\n' > "$case_dir/host/usr/local/bin/moddex"
  cp -R "$case_dir/host" "$case_dir/before"
  : > "$case_dir/commands"

  # Keep the production port flow intact. Only privilege gating, Bash 3's missing
  # lowercase operator and task-owned fixture paths differ from the real script.
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

  (
    unset PORT MODDEX_PORT MODE MODDEX_MODE BACKEND_JAR MODDEX_BACKEND_JAR \
      FRONTEND_DIR MODDEX_FRONTEND_DIR MODDEX_INSTALL_REEXEC MODDEX_LOCK_PID
    export PATH="$TEST_DIR/bin" TEST_CASE_DIR="$case_dir" TEST_EXPECTED_PORT="$expected_port" \
      TEST_NONROOT="$nonroot" BASH_BIN CP_BIN MKDIR_BIN CHMOD_BIN SED_BIN MV_BIN \
      MODDEX_LOCK_FILE="$case_dir/host/run/moddex/install.lock"
    if [[ "$mode" == local ]]; then
      export TEST_EXPECTED_ADDRESS=127.0.0.1
    else
      export TEST_EXPECTED_ADDRESS=0.0.0.0
    fi
    args=(--mode "$mode")
    case "$source" in
      cli)
        export PORT=18081 MODDEX_PORT=18082
        args+=(--port "$value")
        ;;
      repeated-cli) args+=(--port 9090 --port "$value") ;;
      port-env) export PORT="$value" MODDEX_PORT=18082 ;;
      moddex-env) export MODDEX_PORT="$value" ;;
      default) ;;
      missing) args+=(--port) ;;
      missing-before-option) args+=(--port --mode local) ;;
      cli-over-invalid-env)
        export PORT=unexpected-token-secret MODDEX_PORT=65536
        args+=(--port "$value")
        ;;
      port-over-invalid-env) export PORT="$value" MODDEX_PORT=unexpected-token-secret ;;
      *) fail 'Unknown port fixture source.' ;;
    esac
    "$BASH_BIN" "$case_dir/bundle/scripts/install.sh" "${args[@]}"
  ) > "$case_dir/output" 2>&1 || status=$?

  [[ "$status" -eq "$expected_status" ]] || {
    cat "$case_dir/output" >&2
    fail "$name: expected exit $expected_status, received $status."
  }
  if grep -Fq 'unexpected-token-secret' "$case_dir/output"; then
    fail "$name: installer exposed sensitive input."
  fi

  if [[ "$expected_status" -ne 0 ]]; then
    [[ ! -s "$case_dir/commands" ]] || fail "$name: invalid port reached a mutation/privilege spy."
    diff -r "$case_dir/before" "$case_dir/host" ||
      fail "$name: invalid port changed installation, environment or service files."
    grep -Fq 'Use a decimal integer from 1 to 65535' "$case_dir/output" ||
      fail "$name: missing actionable port error."
  else
    grep -Fxq 'apt-get update -y' "$case_dir/commands" ||
      fail "$name: valid port never reached package update."
    grep -Fxq 'apt-get install -y --no-install-recommends openjdk-17-jre-headless rsync' "$case_dir/commands" ||
      fail "$name: valid port never reached package install."
    grep -Fxq 'systemctl enable --now moddex-backend.service' "$case_dir/commands" ||
      fail "$name: valid port never completed mocked installation."
    grep -Fxq "Environment=SERVER_PORT=$expected_port" "$case_dir/host/etc/systemd/system/moddex-backend.service" ||
      fail "$name: wrong persisted port."
    grep -Fxq '[moddex-install] Installation complete' "$case_dir/output" ||
      fail "$name: installation did not complete."
    cmp "$case_dir/bundle/backend/Moddex-Backend.jar" "$case_dir/host/opt/moddex/app.jar" ||
      fail "$name: backend was not deployed."
    cmp "$case_dir/bundle/frontend/index.html" "$case_dir/host/var/lib/moddex/ui/index.html" ||
      fail "$name: frontend was not deployed."
    cmp "$case_dir/bundle/backend/bin/moddex" "$case_dir/host/usr/local/bin/moddex" ||
      fail "$name: CLI helper was not deployed."
    cmp "$case_dir/bundle/VERSION" "$case_dir/host/opt/moddex/VERSION" ||
      fail "$name: version was not persisted."
    cmp "$case_dir/before/etc/moddex/config.env" "$case_dir/host/etc/moddex/config.env" ||
      fail "$name: unrelated environment configuration changed."
    if [[ "$mode" == local ]]; then
      ! grep -Eq '^(ufw|firewall-cmd) ' "$case_dir/commands" ||
        fail "$name: local install changed firewall rules."
    else
      grep -Fxq "ufw allow $expected_port/tcp" "$case_dir/commands" ||
        fail "$name: wrong firewall port."
    fi
    if [[ "$nonroot" == 1 ]]; then
      grep -q '^sudo -E ' "$case_dir/commands" || fail "$name: missing mocked privilege escalation."
    else
      ! grep -q '^sudo ' "$case_dir/commands" || fail "$name: root install invoked sudo."
    fi
  fi
  case_count=$((case_count + 1))
}

for source in cli port-env moddex-env; do
  run_case "$source-zero" 1 "" "$source" 0
  run_case "$source-too-large" 1 "" "$source" 65536
  run_case "$source-negative" 1 "" "$source" -1
  run_case "$source-nonnumeric" 1 "" "$source" unexpected-token-secret
  run_case "$source-empty" 1 "" "$source" ""
done
run_case missing 1 "" missing ""
run_case missing-before-option 1 "" missing-before-option ""
run_case decimal-point 1 "" cli 8080.0
run_case whitespace 1 "" cli ' 8080 '
run_case newline 1 "" cli $'8080\n'
run_case plus-sign 1 "" cli +8080
run_case hexadecimal 1 "" cli 0x1f90
run_case arithmetic 1 "" cli '$((8000+80))'
run_case shell-text 1 "" cli '8080;unexpected-token-secret'
run_case overflow-wrap 1 "" cli 18446744073709559696
run_case leading-zeros-out-of-range 1 "" cli 00065536
run_case repeated-cli-invalid 1 "" repeated-cli 0
printf -v long_zeros '%04096d' 0
run_case long-overflow 1 "" cli "${long_zeros//0/9}"
run_case long-zero 1 "" cli "$long_zeros"
run_case long-out-of-range 1 "" cli "${long_zeros}65536"

run_case default 0 8080 default "" lan 0
run_case cli-8080 0 8080 cli 8080 lan 0
run_case cli-minimum 0 1 cli 1 lan 0
run_case cli-maximum 0 65535 cli 65535 local 0
run_case port-env 0 18080 port-env 18080 lan 0
run_case moddex-env 0 18082 moddex-env 18082 lan 0
run_case cli-over-invalid-env 0 8080 cli-over-invalid-env 8080 lan 0
run_case port-over-invalid-env 0 8080 port-over-invalid-env 8080 lan 0
run_case repeated-cli-valid 0 8080 repeated-cli 8080 lan 0
run_case decimal-not-octal 0 8080 cli 08080 lan 0
run_case leading-zero-minimum 0 1 cli 00001 lan 0
run_case leading-zero-maximum 0 65535 cli 00065535 lan 0
run_case long-leading-zeros 0 8080 cli "${long_zeros}8080" lan 0
run_case reexec-8080 0 8080 cli 0008080 public 1
run_case reexec-environment 0 8080 port-env 0008080 lan 1

printf 'Installer port checks passed (%s cases; invalid inputs cannot mutate, valid installs persist decimal ports).\n' "$case_count"
