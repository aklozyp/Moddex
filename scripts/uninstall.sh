#!/usr/bin/env bash
set -euo pipefail

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  printf '%s\n' \
    'Usage: uninstall.sh [--purge-data] [-h|--help]' \
    '' \
    'By default, remove the application JAR, version marker and systemd unit only.' \
    'Keep worlds, backups, configuration, other files and the moddex system account.' \
    '--purge-data  Also delete /opt/moddex, /var/lib/moddex, /etc/moddex and the account.' \
    '             The removal paths are displayed before a separate confirmation.'
}

purge_data=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data) purge_data=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 'Unknown argument. Use uninstall.sh --help for supported options.' ;;
  esac
done

printf 'Moddex uninstall will remove:\n  /etc/systemd/system/moddex-backend.service\n'
if [[ "$purge_data" == true ]]; then
  printf '%s\n' \
    '  /opt/moddex' \
    '  /var/lib/moddex (including worlds and backups)' \
    '  /etc/moddex (configuration)' \
    'The moddex system account will also be deleted.' \
    'WARNING: --purge-data permanently deletes these directories and their contents.' \
    'Custom data paths outside these directories are not removed.'
  prompt='Permanently delete this data and uninstall Moddex? [y/N] '
else
  printf '%s\n' \
    '  /opt/moddex/app.jar' \
    '  /opt/moddex/VERSION' \
    'Retaining /var/lib/moddex (worlds and backups), /etc/moddex (configuration),' \
    'all other files in /opt/moddex, and the moddex system account with its ownership.' \
    'Use --purge-data only if you also want to permanently delete the retained data.'
  prompt='Uninstall Moddex and retain data? [y/N] '
fi

if ! read -r -p "$prompt" answer; then
  die 'No confirmation received. Nothing was changed; rerun interactively and enter y to proceed.'
fi
case "$answer" in
  y|Y) ;;
  *) printf 'Uninstall cancelled. Nothing was changed.\n'; exit 0 ;;
esac

command -v sudo >/dev/null 2>&1 ||
  die 'sudo is required. Install sudo and rerun the uninstaller with an account allowed to administer Moddex.'

remove_or_die() {
  local message="$1"
  shift
  if ! sudo rm "$@" >/dev/null 2>&1; then
    die "$message"
  fi
}

read_service_state() {
  local state property value
  load_state=unknown active_state=unknown main_pid=unknown service_result=unknown
  if ! state="$(sudo systemctl show moddex-backend --property=LoadState,ActiveState,MainPID,Result 2>/dev/null)"; then
    return 1
  fi
  # Only display known systemd values, never arbitrary command output.
  while IFS='=' read -r property value; do
    case "$property:$value" in
      LoadState:loaded|LoadState:not-found|LoadState:masked|LoadState:error|LoadState:bad-setting|LoadState:stub|LoadState:merged)
        load_state="$value" ;;
      ActiveState:active|ActiveState:inactive|ActiveState:failed|ActiveState:activating|ActiveState:deactivating|ActiveState:reloading|ActiveState:maintenance|ActiveState:refreshing)
        active_state="$value" ;;
      MainPID:*)
        if [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then main_pid="$value"; fi ;;
      Result:success|Result:resources|Result:timeout|Result:exit-code|Result:signal|Result:core-dump|Result:watchdog|Result:start-limit-hit|Result:oom-kill|Result:protocol|Result:exec-condition)
        service_result="$value" ;;
    esac
  done <<< "$state"
  [[ "$load_state" != unknown && "$active_state" != unknown && "$main_pid" != unknown ]]
}

