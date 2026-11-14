#!/usr/bin/env bash
set -Eeuo pipefail

# Issue #119: the installer must verify the targets of the systemwide
# installation paths before any write. A symlink on a written path pointing
# outside the Moddex layout, or an unexpected owner, must abort the
# installation before the first host change with the reason and a safe next
# action, while supported layouts (real mountpoints, in-layout symlinks,
# explicitly allowed relocations) stay usable.
#
# Every case runs against an isolated fixture host with a closed PATH, like
# test-install-systemd-preflight.sh. Symlinks and ownership are simulated
# strictly inside the fixture (the "tmp" and "srv" directories of the
# fixture host stand in for off-layout destinations); the real /opt/moddex,
# /var/lib/moddex, /etc/moddex paths of the machine running the tests are
# never touched. The installer under test is the staged awk copy used by the
# other suites: only privilege gating, Bash 3's missing lowercase operator
# and task-owned fixture paths differ from the real script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.install-symlink-preflight-test.$$"
BASH_BIN="$(command -v bash)"
CP_BIN="$(command -v cp)"
MKDIR_BIN="$(command -v mkdir)"
CHMOD_BIN="$(command -v chmod)"
SED_BIN="$(command -v sed)"
MV_BIN="$(command -v mv)"
RM_BIN="$(command -v rm)"
AWK_BIN="$(command -v awk)"
READLINK_BIN="$(command -v readlink)"
STAT_BIN="$(command -v stat)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -n "$READLINK_BIN" ]] || fail "readlink is required to build the symlink fixtures."
[[ -n "$STAT_BIN" ]] || fail "stat is required to build the ownership fixtures."

[[ ! -e "$TEST_DIR" ]] || fail "Test directory already exists: $TEST_DIR"
mkdir "$TEST_DIR"
cleanup() {
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.install-symlink-preflight-test.* &&
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
  "rsync:-a --delete --chown=moddex:moddex $TEST_CASE_DIR/bundle/frontend/ $TEST_CASE_DIR/host/var/lib/moddex/ui/")
    "$CP_BIN" "$TEST_CASE_DIR/bundle/frontend/index.html" "$TEST_CASE_DIR/host/var/lib/moddex/ui/index.html"
    ;;
  "sed:-i s/^Environment=SERVER_ADDRESS=.*/Environment=SERVER_ADDRESS=$TEST_EXPECTED_ADDRESS/ $TEST_CASE_DIR/host/etc/systemd/system/moddex-backend.service"|\
  "sed:-i s/^Environment=SERVER_PORT=.*/Environment=SERVER_PORT=$TEST_EXPECTED_PORT/ $TEST_CASE_DIR/host/etc/systemd/system/moddex-backend.service")
    "$SED_BIN" "$2" "$3" > "$3.symlink-fixture"
    "$MV_BIN" "$3.symlink-fixture" "$3"
    ;;
  'systemctl:daemon-reload'|'systemctl:enable --now moddex-backend.service') ;;
  "ufw:allow $TEST_EXPECTED_PORT/tcp") ;;
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
' "$3" > "$3.symlink-preflight-fixture"
"$MV_BIN" "$3.symlink-preflight-fixture" "$3"
SH

chmod +x "$TEST_DIR/bin/install" "$TEST_DIR/bin/host-command" "$TEST_DIR/bin/sed"

# Builds a closed-PATH bin variant.
#   stat_mode:     none (stat unavailable) | real | stub (env-controlled)
#   readlink_mode: yes | no
#   id_mode:       default (id -u moddex fails, like the other suites)
#                  | moddex777 (the moddex service account resolves to 777)
make_bin() {
  local dest="$1" stat_mode="$2" readlink_mode="$3" id_mode="$4" name
  "$MKDIR_BIN" "$dest"
  for name in bash cat dirname; do
    ln -s "$(command -v "$name")" "$dest/$name"
  done
  ln -s "$TEST_DIR/bin/install" "$dest/install"
  ln -s "$TEST_DIR/bin/sed" "$dest/sed"
  ln -s "$TEST_DIR/bin/flock" "$dest/flock"
  ln -s "$TEST_DIR/bin/date" "$dest/date"
  for name in host-command apt-get apt dpkg useradd userdel chown chmod rsync \
    systemctl ufw firewall-cmd java curl wget rm cp mv; do
    ln -s "$TEST_DIR/bin/host-command" "$dest/$name"
  done
  if [[ "$id_mode" == moddex777 ]]; then
    cat > "$dest/id" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -u && "$2" == moddex ]] || exit 91
