#!/usr/bin/env bash
#
# Moddex recovery smoke test.
#
# Exercises the backup/restore and mod-listing REST endpoints against a running
# Moddex backend, so a release candidate can be checked end-to-end before ship.
# See docs/qa/recovery-checklist.md for the full manual matrix.
#
# Usage:
#   BASE_URL=http://127.0.0.1:8080 TOKEN=<jwt> INSTANCE_ID=<uuid> \
#     scripts/smoke-test.sh [--with-restore]
#
# Environment:
#   BASE_URL      Backend base URL (default: http://127.0.0.1:8080)
#   TOKEN         JWT bearer token from /api/v1/auth/login (required for auth'd calls)
#   INSTANCE_ID   Instance UUID to exercise (required for backup/mod checks)
#
# Flags:
#   --with-restore   Also run the (destructive) restore step. Restore overwrites
#                    the current instance state, so it is opt-in only.
#
# Exit code is non-zero if any checked step fails.

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
TOKEN="${TOKEN:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
WITH_RESTORE=0

for arg in "$@"; do
  case "$arg" in
    --with-restore) WITH_RESTORE=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

pass=0
fail=0

log()  { printf '[smoke] %s\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }

# Performs a GET and echoes the HTTP status code.
http_status() {
  local method="$1" path="$2"
  shift 2
  curl -s -o /dev/null -w '%{http_code}' -X "$method" "$@" "${BASE_URL}${path}"
}

auth_header() { [[ -n "$TOKEN" ]] && printf 'Authorization: Bearer %s' "$TOKEN"; }

require_instance() {
  if [[ -z "$INSTANCE_ID" ]]; then
    log "INSTANCE_ID not set; skipping instance-scoped checks."
    return 1
  fi
  return 0
}

log "Target: $BASE_URL"

# --- 1. Reachability (no auth required) ---
status=$(http_status GET /api/v1/setup/status)
if [[ "$status" == "200" ]]; then
  ok "backend reachable (/setup/status -> 200)"
else
  bad "backend not reachable (/setup/status -> $status)"
  log "Aborting: backend unreachable."
  exit 1
fi

# --- 2. Auth enforcement: a protected endpoint must reject anonymous calls ---
anon=$(http_status GET /api/v1/instance)
if [[ "$anon" == "401" || "$anon" == "403" ]]; then
  ok "protected endpoint rejects anonymous access (/instance -> $anon)"
elif [[ "$anon" == "200" ]]; then
  bad "protected endpoint served WITHOUT a token (/instance -> 200) — auth not enforced"
else
  log "unexpected anonymous status for /instance: $anon (continuing)"
fi

# The remaining checks need a token.
if [[ -z "$TOKEN" ]]; then
  log "TOKEN not set; skipping authenticated checks."
  log "Result: $pass passed, $fail failed."
  [[ "$fail" -eq 0 ]] && exit 0 || exit 1
fi

authed=$(http_status GET /api/v1/instance -H "$(auth_header)")
if [[ "$authed" == "200" ]]; then
  ok "authenticated instance list (/instance -> 200)"
else
  bad "authenticated instance list failed (/instance -> $authed)"
fi

# --- 3. Mod listing (covers the read side of mod changes) ---
if require_instance; then
  mods=$(http_status GET "/api/v1/instance/${INSTANCE_ID}/mods" -H "$(auth_header)")
  if [[ "$mods" == "200" ]]; then
    ok "mod list reachable (/mods -> 200)"
  else
    bad "mod list failed (/mods -> $mods)"
  fi
fi

# --- 4. Backup create + list ---
if require_instance; then
  before=$(curl -s -H "$(auth_header)" "${BASE_URL}/api/v1/instance/${INSTANCE_ID}/backups" \
    | grep -o '"name"' | wc -l | tr -d ' ')

  create=$(http_status POST "/api/v1/instance/${INSTANCE_ID}/backups" -H "$(auth_header)")
  if [[ "$create" == "200" || "$create" == "201" ]]; then
    ok "backup created (POST /backups -> $create)"
  else
    bad "backup creation failed (POST /backups -> $create)"
  fi

  after=$(curl -s -H "$(auth_header)" "${BASE_URL}/api/v1/instance/${INSTANCE_ID}/backups" \
    | grep -o '"name"' | wc -l | tr -d ' ')
  if [[ "$after" -gt "$before" ]]; then
    ok "backup appears in list (count $before -> $after)"
  else
    bad "backup did not appear in list (count $before -> $after)"
  fi

  # --- 5. Restore (destructive, opt-in) ---
  if [[ "$WITH_RESTORE" -eq 1 ]]; then
    name=$(curl -s -H "$(auth_header)" "${BASE_URL}/api/v1/instance/${INSTANCE_ID}/backups" \
      | grep -o '"name":"[^"]*"' | head -n1 | sed 's/.*:"//;s/"$//')
    if [[ -n "$name" ]]; then
      restore=$(http_status POST "/api/v1/instance/${INSTANCE_ID}/backups/${name}/restore" -H "$(auth_header)")
      if [[ "$restore" == "200" || "$restore" == "204" ]]; then
        ok "restore succeeded (POST /backups/$name/restore -> $restore)"
      else
        bad "restore failed (POST /backups/$name/restore -> $restore)"
      fi
    else
      bad "restore skipped: could not determine a backup name"
    fi
  else
    log "restore step skipped (pass --with-restore to run the destructive restore)"
  fi
fi

log "Result: $pass passed, $fail failed."
[[ "$fail" -eq 0 ]]