report_processes() {
  local processes pid name extra reported=false
  local selectors=(-u moddex)
  if [[ "$main_pid" != unknown && "$main_pid" != 0 ]]; then
    selectors+=(-p "$main_pid")
  fi
  if processes="$(sudo ps "${selectors[@]}" -o pid=,comm= 2>/dev/null)"; then
    while read -r pid name extra; do
      if [[ "$pid" =~ ^[1-9][0-9]*$ && "$name" =~ ^[[:alnum:]_.-]+$ && -z "$extra" ]]; then
        printf '  PID %s: %s\n' "$pid" "$name" >&2
        reported=true
      fi
    done <<< "$processes"
    if [[ "$reported" == false ]]; then
      printf 'No matching process names were reported; this does not prove a successful stop.\n' >&2
    fi
  else
    printf 'Process diagnostics unavailable. Check sudo permissions; inspect with sudo ps -u moddex -o pid=,comm=.\n' >&2
  fi
}

abort_before_removal() {
  printf '[ERROR] %s No files or accounts were removed.\n' "$1" >&2
  printf 'moddex-backend: LoadState=%s ActiveState=%s MainPID=%s Result=%s\n' \
    "$load_state" "$active_state" "$main_pid" "$service_result" >&2
  report_processes
  die 'Resolve sudo/systemd errors and stop Moddex and the listed processes cleanly before rerunning the uninstaller. Check with sudo systemctl show moddex-backend --property=LoadState,ActiveState,MainPID,Result. Rerunning --purge-data requires confirmation again.'
}

service_is_stopped() {
  [[ "$active_state" == inactive && "$main_pid" == 0 ]]
}

if ! read_service_state; then
  abort_before_removal 'Could not verify the initial service state; the systemctl query failed or returned incomplete/unknown state.'
fi
if [[ "$load_state" == not-found ]]; then
  # An explicitly absent, inactive unit is safe for repeated uninstalls.
  if ! service_is_stopped; then
    abort_before_removal 'The missing service unit is not confirmed inactive.'
  fi
else
  stop_status=0
  sudo systemctl disable --now moddex-backend >/dev/null 2>&1 || stop_status=$?
  state_verified=true
  read_service_state || state_verified=false
  if [[ "$stop_status" -ne 0 ]]; then
    abort_before_removal "systemctl disable --now moddex-backend failed (exit $stop_status)."
  fi
  if [[ "$state_verified" == false ]]; then
    abort_before_removal 'Could not verify the service state after stopping; the systemctl query failed or returned incomplete/unknown state.'
  fi
  if ! service_is_stopped; then
    abort_before_removal 'moddex-backend is not confirmed inactive with MainPID=0 after stopping.'
  fi
fi
remove_or_die 'Could not remove the Moddex systemd unit. Check sudo permissions and /etc/systemd/system, then rerun the uninstaller.' \
  -f -- /etc/systemd/system/moddex-backend.service
if ! sudo systemctl daemon-reload >/dev/null 2>&1; then
  printf '[WARNING] Could not reload systemd; run sudo systemctl daemon-reload after resolving the systemd error.\n' >&2
fi

if [[ "$purge_data" == true ]]; then
  remove_or_die 'Could not completely remove /opt/moddex, /var/lib/moddex and /etc/moddex. The moddex account was retained; check permissions and filesystem mounts, then rerun with --purge-data only if deletion is still intended.' \
    -rf -- /opt/moddex /var/lib/moddex /etc/moddex
  if sudo userdel moddex >/dev/null 2>&1; then
    :
  else
    status=$?
    if [[ "$status" -ne 6 ]]; then
      die 'Data directories were removed, but the moddex account could not be deleted. Check for remaining processes with ps -u moddex -o pid=,comm=, then retry sudo userdel moddex.'
    fi
  fi
  printf 'Moddex, its data directories and its system account removed.\n'
else
  remove_or_die 'Could not remove /opt/moddex/app.jar and /opt/moddex/VERSION. Data and the moddex account were retained; check permissions and rerun the uninstaller.' \
    -f -- /opt/moddex/app.jar /opt/moddex/VERSION
  printf 'Moddex uninstalled. Data, configuration, other files and the moddex account retained.\n'
fi
