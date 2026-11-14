#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TEST_DIR="$PROJECT_ROOT/.uninstall-data-policy-test.$$"
BASH_BIN="$(command -v bash)"
RM_BIN="$(command -v rm)"

mkdir "$TEST_DIR"
cleanup() {
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.uninstall-data-policy-test.* &&
    -d "$TEST_DIR" && ! -L "$TEST_DIR" ]]; then
    "$RM_BIN" -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT
mkdir "$TEST_DIR/bin" "$TEST_DIR/no-sudo-bin"

cat > "$TEST_DIR/bin/sudo" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "$FIXTURE" == "$TEST_DIR/"* && -d "$FIXTURE" && ! -L "$FIXTURE" ]] || exit 98
printf '%s\n' "$*" >> "$TEST_DIR/commands"
case "$*" in
  'systemctl show moddex-backend --property=LoadState,ActiveState,MainPID,Result')
    if [[ "${FAIL_ACTION:-}" == status-before ||
      ( -f "$TEST_DIR/stop-attempted" && "${FAIL_ACTION:-}" == *status-failed ) ]]; then
      printf 'secret-from-command\n'
      printf 'secret-from-command\n' >&2
      exit 52
    fi
    load=loaded active=active pid=4312 result=success
    if [[ ! -f "$FIXTURE/etc/systemd/system/moddex-backend.service" ]]; then
      load=not-found active=inactive pid=0
    elif [[ -f "$TEST_DIR/stop-attempted" ]]; then
      active=inactive pid=0
      case "${FAIL_ACTION:-}" in
        stop|stop-diagnostics-failed)
          active=deactivating pid=4312 result=timeout ;;
        still-running)
          active=active pid=4312 ;;
        lingering-pid)
          pid=4312 ;;
        missing-running)
          load=not-found active=active pid=4312 ;;
        status-incomplete)
          printf 'LoadState=loaded\nActiveState=inactive\n'
          exit 0 ;;
        status-unknown)
          active=unexpected-token-secret result=unexpected-token-secret ;;
      esac
    fi
    printf 'LoadState=%s\nActiveState=%s\nMainPID=%s\nResult=%s\n' "$load" "$active" "$pid" "$result"
    ;;
  'systemctl disable --now moddex-backend')
    : > "$TEST_DIR/stop-attempted"
    case "${FAIL_ACTION:-}" in
      stop|stop-inactive|stop-status-failed|stop-diagnostics-failed)
        printf 'secret-from-command\n' >&2
        exit 51 ;;
    esac
    ;;
  'ps -u moddex -o pid=,comm='|'ps -u moddex -p 4312 -o pid=,comm=')
    if [[ "${FAIL_ACTION:-}" == stop-diagnostics-failed ]]; then
      printf 'secret-from-command\n'
      printf 'secret-from-command\n' >&2
      exit 53
    fi
    printf ' 4312 java\n 4313 minecraft\n'
    printf 'invalid-pid unexpected-token-secret\n 4314 java --provider-key=unexpected-token-secret\n'
    ;;
  'systemctl daemon-reload') ;;
  'rm -f -- /etc/systemd/system/moddex-backend.service')
    [[ "${FAIL_ACTION:-}" != unit ]] || { printf 'secret-from-command\n' >&2; exit 41; }
    "$RM_BIN" -f -- "$FIXTURE/etc/systemd/system/moddex-backend.service"
    ;;
  'rm -f -- /opt/moddex/app.jar /opt/moddex/VERSION')
    [[ "${FAIL_ACTION:-}" != application ]] || { printf 'secret-from-command\n' >&2; exit 42; }
    "$RM_BIN" -f -- "$FIXTURE/opt/moddex/app.jar" "$FIXTURE/opt/moddex/VERSION"
    ;;
  'rm -rf -- /opt/moddex /var/lib/moddex /etc/moddex')
    [[ "${FAIL_ACTION:-}" != data ]] || { printf 'secret-from-command\n' >&2; exit 43; }
    "$RM_BIN" -rf -- "$FIXTURE/opt/moddex" "$FIXTURE/var/lib/moddex" "$FIXTURE/etc/moddex"
    ;;
  'userdel moddex')
    [[ "${FAIL_ACTION:-}" != account ]] || { printf 'secret-from-command\n' >&2; exit 44; }
    [[ -f "$FIXTURE/account" ]] || exit 6
    "$RM_BIN" -f -- "$FIXTURE/account"
    ;;
  *) printf 'Unexpected privileged command blocked.\n' >&2; exit 99 ;;
