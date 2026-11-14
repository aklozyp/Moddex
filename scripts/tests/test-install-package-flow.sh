#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.install-package-flow-test.$$"
MKDIR_BIN="$(command -v mkdir)"
export MKDIR_BIN

if [[ -e "$TEST_DIR" ]]; then
  printf 'Test directory already exists: %s\n' "$TEST_DIR" >&2
  exit 1
fi

mkdir "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"
# The systemd preflight runs before the package steps under test; the
# fixture simulates a systemd host so the flow reaches the apt steps.
mkdir -p "$TEST_DIR/run/systemd/system"
# The host lock (issue #108) is acquired before the package steps; the lock
# file is redirected into this fixture.
TEST_LOCK_DIR="$TEST_DIR/lock"
mkdir "$TEST_LOCK_DIR"

TEST_DIR="$TEST_DIR" awk '
  $0 == "if [[ \"${EUID:-$(id -u)}\" -ne 0 ]]; then" {
    print "if false; then"
    replaced = 1
    next
  }
  $0 == "MODE=\"${MODE,,}\"" {
    print "MODE=\"${MODE}\""
    mode_replaced = 1
    next
  }
  {
    # The install path preflight (#119) runs before the package steps under
    # test; its targets are redirected into the fixture so the suite never
    # inspects the real systemwide paths of the machine running the tests.
    gsub("/opt/moddex", ENVIRON["TEST_DIR"] "/host/opt/moddex")
    gsub("/var/lib/moddex", ENVIRON["TEST_DIR"] "/host/var/lib/moddex")
    gsub("/etc/moddex", ENVIRON["TEST_DIR"] "/host/etc/moddex")
    gsub("/etc/systemd/system", ENVIRON["TEST_DIR"] "/host/etc/systemd/system")
    gsub("/run/systemd/system", ENVIRON["TEST_DIR"] "/run/systemd/system")
    gsub("/usr/local/bin", ENVIRON["TEST_DIR"] "/host/usr/local/bin")
    print
  }
  END { if (!replaced || !mode_replaced) exit 1 }
' "$PROJECT_ROOT/scripts/install.sh" > "$TEST_DIR/install.sh"
if ! grep -Fq 'if false; then' "$TEST_DIR/install.sh"; then
  printf 'Could not prepare non-privileged installer test copy.\n' >&2
  exit 1
fi

# The lock acquisition (issue #108) runs before the package steps: the closed
# fixture PATH needs flock (real where available, otherwise a perl stub with
# the same kernel-lock semantics), the lock directory creation via install -d,
# and the metadata timestamp.
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
# The install stub is a bash script (the other fixture stubs are POSIX sh);
# the closed PATH must carry bash for its shebang.
ln -s "$(command -v bash)" "$TEST_DIR/bin/bash"
cat > "$TEST_DIR/bin/install" <<SH
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "\$#" -eq 4 && "\$1" == -d && "\$2" == -m && "\$3" == 0755 &&
  "\$4" == "$TEST_LOCK_DIR" ]] || exit 91
"$MKDIR_BIN" -p "\$4"
SH
chmod +x "$TEST_DIR/bin/install"