printf '777\n'
SH
    chmod +x "$dest/id"
  else
    ln -s host-command "$dest/id"
  fi
  if [[ "$readlink_mode" == yes ]]; then
    ln -s "$READLINK_BIN" "$dest/readlink"
  fi
  case "$stat_mode" in
    real) ln -s "$STAT_BIN" "$dest/stat" ;;
    stub)
      cat > "$dest/stat" <<SH
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "\$1" == -c && "\$2" == '%u' && "\${3:-}" == "\$STAT_PROBE_PATH" &&
  -n "\${STAT_PROBE_UID:-}" ]]; then
  printf '%s\n' "\$STAT_PROBE_UID"
  exit 0
fi
exec "$STAT_BIN" "\$@"
SH
      chmod +x "$dest/stat"
      ;;
  esac
}

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
  printf 'v0.1.2-symlink-preflight-fixture\n' > "$case_dir/bundle/VERSION"
  cp "$PROJECT_ROOT/backend/bin/moddex" "$case_dir/bundle/backend/bin/moddex"
  cp "$PROJECT_ROOT/packaging/systemd/moddex-backend.service" \
    "$case_dir/bundle/packaging/systemd/moddex-backend.service"
  printf 'previous backend\n' > "$case_dir/host/opt/moddex/app.jar"
  printf 'previous version\n' > "$case_dir/host/opt/moddex/VERSION"
  printf 'previous frontend\n' > "$case_dir/host/var/lib/moddex/ui/index.html"
  printf 'provider-key=unexpected-token-secret\n' > "$case_dir/host/etc/moddex/config.env"
  # Expected content of the unrelated environment file, kept outside the
  # archived fixture tree for the unchanged-content assertion.
  "$CP_BIN" "$case_dir/host/etc/moddex/config.env" "$case_dir/config.env.expected"
  printf 'previous unit\n' > "$case_dir/host/etc/systemd/system/moddex-backend.service"
  printf 'previous cli\n' > "$case_dir/host/usr/local/bin/moddex"

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

# Builds a comparable manifest of the fixture tree: one line per entry with
# path, type and, depending on type, the raw link target or the POSIX cksum
# of the content. Symlinks are never dereferenced, so fixtures containing
# directory links compare safely and portably on BSD and GNU (plain diff -r
# follows them); LC_ALL=C keeps the sort order deterministic.
build_tree_manifest() {
  local root="$1" out="$2" p
  : > "$out"
  while IFS= read -r p; do
    if [[ "$p" == "." ]]; then
      continue
    fi
    if [[ -L "$p" ]]; then
      printf '%s\tlink\t%s\n' "$p" "$(readlink "$p")" >> "$out"
    elif [[ -d "$p" ]]; then
      printf '%s\tdir\n' "$p" >> "$out"
    elif [[ -f "$p" ]]; then
      printf '%s\tfile\t%s\n' "$p" "$(cksum < "$p")" >> "$out"
    else
      printf '%s\tother\n' "$p" >> "$out"
    fi
  done < <(cd "$root" && find . | LC_ALL=C sort)
}

snapshot_case() {
  # Called after the tamper setup, so the manifest comparison proves exactly
  # that the installer changed nothing beyond the staged tamper.
  local case_dir="$1"
  build_tree_manifest "$case_dir/host" "$case_dir/manifest.before"
  : > "$case_dir/commands"
}

