#!/usr/bin/env bash
#
# Moddex release smoke test.
#
# End-to-end check of the critical v0.2 flow against a running backend:
#   reachability -> first-run setup -> auth enforcement -> login ->
#   create instance (downloads the server) -> create backup -> cleanup.
#
# This is the gate described in docs/qa/release-checklist.md. It complements
# scripts/smoke-test.sh (focused backup/restore/mod checks) by also covering the
# setup, login and instance-creation steps a fresh release must survive.
#
# Usage:
#   BASE_URL=http://127.0.0.1:8080 MODDEX_ADMIN_PASSWORD='<pw>' \
#     scripts/release-smoke-test.sh [--skip-instance]
#
# Environment:
#   BASE_URL              Backend base URL (default: http://127.0.0.1:8080)
#   MODDEX_ADMIN_PASSWORD Admin password. On a fresh backend this completes the
#                         setup; on an already-set-up backend it must match the
#                         existing admin password. (default: a generated value,
#                         only useful on a fresh instance.)
#   GAME_VERSION          Minecraft version for the test instance (default: 1.21.1)
#   MOD_LOADER            Loader for the test instance (default: VANILLA)
#
# Flags:
#   --skip-instance   Skip the instance-create + backup + cleanup steps (use when
#                     the runner has no network to download a server JAR).
#   -h, --help        Show this help.
#
# Exit codes (stable):
#   0  all checked steps passed
#   1  one or more checked steps failed
#   2  usage / precondition error
#   5  backend unreachable
#
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ADMIN_PASSWORD="${MODDEX_ADMIN_PASSWORD:-Smoke-$(date +%s)-Aa1}"
GAME_VERSION="${GAME_VERSION:-1.21.1}"
MOD_LOADER="${MOD_LOADER:-VANILLA}"
SKIP_INSTANCE=0

for arg in "$@"; do
  case "$arg" in
    --skip-instance) SKIP_INSTANCE=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

pass=0
fail=0
TOKEN=""

log()  { printf '[release-smoke] %s\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }

# HTTP status only. curl's connect failure is swallowed so the script can report
# "unreachable" itself instead of aborting; 000 means no response.
http_status() {
  local method="$1" path="$2"; shift 2
  curl -s -o /dev/null -w '%{http_code}' -X "$method" "$@" "${BASE_URL}${path}" 2>/dev/null || true
}

# Body + trailing status line.
http_body_status() {
  local method="$1" path="$2"; shift 2
  curl -s -w '\n%{http_code}' -X "$method" "$@" "${BASE_URL}${path}" 2>/dev/null || true
}

json_field() {  # json_field <key>  (reads stdin; first matching string value)
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else
    grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed 's/.*:[[:space:]]*"//;s/"$//'
  fi
}

auth_header() { printf 'Authorization: Bearer %s' "$TOKEN"; }

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }

log "Target: $BASE_URL"

# --- 1. Reachability -------------------------------------------------------
code=$(http_status GET /api/v1/setup/status)
if [[ "$code" != "000" && -n "$code" ]]; then
  ok "backend reachable (/setup/status -> $code)"
else
  bad "backend not reachable (no HTTP response)"
  log "Aborting: backend unreachable."
  exit 5
fi

# --- 2. First-run setup (idempotent) --------------------------------------
status_body=$(http_body_status GET /api/v1/setup/status)
setup_required=$(printf '%s' "${status_body%$'\n'*}" | grep -o '"setupRequired"[^,}]*' | grep -o 'true\|false' | head -n1)
if [[ "$setup_required" == "true" ]]; then
  complete=$(printf '{"password":"%s"}' "$ADMIN_PASSWORD" \
    | http_status POST /api/v1/setup/complete -H 'Content-Type: application/json' --data @-)
  if [[ "$complete" == "200" ]]; then
    ok "first-run setup completed (POST /setup/complete -> 200)"
  else
    bad "first-run setup failed (POST /setup/complete -> $complete)"
  fi
else
  ok "setup already completed (using provided admin password for login)"
fi

# --- 3. Auth enforcement ---------------------------------------------------
anon=$(http_status GET /api/v1/instance)
if [[ "$anon" == "401" || "$anon" == "403" ]]; then
  ok "protected endpoint rejects anonymous access (/instance -> $anon)"
else
  bad "protected endpoint not enforced (/instance -> $anon)"
fi

# --- 4. Login --------------------------------------------------------------
login_out=$(printf '{"password":"%s"}' "$ADMIN_PASSWORD" \
  | http_body_status POST /api/v1/auth/login -H 'Content-Type: application/json' --data @-)
login_code="${login_out##*$'\n'}"
TOKEN=$(printf '%s' "${login_out%$'\n'*}" | json_field token)
if [[ "$login_code" == "200" && -n "$TOKEN" ]]; then
  ok "admin login (POST /auth/login -> 200, token issued)"
else
  bad "admin login failed (POST /auth/login -> $login_code)"
  log "Cannot continue authenticated checks without a token."
  log "Result: $pass passed, $fail failed."
  [[ "$fail" -eq 0 ]] && exit 0 || exit 1
fi

# --- 5. Authenticated instance list ---------------------------------------
authed=$(http_status GET /api/v1/instance -H "$(auth_header)")
if [[ "$authed" == "200" ]]; then
  ok "authenticated instance list (/instance -> 200)"
else
  bad "authenticated instance list failed (/instance -> $authed)"
fi

# --- 6/7/8. Instance lifecycle + backup -----------------------------------
if [[ "$SKIP_INSTANCE" -eq 1 ]]; then
  log "Skipping instance create/backup steps (--skip-instance)."
else
  inst_name="smoke-$(date +%s)"
  create_out=$(printf '{"name":"%s","gameVersion":"%s","modLoader":"%s"}' \
      "$inst_name" "$GAME_VERSION" "$MOD_LOADER" \
    | http_body_status POST /api/v1/instance -H 'Content-Type: application/json' -H "$(auth_header)" --data @-)
  create_code="${create_out##*$'\n'}"
  inst_id=$(printf '%s' "${create_out%$'\n'*}" | json_field id)
  if [[ ( "$create_code" == "200" || "$create_code" == "201" ) && -n "$inst_id" ]]; then
    ok "instance created (POST /instance -> $create_code, id=$inst_id)"
  else
    bad "instance creation failed (POST /instance -> $create_code) — needs network to download the server JAR"
    inst_id=""
  fi

  if [[ -n "$inst_id" ]]; then
    listed=$(http_status GET "/api/v1/instance/${inst_id}" -H "$(auth_header)")
    if [[ "$listed" == "200" ]]; then
      ok "instance retrievable (/instance/$inst_id -> 200)"
    else
      bad "instance not retrievable (/instance/$inst_id -> $listed)"
    fi

    backup=$(http_status POST "/api/v1/instance/${inst_id}/backups?type=full" -H "$(auth_header)")
    if [[ "$backup" == "200" || "$backup" == "201" ]]; then
      ok "backup created (POST /backups?type=full -> $backup)"
    else
      bad "backup creation failed (POST /backups -> $backup)"
    fi

    # Cleanup is best-effort and not counted as a checked step.
    cleanup=$(http_status DELETE "/api/v1/instance/${inst_id}" -H "$(auth_header)")
    log "cleanup: deleted test instance (/instance/$inst_id -> $cleanup)"
  fi
fi

log "Result: $pass passed, $fail failed."
[[ "$fail" -eq 0 ]]