cat > "$TEST_DIR/bin/dirname" <<'SH'
#!/bin/sh
case "$1" in
  */*) printf '%s\n' "${1%/*}" ;;
  *) printf '.\n' ;;
esac
SH

cat > "$TEST_DIR/bin/apt-get" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$APT_LOG"
case "${1:-}" in
  update) [ "${APT_FAILURE:-}" = update ] && exit 41 ;;
  install) [ "${APT_FAILURE:-}" = install ] && exit 42 ;;
  *) exit 99 ;;
esac
exit 0
SH

cat > "$TEST_DIR/bin/systemctl" <<'SH'
#!/bin/sh
# The systemd preflight only checks for systemctl's presence; the flows
# under test must abort at the package steps before any systemctl call.
exit 91
SH

chmod +x "$TEST_DIR/bin/dirname" "$TEST_DIR/bin/apt-get" "$TEST_DIR/bin/systemctl"
mkdir "$TEST_DIR/no-apt-bin"
cp "$TEST_DIR/bin/dirname" "$TEST_DIR/no-apt-bin/dirname"
cp "$TEST_DIR/bin/systemctl" "$TEST_DIR/no-apt-bin/systemctl"
# The lock acquisition precedes the rsync check as well.
cp "$TEST_DIR/bin/flock" "$TEST_DIR/no-apt-bin/flock" 2>/dev/null ||
  ln -s "$(command -v flock)" "$TEST_DIR/no-apt-bin/flock"
cp "$TEST_DIR/bin/date" "$TEST_DIR/no-apt-bin/date"
cp "$TEST_DIR/bin/install" "$TEST_DIR/no-apt-bin/install"
ln -s "$(command -v bash)" "$TEST_DIR/no-apt-bin/bash"
# The backend JAR preflight rejects empty files before packages are touched,
# so this flow test installs a non-empty fixture JAR.
printf 'fixture backend\n' > "$TEST_DIR/backend.jar"

if PATH="$TEST_DIR/bin" /bin/bash -c 'command -v rsync >/dev/null 2>&1'; then
  printf 'Test setup unexpectedly provides rsync.\n' >&2
  exit 1
fi

run_installer() {
  local failure="$1" expected_message="$2" status
  : > "$TEST_DIR/apt.log"

  if PATH="$TEST_DIR/bin" APT_LOG="$TEST_DIR/apt.log" APT_FAILURE="$failure" \
    MODDEX_LOCK_FILE="$TEST_LOCK_DIR/install.lock" \
    /bin/bash "$TEST_DIR/install.sh" --mode local --backend-jar "$TEST_DIR/backend.jar" --version v0.1.2-fixture \
    > "$TEST_DIR/output" 2>&1; then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -eq 0 ]]; then
    printf 'Installer unexpectedly succeeded for apt-get %s failure.\n' "$failure" >&2
    cat "$TEST_DIR/output" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" "$TEST_DIR/output"; then
    printf 'Expected failure reason was not reported: %s\n' "$expected_message" >&2
    cat "$TEST_DIR/output" >&2
    exit 1
  fi
}

run_installer update 'apt-get update failed'
if ! grep -Fq 'update -y' "$TEST_DIR/apt.log" || grep -q '^install ' "$TEST_DIR/apt.log"; then
  printf 'apt-get update failure did not stop at the update step.\n' >&2
  cat "$TEST_DIR/apt.log" >&2
  exit 1
fi

run_installer install 'apt-get install failed'
if ! grep -Fq 'update -y' "$TEST_DIR/apt.log" ||
  ! grep -Fq 'install -y --no-install-recommends openjdk-17-jre-headless rsync' "$TEST_DIR/apt.log"; then
  printf 'Installer did not reach package installation without rsync.\n' >&2
  cat "$TEST_DIR/apt.log" >&2
  exit 1
fi

: > "$TEST_DIR/apt.log"
if PATH="$TEST_DIR/no-apt-bin" APT_LOG="$TEST_DIR/apt.log" APT_FAILURE="" \
  MODDEX_LOCK_FILE="$TEST_LOCK_DIR/install.lock" \
  /bin/bash "$TEST_DIR/install.sh" --mode local --backend-jar "$TEST_DIR/backend.jar" --version v0.1.2-fixture \
  > "$TEST_DIR/output" 2>&1; then
  printf 'Installer unexpectedly succeeded without apt-get and rsync.\n' >&2
  exit 1
fi
if ! grep -Fq "rsync is required but was not found. Install it with your platform's package manager" "$TEST_DIR/output"; then
  printf 'Non-Debian path did not provide an actionable rsync dependency message.\n' >&2
  cat "$TEST_DIR/output" >&2
  exit 1
fi
if [[ -s "$TEST_DIR/apt.log" ]]; then
  printf 'Installer unexpectedly invoked apt-get when it was unavailable.\n' >&2
  cat "$TEST_DIR/apt.log" >&2
  exit 1
fi

printf 'Installer package-flow checks passed (missing rsync, apt failures, and non-Debian dependency reported).\n'