run_installer() {
  # Runs the staged installer with the closed PATH and records the status.
  # Extra "NAME=VALUE" arguments are exported into the installer environment
  # for this case only.
  local case_dir="$1" bin_dir="$2" kv
  shift 2
  (
    unset PORT MODDEX_PORT MODE MODDEX_MODE BACKEND_JAR MODDEX_BACKEND_JAR \
      FRONTEND_DIR MODDEX_FRONTEND_DIR MODDEX_INSTALL_REEXEC MODDEX_LOCK_PID
    export PATH="$bin_dir" TEST_CASE_DIR="$case_dir" TEST_NONROOT=0 \
      TEST_EXPECTED_PORT=8080 TEST_EXPECTED_ADDRESS=0.0.0.0 \
      MODDEX_LOCK_FILE="$case_dir/host/run/moddex/install.lock" \
      BASH_BIN CP_BIN MKDIR_BIN CHMOD_BIN SED_BIN MV_BIN RM_BIN AWK_BIN
    for kv in ${1+"$@"}; do
      # Each argument is a complete NAME=VALUE assignment.
      # shellcheck disable=SC2163
      export "$kv"
    done
    "$BASH_BIN" "$case_dir/bundle/scripts/install.sh" --mode lan \
      --backend-jar "$case_dir/bundle/backend/Moddex-Backend.jar" \
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

assert_install_completed() {
  # A supported layout must complete the installation; the mutation spies
  # prove every deployment write, and the path preflight must have verified
  # the targets (issue #119 acceptance criterion 1).
  local name="$1" case_dir="$2" bin_dir="$3" status=0
  shift 3
  run_installer "$case_dir" "$bin_dir" "$@" || status=$?
  [[ "$status" -eq 0 ]] ||
    { cat "$case_dir/output" >&2; fail "$name: installer rejected a supported layout."; }
  grep -Fq 'Install path preflight passed' "$case_dir/output" ||
    fail "$name: successful run did not verify the installation paths."
  grep -Fxq '[moddex-install] Installation complete' "$case_dir/output" ||
    fail "$name: installation did not complete."
  grep -Fxq 'apt-get update -y' "$case_dir/commands" ||
    fail "$name: supported layout never reached package update."
  grep -Fxq 'systemctl enable --now moddex-backend.service' "$case_dir/commands" ||
    fail "$name: supported layout never completed the mocked installation."
  cmp "$case_dir/bundle/backend/Moddex-Backend.jar" "$case_dir/host/opt/moddex/app.jar" ||
    fail "$name: backend was not deployed."
  cmp "$case_dir/bundle/VERSION" "$case_dir/host/opt/moddex/VERSION" ||
    fail "$name: version was not persisted."
  cmp "$case_dir/bundle/frontend/index.html" "$case_dir/host/var/lib/moddex/ui/index.html" ||
    fail "$name: frontend was not deployed."
  cmp "$case_dir/bundle/backend/bin/moddex" "$case_dir/host/usr/local/bin/moddex" ||
    fail "$name: CLI helper was not deployed."
  cmp "$case_dir/config.env.expected" "$case_dir/host/etc/moddex/config.env" ||
    fail "$name: unrelated environment configuration changed."
  assert_output_has_no_secrets "$name" "$case_dir"
  case_count=$((case_count + 1))
}

assert_rejected_before_mutation() {
  # A tampered target must abort with the reason and a safe next action
  # before any mutating or privileged command runs and without changing any
  # fixture file (issue #119 acceptance criteria 1 and 3). The moddex-uid
  # probe is a read-only preflight lookup and is the only tolerated log line.
  local name="$1" expected_reason="$2" expected_action="$3" case_dir="$4" bin_dir="$5" status=0
  shift 5
  run_installer "$case_dir" "$bin_dir" "$@" || status=$?
  [[ "$status" -ne 0 ]] ||
    fail "$name: installer unexpectedly accepted the tampered target."
  grep -Fq "$expected_reason" "$case_dir/output" ||
    fail "$name: error message misses the tamper reason."
  grep -Fq "$expected_action" "$case_dir/output" ||
    fail "$name: error message misses the safe next action."
  if grep -Evq '^id -u moddex$' "$case_dir/commands"; then
    fail "$name: tampered target reached a mutation/privilege spy."
  fi
  build_tree_manifest "$case_dir/host" "$case_dir/manifest.after"
  if ! diff "$case_dir/manifest.before" "$case_dir/manifest.after" \
    > "$case_dir/tree-diff" 2>&1; then
    cat "$case_dir/tree-diff" >&2
    fail "$name: tampered target changed installation, environment or service files."
  fi
  assert_output_has_no_secrets "$name" "$case_dir"
  case_count=$((case_count + 1))
}

# --- Case 1: a clean layout installs with ownership verification ------------
make_bin "$TEST_DIR/bin-verify" real yes default
prepare_case clean-layout-installs
snapshot_case "$TEST_DIR/clean-layout-installs"
assert_install_completed clean-layout-installs \
  "$TEST_DIR/clean-layout-installs" "$TEST_DIR/bin-verify"
if grep -Fq 'Skipping installation path ownership verification' \
  "$TEST_DIR/clean-layout-installs/output"; then
  fail "clean-layout-installs: ownership verification was skipped although stat is available."
fi

# --- Case 2: app.jar symlinked outside the layout aborts before writes ------
make_bin "$TEST_DIR/bin-base" none yes default
prepare_case app-jar-symlink-outside
case_dir="$TEST_DIR/app-jar-symlink-outside"
mkdir "$case_dir/host/tmp"
printf 'planted evil jar\n' > "$case_dir/host/tmp/evil.jar"
rm "$case_dir/host/opt/moddex/app.jar"
ln -s "$case_dir/host/tmp/evil.jar" "$case_dir/host/opt/moddex/app.jar"
snapshot_case "$case_dir"
assert_rejected_before_mutation app-jar-symlink-outside \
  "is a symlink to" "outside the Moddex installation layout" \
  "$case_dir" "$TEST_DIR/bin-base"
grep -Fq 'MODDEX_ALLOWED_INSTALL_ROOTS' "$case_dir/output" ||
  fail "app-jar-symlink-outside: error does not name the explicit allowance."
if ! grep -Fq 'Skipping installation path ownership verification' "$case_dir/output"; then
  fail "app-jar-symlink-outside: the skipped ownership verification was not reported."
fi

# --- Case 3: the configuration directory symlinked away aborts --------------
prepare_case etc-moddex-symlink-outside
case_dir="$TEST_DIR/etc-moddex-symlink-outside"
mkdir "$case_dir/host/evil-etc"
"$MV_BIN" "$case_dir/host/etc/moddex/config.env" "$case_dir/host/evil-etc/config.env"
rmdir "$case_dir/host/etc/moddex"
ln -s "$case_dir/host/evil-etc" "$case_dir/host/etc/moddex"
snapshot_case "$case_dir"
assert_rejected_before_mutation etc-moddex-symlink-outside \
  "is a symlink to" "outside the Moddex installation layout" \
  "$case_dir" "$TEST_DIR/bin-base"

# --- Case 4: the systemd unit directory symlinked away aborts ---------------
prepare_case unit-dir-symlink-outside
case_dir="$TEST_DIR/unit-dir-symlink-outside"
mkdir "$case_dir/host/evil-units"
"$MV_BIN" "$case_dir/host/etc/systemd/system/moddex-backend.service" \
  "$case_dir/host/evil-units/moddex-backend.service"
rmdir "$case_dir/host/etc/systemd/system"
ln -s "$case_dir/host/evil-units" "$case_dir/host/etc/systemd/system"
snapshot_case "$case_dir"
assert_rejected_before_mutation unit-dir-symlink-outside \
  "is a symlink to" "outside the Moddex installation layout" \
  "$case_dir" "$TEST_DIR/bin-base"

# --- Case 5: an unverifiable symlink fails closed without readlink ---------
make_bin "$TEST_DIR/bin-no-readlink" none no default
prepare_case readlink-missing-fails-closed
case_dir="$TEST_DIR/readlink-missing-fails-closed"
mkdir "$case_dir/host/tmp"
printf 'planted evil jar\n' > "$case_dir/host/tmp/evil.jar"
rm "$case_dir/host/opt/moddex/app.jar"
ln -s "$case_dir/host/tmp/evil.jar" "$case_dir/host/opt/moddex/app.jar"
snapshot_case "$case_dir"
assert_rejected_before_mutation readlink-missing-fails-closed \
  "readlink is unavailable" "replace the symlink with a real file or directory" \
  "$case_dir" "$TEST_DIR/bin-no-readlink"

# --- Case 6: a foreign owner on a written target aborts (decision logic) ----
# The controlled stat stub reports a uid that is neither root, nor the
# invoking user, nor the moddex service account; this is deterministic for
# every runner regardless of privilege level.
make_bin "$TEST_DIR/bin-owner-stub" stub yes default
prepare_case foreign-owner-rejected
case_dir="$TEST_DIR/foreign-owner-rejected"
snapshot_case "$case_dir"
assert_rejected_before_mutation foreign-owner-rejected \
  "owned by uid" "Restore the expected ownership" \
  "$case_dir" "$TEST_DIR/bin-owner-stub" \
  "STAT_PROBE_PATH=$case_dir/host/opt/moddex/app.jar" \
  "STAT_PROBE_UID=$((EUID + 1))"
grep -Fq "uid $((EUID + 1))" "$case_dir/output" ||
  fail "foreign-owner-rejected: the reported owner uid is not named."

# --- Case 7: the moddex service account owner stays allowed -----------------
# The stub reports the same uid for app.jar that the id stub resolves for the
# moddex account; the installer must accept it and deploy as usual.
make_bin "$TEST_DIR/bin-owner-stub-moddex" stub yes moddex777
prepare_case moddex-owner-allowed
case_dir="$TEST_DIR/moddex-owner-allowed"
snapshot_case "$case_dir"
assert_install_completed moddex-owner-allowed \
  "$case_dir" "$TEST_DIR/bin-owner-stub-moddex" \
  "STAT_PROBE_PATH=$case_dir/host/opt/moddex/app.jar" "STAT_PROBE_UID=777"

# --- Case 8: real foreign ownership is rejected when deterministically -----
# reproducible. chown must actually take effect (root runner on a filesystem
# that honors it, for example a native CI workspace); on mounts that ignore
# chown the case is skipped with a note and the decision logic stays covered
# by the controlled stat stub in foreign-owner-rejected.
real_owner_uid() {
  local u
  if u="$("$STAT_BIN" -c '%u' "$1" 2>/dev/null)"; then
    printf '%s\n' "$u"
  else
    "$STAT_BIN" -f '%u' "$1"
  fi
}
prepare_case real-foreign-owner-rejected
case_dir="$TEST_DIR/real-foreign-owner-rejected"
if [[ "$EUID" -eq 0 ]] &&
  "$(command -v chown)" 65534 "$case_dir/host/opt/moddex/app.jar" 2>/dev/null &&
  [[ "$(real_owner_uid "$case_dir/host/opt/moddex/app.jar")" == 65534 ]]; then
  snapshot_case "$case_dir"
  assert_rejected_before_mutation real-foreign-owner-rejected \
    "owned by uid 65534" "Restore the expected ownership" \
    "$case_dir" "$TEST_DIR/bin-verify"
else
  printf 'Skipping the real-ownership case: this runner cannot assign a foreign uid deterministically (not root, or the filesystem ignores chown); the decision logic is covered by the controlled stat stub in foreign-owner-rejected.\n'
fi

# --- Case 9: in-layout symlinks stay usable and receive the writes ----------
prepare_case in-layout-symlinks-install
case_dir="$TEST_DIR/in-layout-symlinks-install"
mkdir "$case_dir/host/var/lib/moddex/ui-data"
"$MV_BIN" "$case_dir/host/var/lib/moddex/ui/index.html" \
  "$case_dir/host/var/lib/moddex/ui-data/index.html"
rmdir "$case_dir/host/var/lib/moddex/ui"
ln -s "$case_dir/host/var/lib/moddex/ui-data" "$case_dir/host/var/lib/moddex/ui"
"$MV_BIN" "$case_dir/host/opt/moddex/app.jar" "$case_dir/host/opt/moddex/app-actual.jar"
ln -s "$case_dir/host/opt/moddex/app-actual.jar" "$case_dir/host/opt/moddex/app.jar"
snapshot_case "$case_dir"
assert_install_completed in-layout-symlinks-install \
  "$case_dir" "$TEST_DIR/bin-verify"
cmp "$case_dir/bundle/backend/Moddex-Backend.jar" \
  "$case_dir/host/opt/moddex/app-actual.jar" ||
  fail "in-layout-symlinks-install: the write did not reach the symlinked jar."
cmp "$case_dir/bundle/frontend/index.html" \
  "$case_dir/host/var/lib/moddex/ui-data/index.html" ||
  fail "in-layout-symlinks-install: the write did not reach the symlinked ui."

# --- Case 10: an explicitly allowed relocation installs ---------------------
prepare_case extra-root-relocation-installs
case_dir="$TEST_DIR/extra-root-relocation-installs"
mkdir "$case_dir/host/srv"
"$MV_BIN" "$case_dir/host/opt/moddex/app.jar" "$case_dir/host/srv/app.jar"
"$MV_BIN" "$case_dir/host/opt/moddex/VERSION" "$case_dir/host/srv/VERSION"
rmdir "$case_dir/host/opt/moddex"
ln -s "$case_dir/host/srv" "$case_dir/host/opt/moddex"
snapshot_case "$case_dir"
assert_install_completed extra-root-relocation-installs \
  "$case_dir" "$TEST_DIR/bin-verify" \
  "MODDEX_ALLOWED_INSTALL_ROOTS=$case_dir/host/srv"
cmp "$case_dir/bundle/backend/Moddex-Backend.jar" "$case_dir/host/srv/app.jar" ||
  fail "extra-root-relocation-installs: the relocated app.jar was not deployed."
cmp "$case_dir/bundle/VERSION" "$case_dir/host/srv/VERSION" ||
  fail "extra-root-relocation-installs: the relocated VERSION was not written."
[[ -L "$case_dir/host/opt/moddex" ]] ||
  fail "extra-root-relocation-installs: the allowed relocation link was replaced."

# --- Case 11: the same relocation without the allowance aborts --------------
prepare_case extra-root-relocation-rejected
case_dir="$TEST_DIR/extra-root-relocation-rejected"
mkdir "$case_dir/host/srv"
"$MV_BIN" "$case_dir/host/opt/moddex/app.jar" "$case_dir/host/srv/app.jar"
"$MV_BIN" "$case_dir/host/opt/moddex/VERSION" "$case_dir/host/srv/VERSION"
rmdir "$case_dir/host/opt/moddex"
ln -s "$case_dir/host/srv" "$case_dir/host/opt/moddex"
snapshot_case "$case_dir"
assert_rejected_before_mutation extra-root-relocation-rejected \
  "is a symlink to" "outside the Moddex installation layout" \
  "$case_dir" "$TEST_DIR/bin-verify"

# --- Case 12: an invalid MODDEX_ALLOWED_INSTALL_ROOTS aborts ----------------
prepare_case extra-roots-invalid-rejected
case_dir="$TEST_DIR/extra-roots-invalid-rejected"
snapshot_case "$case_dir"
assert_rejected_before_mutation extra-roots-invalid-rejected \
  "absolute path" "Use absolute directory paths separated by colons" \
  "$case_dir" "$TEST_DIR/bin-verify" \
  "MODDEX_ALLOWED_INSTALL_ROOTS=fixture-relative/path"

printf 'Installer symlink/ownership preflight checks passed (%s cases; off-layout symlinks and foreign owners abort before any host change, supported layouts, in-layout symlinks and explicitly allowed relocations install).\n' "$case_count"