esac
SH
chmod +x "$TEST_DIR/bin/sudo"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

new_fixture() {
  local name="$1"
  FIXTURE="$TEST_DIR/$name"
  mkdir -p "$FIXTURE/opt/moddex" "$FIXTURE/var/lib/moddex/worlds/example" \
    "$FIXTURE/var/lib/moddex/backups" "$FIXTURE/etc/moddex" "$FIXTURE/etc/systemd/system" \
    "$FIXTURE/custom-data" "$FIXTURE/unrelated"
  printf 'world\n' > "$FIXTURE/var/lib/moddex/worlds/example/level.dat"
  printf 'backup\n' > "$FIXTURE/var/lib/moddex/backups/example.zip"
  printf 'secret-config\n' > "$FIXTURE/etc/moddex/application.yml"
  printf 'custom-config\n' > "$FIXTURE/opt/moddex/application.yml"
  printf 'jar\n' > "$FIXTURE/opt/moddex/app.jar"
  printf 'version\n' > "$FIXTURE/opt/moddex/VERSION"
  printf 'unit\n' > "$FIXTURE/etc/systemd/system/moddex-backend.service"
  printf 'moddex:retained-owner\n' > "$FIXTURE/account"
  printf 'outside-data\n' > "$FIXTURE/custom-data/world"
  printf 'unrelated\n' > "$FIXTURE/unrelated/file"
  : > "$TEST_DIR/commands"
  "$RM_BIN" -f -- "$TEST_DIR/stop-attempted"
}

run_uninstaller() {
  local input="$1" expected_status="$2" failure="$3" status=0
  shift 3
  printf '%s' "$input" | PATH="$TEST_PATH" TEST_DIR="$TEST_DIR" FIXTURE="$FIXTURE" \
    RM_BIN="$RM_BIN" FAIL_ACTION="$failure" \
    "$BASH_BIN" "$PROJECT_ROOT/scripts/uninstall.sh" "$@" > "$TEST_DIR/output" 2>&1 || status=$?
  [[ "$status" -eq "$expected_status" ]] ||
    fail "Expected exit $expected_status, received $status."
  if grep -Eq 'secret-config|secret-from-command|unexpected-token-secret' "$TEST_DIR/output"; then
    fail 'Uninstaller exposed sensitive input or command output.'
  fi
}

run_policy_uninstaller() {
  local policy="$1"
  shift
  if [[ "$policy" == purge ]]; then
    run_uninstaller "$@" --purge-data
  else
    run_uninstaller "$@"
  fi
}

assert_output() {
  grep -Fq -- "$1" "$TEST_DIR/output" || fail "Missing output: $1"
}

assert_no_commands() {
  [[ ! -s "$TEST_DIR/commands" ]] || fail 'Privileged commands ran without consent.'
}

assert_retained_data() {
  [[ "$(cat "$FIXTURE/var/lib/moddex/worlds/example/level.dat")" == world ]] ||
    fail 'World data changed.'
  [[ "$(cat "$FIXTURE/var/lib/moddex/backups/example.zip")" == backup ]] ||
    fail 'Backup data changed.'
  [[ "$(cat "$FIXTURE/etc/moddex/application.yml")" == secret-config ]] ||
    fail 'Configuration changed.'
  [[ "$(cat "$FIXTURE/opt/moddex/application.yml")" == custom-config ]] ||
    fail 'Non-program files in /opt/moddex changed.'
  [[ "$(cat "$FIXTURE/account")" == moddex:retained-owner ]] ||
    fail 'Retained account ownership changed.'
  [[ -O "$FIXTURE/var/lib/moddex/worlds/example/level.dat" &&
    -O "$FIXTURE/etc/moddex/application.yml" ]] || fail 'Retained file ownership changed.'
}

