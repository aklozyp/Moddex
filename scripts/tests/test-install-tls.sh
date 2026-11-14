#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.install-tls-test.$$"
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
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.install-tls-test.* &&
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
  "chmod:0600 $TEST_CASE_DIR/host/etc/moddex/moddex.env") "$CHMOD_BIN" "$@" ;;
  "mv:-f -- $TEST_CASE_DIR/host/etc/moddex/moddex.env.tmp $TEST_CASE_DIR/host/etc/moddex/moddex.env")
    "$MV_BIN" -f -- "$TEST_CASE_DIR/host/etc/moddex/moddex.env.tmp" "$TEST_CASE_DIR/host/etc/moddex/moddex.env"
    ;;
  "rm:-f -- $TEST_CASE_DIR/host/etc/moddex/moddex.env")
    "$RM_BIN" -f -- "$TEST_CASE_DIR/host/etc/moddex/moddex.env"
    ;;
  "rm:-f -- $TEST_CASE_DIR/host/etc/moddex/moddex.env.tmp")
    "$RM_BIN" -f -- "$TEST_CASE_DIR/host/etc/moddex/moddex.env.tmp"
    ;;
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

chmod +x "$TEST_DIR/bin/install" "$TEST_DIR/bin/host-command"
for command in apt-get apt dpkg id useradd userdel chown chmod rsync sed systemctl \
  ufw firewall-cmd java curl wget rm cp mv; do
  ln -s host-command "$TEST_DIR/bin/$command"
done

ENV_FILE_REL="host/etc/moddex/moddex.env"
UNIT_REL="host/etc/systemd/system/moddex-backend.service"

prepare_case() {
  local name="$1"
  case_dir="$TEST_DIR/$name"
  mkdir -p "$case_dir/bundle/scripts" "$case_dir/bundle/backend/bin" \
    "$case_dir/bundle/frontend" "$case_dir/bundle/packaging/systemd" \
    "$case_dir/host/opt/moddex" "$case_dir/host/var/lib/moddex/ui" \
    "$case_dir/host/etc/moddex" "$case_dir/host/etc/systemd/system" \
    "$case_dir/host/run/systemd/system" "$case_dir/host/usr/local/bin" \
    "$case_dir/host/tls"
  printf 'fixture backend\n' > "$case_dir/bundle/backend/Moddex-Backend.jar"
  printf 'fixture frontend\n' > "$case_dir/bundle/frontend/index.html"
  printf 'v0.1.2-tls-fixture\n' > "$case_dir/bundle/VERSION"
  cp "$PROJECT_ROOT/backend/bin/moddex" "$case_dir/bundle/backend/bin/moddex"
  cp "$PROJECT_ROOT/packaging/systemd/moddex-backend.service" \
    "$case_dir/bundle/packaging/systemd/moddex-backend.service"
  printf 'previous backend\n' > "$case_dir/host/opt/moddex/app.jar"
  printf 'previous version\n' > "$case_dir/host/opt/moddex/VERSION"
  printf 'previous frontend\n' > "$case_dir/host/var/lib/moddex/ui/index.html"
  printf 'provider-key=unexpected-token-secret\n' > "$case_dir/host/etc/moddex/config.env"
  printf 'previous unit\n' > "$case_dir/host/etc/systemd/system/moddex-backend.service"
  printf 'previous cli\n' > "$case_dir/host/usr/local/bin/moddex"
  printf 'fixture certificate\n' > "$case_dir/host/tls/server.crt"
  printf 'fixture private key\n' > "$case_dir/host/tls/server.key"
  printf 'fixture keystore\n' > "$case_dir/host/tls/server.p12"
  cp -R "$case_dir/host" "$case_dir/before"
  : > "$case_dir/commands"

  # Keep the production flow intact. Only privilege gating, Bash 3's missing
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
}

run_install() {
  # Runs the staged installer with the closed PATH and records status/output.
  # TLS variables are exported by the caller after clear_tls_env, so each
  # case starts with a clean TLS environment.
  (
    unset PORT MODDEX_PORT MODE MODDEX_MODE BACKEND_JAR MODDEX_BACKEND_JAR \
      FRONTEND_DIR MODDEX_FRONTEND_DIR MODDEX_INSTALL_REEXEC MODDEX_LOCK_PID
    export PATH="$TEST_DIR/bin" TEST_CASE_DIR="$case_dir" TEST_NONROOT=0 \
      TEST_EXPECTED_PORT="$TEST_EXPECTED_PORT" \
      TEST_EXPECTED_ADDRESS="${TEST_EXPECTED_ADDRESS:-0.0.0.0}" \
      MODDEX_LOCK_FILE="$case_dir/host/run/moddex/install.lock" \
      BASH_BIN CP_BIN MKDIR_BIN CHMOD_BIN SED_BIN MV_BIN RM_BIN
    "$BASH_BIN" "$case_dir/bundle/scripts/install.sh" "$@" > "$case_dir/output" 2>&1
  )
}

clear_tls_env() {
  unset MODDEX_TLS_CERT_FILE MODDEX_TLS_KEY_FILE MODDEX_TLS_KEYSTORE \
    MODDEX_TLS_KEYSTORE_PASSWORD MODDEX_TLS_KEYSTORE_TYPE
}

assert_no_mutation() {
  diff -r "$case_dir/before" "$case_dir/host" ||
    fail "$1: the failing run changed installation, environment or service files."
}

case_count=0
begin_case() { case_count=$((case_count + 1)); }

# --- Case 1: fresh PEM install writes the env file and announces https -----
begin_case
prepare_case tls-pem-fresh
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
export MODDEX_TLS_CERT_FILE="$case_dir/host/tls/server.crt"
export MODDEX_TLS_KEY_FILE="$case_dir/host/tls/server.key"
run_install --mode lan || fail "tls-pem-fresh: installer exited with an error."
grep -Fxq 'MODDEX_TLS_ENABLED="true"' "$case_dir/$ENV_FILE_REL" ||
  fail "tls-pem-fresh: env file misses MODDEX_TLS_ENABLED."
grep -Fxq "MODDEX_TLS_CERT_FILE=\"$case_dir/host/tls/server.crt\"" "$case_dir/$ENV_FILE_REL" ||
  fail "tls-pem-fresh: env file misses the certificate file."
grep -Fxq "MODDEX_TLS_KEY_FILE=\"$case_dir/host/tls/server.key\"" "$case_dir/$ENV_FILE_REL" ||
  fail "tls-pem-fresh: env file misses the key file."