assert_unrelated_data() {
  [[ "$(cat "$FIXTURE/custom-data/world")" == outside-data &&
    "$(cat "$FIXTURE/unrelated/file")" == unrelated ]] || fail 'Unrelated data changed.'
}

assert_no_removal() {
  if grep -Eq '^rm |^userdel |^systemctl daemon-reload$' "$TEST_DIR/commands"; then
    fail 'Uninstaller attempted removal or reloaded systemd without a verified stop.'
  fi
  assert_retained_data
  assert_unrelated_data
  [[ "$(cat "$FIXTURE/opt/moddex/app.jar")" == jar &&
    "$(cat "$FIXTURE/opt/moddex/VERSION")" == version &&
    "$(cat "$FIXTURE/etc/systemd/system/moddex-backend.service")" == unit ]] ||
    fail 'Unverified stop did not preserve the application and service unit.'
  assert_output 'No files or accounts were removed.'
  assert_output 'Resolve sudo/systemd errors and stop Moddex and the listed processes cleanly'
  assert_output 'Rerunning --purge-data requires confirmation again.'
}

assert_stop_before_removal() {
  [[ "$(head -n 3 "$TEST_DIR/commands")" == \
    $'systemctl show moddex-backend --property=LoadState,ActiveState,MainPID,Result\nsystemctl disable --now moddex-backend\nsystemctl show moddex-backend --property=LoadState,ActiveState,MainPID,Result' ]] ||
    fail 'Uninstaller did not check, stop and verify the service before removal.'
}

TEST_PATH="$TEST_DIR/bin"
new_fixture default
run_uninstaller $'y\n' 0 ''
assert_stop_before_removal
assert_retained_data
assert_unrelated_data
[[ ! -e "$FIXTURE/opt/moddex/app.jar" && ! -e "$FIXTURE/opt/moddex/VERSION" &&
  ! -e "$FIXTURE/etc/systemd/system/moddex-backend.service" ]] ||
  fail 'Default uninstall left program files or the service unit.'
assert_output 'Data, configuration, other files and the moddex account retained.'
if grep -Eq '^userdel |^rm -rf ' "$TEST_DIR/commands"; then
  fail 'Default uninstall attempted recursive data or account deletion.'
fi

for option in default purge; do
  for answer in $'\n' $'n\n' $'yes\n'; do
    new_fixture "decline-$option-${#answer}"
    run_policy_uninstaller "$option" "$answer" 0 ''
    assert_no_commands
    assert_retained_data
    assert_output 'Uninstall cancelled.'
    if [[ "$option" == purge ]]; then
      for path in /opt/moddex /var/lib/moddex /etc/moddex /etc/systemd/system/moddex-backend.service; do
        assert_output "  $path"
      done
      assert_output 'WARNING: --purge-data permanently deletes'
    fi
  done
  new_fixture "eof-$option"
  run_policy_uninstaller "$option" '' 1 ''
  assert_no_commands
  assert_retained_data
  assert_output 'No confirmation received. Nothing was changed; rerun interactively'
done

new_fixture purge
run_uninstaller $'Y\n' 0 '' --purge-data
assert_stop_before_removal
for path in /opt/moddex /var/lib/moddex /etc/moddex /etc/systemd/system/moddex-backend.service; do
  assert_output "  $path"
  [[ ! -e "$FIXTURE$path" ]] || fail "Purge did not remove $path."
done
[[ ! -e "$FIXTURE/account" ]] || fail 'Purge did not remove the system account.'
assert_output 'WARNING: --purge-data permanently deletes'
assert_output 'Custom data paths outside these directories are not removed.'
assert_unrelated_data
: > "$TEST_DIR/commands"
run_uninstaller $'y\n' 0 '' --purge-data
assert_output 'Moddex, its data directories and its system account removed.'
if grep -q '^systemctl disable ' "$TEST_DIR/commands"; then
  fail 'Repeated purge tried to stop an explicitly absent, inactive unit.'
fi

new_fixture default-not-installed
"$RM_BIN" -f -- "$FIXTURE/etc/systemd/system/moddex-backend.service" \
  "$FIXTURE/opt/moddex/app.jar" "$FIXTURE/opt/moddex/VERSION"