# BSD stat (macOS) has no -c; try the GNU form first, then the BSD form, so
# the mode assertion works on both platforms (the installer itself probes
# stat the same way for the ownership preflight).
[[ "$(stat -c %a "$case_dir/$ENV_FILE_REL" 2>/dev/null ||
  stat -f %Lp "$case_dir/$ENV_FILE_REL" 2>/dev/null)" == 600 ]] ||
  fail "tls-pem-fresh: env file is not mode 0600."
grep -Fq 'Backend API reachable at: https://<server-ip>:8080' "$case_dir/output" ||
  fail "tls-pem-fresh: final message does not announce https."
grep -Fq 'EnvironmentFile=-/etc/moddex/moddex.env' "$case_dir/$UNIT_REL" ||
  fail "tls-pem-fresh: unit does not reference the env file."

# --- Case 2: reinstall without TLS options preserves the configuration -----
begin_case
prepare_case tls-pem-reinstall-preserved
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
printf '# Managed by install.sh - native TLS settings for the Moddex backend.\nMODDEX_TLS_ENABLED="true"\nMODDEX_TLS_CERT_FILE="/existing/server.crt"\nMODDEX_TLS_KEY_FILE="/existing/server.key"\n' > "$case_dir/$ENV_FILE_REL"
run_install --mode lan || fail "tls-pem-reinstall-preserved: installer exited with an error."
grep -Fxq 'MODDEX_TLS_CERT_FILE="/existing/server.crt"' "$case_dir/$ENV_FILE_REL" ||
  fail "tls-pem-reinstall-preserved: preserved configuration was replaced."
grep -Fq 'Preserving the existing TLS configuration' "$case_dir/output" ||
  fail "tls-pem-reinstall-preserved: installer did not report preservation."
grep -Fq 'Backend API reachable at: https://<server-ip>:8080' "$case_dir/output" ||
  fail "tls-pem-reinstall-preserved: final message does not announce https."

# --- Case 3: --no-tls removes the configuration and announces http ---------
begin_case
prepare_case tls-no-tls-removes
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
printf '# Managed by install.sh - native TLS settings for the Moddex backend.\nMODDEX_TLS_ENABLED="true"\nMODDEX_TLS_CERT_FILE="/existing/server.crt"\nMODDEX_TLS_KEY_FILE="/existing/server.key"\n' > "$case_dir/$ENV_FILE_REL"
run_install --mode lan --no-tls || fail "tls-no-tls-removes: installer exited with an error."
[[ ! -e "$case_dir/$ENV_FILE_REL" ]] ||
  fail "tls-no-tls-removes: env file still exists."
grep -Fq 'Removed the existing TLS configuration' "$case_dir/output" ||
  fail "tls-no-tls-removes: installer did not report the removal."
grep -Fq 'Backend API reachable at: http://<server-ip>:8080' "$case_dir/output" ||
  fail "tls-no-tls-removes: final message does not announce http."

# --- Case 4: certificate without key fails safely without mutating ---------
begin_case
prepare_case tls-cert-only-fails
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
export MODDEX_TLS_CERT_FILE="$case_dir/host/tls/server.crt"
run_install --mode lan && fail "tls-cert-only-fails: installer succeeded without a key."
grep -Fq 'Native TLS needs both' "$case_dir/output" ||
  fail "tls-cert-only-fails: error message misses the safe next action."
[[ ! -e "$case_dir/$ENV_FILE_REL" ]] ||
  fail "tls-cert-only-fails: env file was written despite the failure."
assert_no_mutation "tls-cert-only-fails"

# --- Case 5: keystore install writes the keystore lines --------------------
begin_case
prepare_case tls-keystore-fresh
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
export MODDEX_TLS_KEYSTORE="$case_dir/host/tls/server.p12"
export MODDEX_TLS_KEYSTORE_PASSWORD='ks-secret-value'
export MODDEX_TLS_KEYSTORE_TYPE='PKCS12'
run_install --mode lan || fail "tls-keystore-fresh: installer exited with an error."
grep -Fxq "MODDEX_TLS_KEYSTORE=\"$case_dir/host/tls/server.p12\"" "$case_dir/$ENV_FILE_REL" ||
  fail "tls-keystore-fresh: env file misses the keystore."
grep -Fxq 'MODDEX_TLS_KEYSTORE_PASSWORD="ks-secret-value"' "$case_dir/$ENV_FILE_REL" ||
  fail "tls-keystore-fresh: env file misses the keystore password."
grep -Fxq 'MODDEX_TLS_KEYSTORE_TYPE="PKCS12"' "$case_dir/$ENV_FILE_REL" ||
  fail "tls-keystore-fresh: env file misses the keystore type."
# The password may appear nowhere in the installer output or command log.
if grep -Fq 'ks-secret-value' "$case_dir/output" "$case_dir/commands"; then
  fail "tls-keystore-fresh: installer exposed the keystore password."
fi
grep -Fq 'Backend API reachable at: https://<server-ip>:8080' "$case_dir/output" ||
  fail "tls-keystore-fresh: final message does not announce https."

# --- Case 6: PEM options combined with a keystore are rejected safely ------
begin_case
prepare_case tls-combo-fails
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
export MODDEX_TLS_CERT_FILE="$case_dir/host/tls/server.crt"
export MODDEX_TLS_KEY_FILE="$case_dir/host/tls/server.key"
export MODDEX_TLS_KEYSTORE="$case_dir/host/tls/server.p12"
run_install --mode lan && fail "tls-combo-fails: installer accepted both PEM and keystore."
grep -Fq 'not both' "$case_dir/output" ||
  fail "tls-combo-fails: error message misses the safe next action."
[[ ! -e "$case_dir/$ENV_FILE_REL" ]] ||
  fail "tls-combo-fails: env file was written despite the failure."
assert_no_mutation "tls-combo-fails"

# --- Case 7: reinstall without a port keeps the existing effective port ----
begin_case
prepare_case tls-port-preserved
TEST_EXPECTED_PORT=9123 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
printf 'previous unit\nEnvironment=SERVER_ADDRESS=0.0.0.0\nEnvironment=SERVER_PORT=9123\n' > "$case_dir/$UNIT_REL"
run_install --mode lan || fail "tls-port-preserved: installer exited with an error."
grep -Fxq 'Environment=SERVER_PORT=9123' "$case_dir/$UNIT_REL" ||
  fail "tls-port-preserved: the effective port was reset."
grep -Fq 'Preserving the existing backend port 9123' "$case_dir/output" ||
  fail "tls-port-preserved: installer did not report the preserved port."

# --- Case 8: fresh configuration directory is created by the installer -----
begin_case
prepare_case tls-fresh-config-dir
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
# A truly fresh installation has no /etc/moddex yet; the installer must
# create it before writing the environment file.
rm -rf "$case_dir/host/etc/moddex" ||
  fail "tls-fresh-config-dir: could not remove the fixture directory."
export MODDEX_TLS_CERT_FILE="$case_dir/host/tls/server.crt"
export MODDEX_TLS_KEY_FILE="$case_dir/host/tls/server.key"
run_install --mode lan || fail "tls-fresh-config-dir: installer exited with an error."
grep -Fxq 'MODDEX_TLS_ENABLED="true"' "$case_dir/$ENV_FILE_REL" ||
  fail "tls-fresh-config-dir: env file was not written on a fresh directory."

# --- Case 9: unreadable key fails safely ----------------------------------
begin_case
prepare_case tls-unreadable-key-fails
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
export MODDEX_TLS_CERT_FILE="$case_dir/host/tls/server.crt"
export MODDEX_TLS_KEY_FILE="$case_dir/host/tls/absent.key"
run_install --mode lan && fail "tls-unreadable-key-fails: installer succeeded with a missing key."
grep -Fq 'is not a file' "$case_dir/output" ||
  fail "tls-unreadable-key-fails: error message misses the safe next action."
[[ ! -e "$case_dir/$ENV_FILE_REL" ]] ||
  fail "tls-unreadable-key-fails: env file was written despite the failure."
assert_no_mutation "tls-unreadable-key-fails"

# --- Case 10: TLS reinstall over a preserved port announces https with it --
begin_case
prepare_case tls-preserved-tls-port-preserved
TEST_EXPECTED_PORT=9123 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
printf 'previous unit\nEnvironment=SERVER_ADDRESS=0.0.0.0\nEnvironment=SERVER_PORT=9123\n' > "$case_dir/$UNIT_REL"
printf '# Managed by install.sh - native TLS settings for the Moddex backend.\nMODDEX_TLS_ENABLED="true"\nMODDEX_TLS_CERT_FILE="/existing/server.crt"\nMODDEX_TLS_KEY_FILE="/existing/server.key"\n' > "$case_dir/$ENV_FILE_REL"
run_install --mode lan || fail "tls-preserved-tls-port-preserved: installer exited with an error."
grep -Fxq 'Environment=SERVER_PORT=9123' "$case_dir/$UNIT_REL" ||
  fail "tls-preserved-tls-port-preserved: the effective port was reset."
grep -Fq 'Preserving the existing backend port 9123' "$case_dir/output" ||
  fail "tls-preserved-tls-port-preserved: installer did not report the preserved port."
grep -Fxq 'MODDEX_TLS_ENABLED="true"' "$case_dir/$ENV_FILE_REL" ||
  fail "tls-preserved-tls-port-preserved: preserved TLS configuration was removed."
grep -Fq 'Backend API reachable at: https://<server-ip>:9123' "$case_dir/output" ||
  fail "tls-preserved-tls-port-preserved: final message does not announce https with the preserved port."

# --- Case 11: reinstall with new TLS options overwrites the configuration --
begin_case
prepare_case tls-reinstall-overwrites
TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0
clear_tls_env
printf '# Managed by install.sh - native TLS settings for the Moddex backend.\nMODDEX_TLS_ENABLED="true"\nMODDEX_TLS_CERT_FILE="/existing/old.crt"\nMODDEX_TLS_KEY_FILE="/existing/old.key"\n' > "$case_dir/$ENV_FILE_REL"
export MODDEX_TLS_CERT_FILE="$case_dir/host/tls/server.crt"
export MODDEX_TLS_KEY_FILE="$case_dir/host/tls/server.key"
run_install --mode lan || fail "tls-reinstall-overwrites: installer exited with an error."
grep -Fxq "MODDEX_TLS_CERT_FILE=\"$case_dir/host/tls/server.crt\"" "$case_dir/$ENV_FILE_REL" ||
  fail "tls-reinstall-overwrites: env file misses the new certificate file."
grep -Fxq "MODDEX_TLS_KEY_FILE=\"$case_dir/host/tls/server.key\"" "$case_dir/$ENV_FILE_REL" ||
  fail "tls-reinstall-overwrites: env file misses the new key file."
if grep -Fq '/existing/old' "$case_dir/$ENV_FILE_REL"; then
  fail "tls-reinstall-overwrites: previous TLS settings were not replaced."
fi
grep -Fq 'Backend API reachable at: https://<server-ip>:8080' "$case_dir/output" ||
  fail "tls-reinstall-overwrites: final message does not announce https."

printf 'Installer TLS checks passed (%s cases; env file contract, preservation, removal and safe failures verified).\n' "$case_count"