run_uninstaller $'y\n' 0 ''
assert_retained_data
assert_unrelated_data
if grep -q '^systemctl disable ' "$TEST_DIR/commands"; then
  fail 'Default uninstall tried to stop an explicitly absent, inactive unit.'
fi

for option in default purge; do
  for failure in stop stop-inactive stop-status-failed stop-diagnostics-failed \
    status-before status-failed status-incomplete status-unknown still-running lingering-pid missing-running; do
    new_fixture "$option-$failure"
    run_policy_uninstaller "$option" $'y\n' 1 "$failure"
    assert_no_removal
    case "$failure" in
      stop|stop-inactive|stop-status-failed|stop-diagnostics-failed)
        assert_output 'systemctl disable --now moddex-backend failed (exit 51).'
        [[ "$(grep -c '^systemctl disable ' "$TEST_DIR/commands")" -eq 1 ]] ||
          fail 'Uninstaller retried a failed stop.'
        ;;
      status-before)
        assert_output 'Could not verify the initial service state'
        if grep -q '^systemctl disable ' "$TEST_DIR/commands"; then
          fail 'Uninstaller ignored an unknown initial service state.'
        fi
        ;;
      status-failed|status-incomplete|status-unknown)
        assert_output 'Could not verify the service state after stopping'
        ;;
      still-running|lingering-pid|missing-running)
        assert_output 'not confirmed inactive with MainPID=0 after stopping.'
        ;;
    esac
    if [[ "$failure" == stop-diagnostics-failed ]]; then
      assert_output 'Process diagnostics unavailable. Check sudo permissions'
    else
      assert_output 'PID 4312: java'
      assert_output 'PID 4313: minecraft'
    fi
    if [[ "$failure" == stop ]]; then
      assert_output 'LoadState=loaded ActiveState=deactivating MainPID=4312 Result=timeout'
    fi
  done
done

new_fixture absent-status-failure
"$RM_BIN" -f -- "$FIXTURE/etc/systemd/system/moddex-backend.service"
run_uninstaller $'y\n' 1 status-before --purge-data
assert_retained_data
assert_unrelated_data
if grep -Eq '^rm |^userdel ' "$TEST_DIR/commands"; then
  fail 'An absent unit allowed purge despite a failed status query.'
fi
assert_output 'Could not verify the initial service state'

for option in -h --help; do
  new_fixture "help-${#option}"
  run_uninstaller '' 0 '' "$option"
  assert_no_commands
  assert_output 'Usage: uninstall.sh [--purge-data]'
done
new_fixture unknown
run_uninstaller $'y\n' 1 '' --unexpected-token-secret
assert_no_commands
assert_retained_data
assert_output 'Unknown argument. Use uninstall.sh --help'

new_fixture missing-sudo
TEST_PATH="$TEST_DIR/no-sudo-bin"
run_uninstaller $'y\n' 1 ''
assert_no_commands
assert_retained_data
assert_output 'sudo is required. Install sudo and rerun'
TEST_PATH="$TEST_DIR/bin"

for failure in unit application data account; do
  new_fixture "failure-$failure"
  option=default
  [[ "$failure" != data && "$failure" != account ]] || option=purge
  run_policy_uninstaller "$option" $'y\n' 1 "$failure"
  case "$failure" in
    unit)
      assert_retained_data
      [[ -f "$FIXTURE/opt/moddex/app.jar" ]] || fail 'Unit removal failure did not stop uninstall.'
      assert_output 'Could not remove the Moddex systemd unit. Check sudo permissions'
      ;;
    application)
      assert_retained_data
      assert_output 'Data and the moddex account were retained; check permissions and rerun'
      ;;
    data)
      assert_retained_data
      assert_output 'check permissions and filesystem mounts, then rerun with --purge-data'
      if grep -q '^userdel ' "$TEST_DIR/commands"; then
        fail 'Purge removed the account after data removal failed.'
      fi
      ;;
    account)
      [[ -f "$FIXTURE/account" ]] || fail 'Failing account removal changed the account.'
      assert_output 'Check for remaining processes with ps -u moddex -o pid=,comm=, then retry sudo userdel moddex.'
      ;;
  esac
  assert_unrelated_data
done

printf 'Uninstall data-policy checks passed (retention, purge, consent, verified stops and safe failure diagnostics).\n'
