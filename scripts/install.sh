#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if [[ -z "${MODDEX_INSTALL_REEXEC:-}" ]] && command -v sudo >/dev/null 2>&1; then
    export MODDEX_INSTALL_REEXEC=1
    exec sudo -E "$0" "$@"
  fi
  echo "This installer must run with root privileges." >&2
  exit 1
fi
unset MODDEX_INSTALL_REEXEC

on_error() {
  local exit_code="$1" line="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    printf '[ERROR] Installation aborted (exit %s at line %s)\n' "$exit_code" "$line" >&2
  fi
}
trap 'on_error $? $LINENO' ERR

umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEMD_DIR="$PROJECT_ROOT/packaging/systemd"

# Filesystem layout (FHS-aligned). The backend reads these via MODDEX_* env vars
# (see application.yml), so the installer, systemd unit and CLI all agree.
APP_DIR=/opt/moddex
UI_DIR=/opt/moddex/ui
DATA_DIR=/var/lib/moddex
CONFIG_DIR=/etc/moddex
LOG_DIR=/var/log/moddex
ENV_FILE="$CONFIG_DIR/moddex.env"
CLI_PATH=/usr/local/bin/moddex
MIN_JAVA_VERSION=17

MODE="${MODE:-${MODDEX_MODE:-}}"
BACKEND_JAR="${BACKEND_JAR:-${MODDEX_BACKEND_JAR:-}}"
FRONTEND_DIR="${FRONTEND_DIR:-${MODDEX_FRONTEND_DIR:-}}"
WITHOUT_FRONTEND=0

# Track whether mode/port were given explicitly (env var or CLI flag) vs left at
# their default. On a re-install we only rewrite an existing moddex.env when the
# operator actually supplied an override, so unattended upgrades stay
# non-destructive but an explicit `--mode/--port` re-run still takes effect.
MODE_EXPLICIT=0
[[ -n "$MODE" ]] && MODE_EXPLICIT=1
PORT_INPUT="${PORT:-${MODDEX_PORT:-}}"
PORT_EXPLICIT=0
[[ -n "$PORT_INPUT" ]] && PORT_EXPLICIT=1
SERVER_PORT="${PORT_INPUT:-8080}"

log() { printf '[moddex-install] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Options:
  --mode MODE           Deployment mode: local, lan, public
  --backend-jar PATH    Path to the backend JAR to install
  --frontend-dir PATH   Path to the directory with built frontend assets
                        (the one containing index.html)
  --without-frontend    Install the backend only, without a web UI. Without this
                        flag a bundle that carries no usable UI is rejected.
  --port NUMBER         TCP port to expose the backend on (default: 8080)
  -h, --help            Show this help and exit

Environment overrides:
  MODDEX_MODE, MODDEX_BACKEND_JAR, MODDEX_FRONTEND_DIR, MODDEX_PORT

The installer is idempotent: re-running it upgrades the application artifacts
without touching local configuration in /etc/moddex/moddex.env or instance data
in /var/lib/moddex.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) [[ $# -ge 2 ]] || die "Missing value for --mode"; MODE="$2"; MODE_EXPLICIT=1; shift 2 ;;
    --backend-jar) [[ $# -ge 2 ]] || die "Missing value for --backend-jar"; BACKEND_JAR="$2"; shift 2 ;;
    --frontend-dir) [[ $# -ge 2 ]] || die "Missing value for --frontend-dir"; FRONTEND_DIR="$2"; shift 2 ;;
    --without-frontend) WITHOUT_FRONTEND=1; shift ;;
    --port) [[ $# -ge 2 ]] || die "Missing value for --port"; SERVER_PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# An existing config file marks an upgrade. We keep the operator's mode/port from
# the previous install unless they are overridden on the command line, so updates
# stay non-destructive.
CONFIG_EXISTS=0
EXISTING_MODE=""
if [[ -f "$ENV_FILE" ]]; then
  CONFIG_EXISTS=1
  # shellcheck disable=SC1090
  EXISTING_MODE="$(. "$ENV_FILE" 2>/dev/null; printf '%s' "${MODDEX_MODE:-}")"
fi

if [[ -z "$MODE" && -n "$EXISTING_MODE" ]]; then
  MODE="$EXISTING_MODE"
  log "Reusing existing deployment mode from $ENV_FILE: $MODE"
fi

# Legacy migration: installs from the previous installer have no moddex.env but a
# systemd unit carrying SERVER_ADDRESS/SERVER_PORT. Recover them so unattended
# upgrades (update.sh/download.sh, which call install.sh without --mode) keep
# working instead of failing the non-interactive guard below.
LEGACY_SERVICE_FILE=/etc/systemd/system/moddex-backend.service
if [[ -z "$MODE" && "$CONFIG_EXISTS" -eq 0 && -f "$LEGACY_SERVICE_FILE" ]]; then
  legacy_addr="$(sed -n 's/^Environment=SERVER_ADDRESS=//p' "$LEGACY_SERVICE_FILE" | tail -n1 | tr -d '\r')"
  legacy_port="$(sed -n 's/^Environment=SERVER_PORT=//p' "$LEGACY_SERVICE_FILE" | tail -n1 | tr -d '\r')"
  if [[ -n "$legacy_addr" ]]; then
    case "$legacy_addr" in
      127.0.0.1|localhost|::1) MODE="local" ;;
      *) MODE="lan" ;;   # 0.0.0.0 etc.: lan is the safe non-public default
    esac
    # Keep the previous port unless the operator overrode it explicitly.
    [[ "$PORT_EXPLICIT" -eq 1 || -z "$legacy_port" ]] || SERVER_PORT="$legacy_port"
    log "Migrating configuration from existing systemd unit (mode=$MODE, port=$SERVER_PORT)"
  fi
fi

if [[ -z "$MODE" ]]; then
  if [[ -t 0 ]]; then
    log "In which mode do you want to operate Moddex?"
    select mode_option in "lan (recommended)" "local (dev only)" "public"; do
      case "$mode_option" in
        "lan (recommended)") MODE="lan"; break ;;
        "local (dev only)") MODE="local"; break ;;
        "public") MODE="public"; break ;;
        *) echo "Invalid option. Please try again." ;;
      esac
    done
  else
    die "No --mode given and not running interactively. Pass --mode local|lan|public."
  fi
fi

MODE="${MODE,,}"
case "$MODE" in
  local|lan|public) ;;
  *) die "Invalid --mode value: $MODE (expected local, lan, or public)" ;;
esac

# Public mode serves plain HTTP unless the operator sets up TLS (reverse proxy
# or the backend's native MODDEX_TLS_*): warn loudly and, when a human newly
# chooses public interactively, require confirmation (Moddex-Backend#50).
# Unattended runs (upgrades inheriting mode, explicit --mode in scripts) only
# warn, so automation keeps working.
if [[ "$MODE" == "public" ]]; then
  log "WARNING: --mode public serves the admin login and ALL API traffic over plain HTTP."
  log "         Passwords and session tokens are readable on the network until you either"
  log "         terminate TLS in a reverse proxy (see the README; then set MODDEX_TLS_TERMINATED=true)"
  log "         or enable native HTTPS via MODDEX_TLS_ENABLED/MODDEX_TLS_CERT/MODDEX_TLS_KEY."
  if [[ -t 0 && "$EXISTING_MODE" != "public" ]]; then
    read -r -p "Continue with public mode over plain HTTP? [y/N] " tls_answer
    case "${tls_answer,,}" in
      y|yes) ;;
      *) die "Aborted. Re-run with --mode lan/local, or set up TLS first (see README)." ;;
    esac
  fi
fi

if [[ -z "$BACKEND_JAR" ]]; then
  DEFAULT_JAR="$PROJECT_ROOT/backend/Moddex-Backend.jar"
  [[ -f "$DEFAULT_JAR" ]] || die "Backend JAR not found. Provide --backend-jar."
  BACKEND_JAR="$DEFAULT_JAR"
fi

# A bundle without a usable frontend installs a product with no user interface.
# That used to pass silently: the default path was probed, found wanting, and
# the deployment step was skipped with an informational line the operator was
# unlikely to read (Moddex#61). A missing UI is now fatal unless the operator
# explicitly asks for a backend-only install.
# --without-frontend is an explicit operator decision and outranks everything
# else, including a perfectly good UI sitting in the bundle. Checking it only
# after auto-detection would silently deploy the UI the operator just declined.
if [[ "$WITHOUT_FRONTEND" -eq 1 ]]; then
  [[ -z "$FRONTEND_DIR" ]] || die "--without-frontend and --frontend-dir are mutually exclusive."
  log "Installing without a web UI (--without-frontend)"
elif [[ -z "$FRONTEND_DIR" ]]; then
  DEFAULT_FRONTEND="$PROJECT_ROOT/frontend"
  if [[ -f "$DEFAULT_FRONTEND/index.html" ]]; then
    FRONTEND_DIR="$DEFAULT_FRONTEND"
  elif [[ -d "$DEFAULT_FRONTEND" ]]; then
    die "No index.html in $DEFAULT_FRONTEND. The bundle carries no usable web UI.
Rebuild it with scripts/build-bundle.sh, pass --frontend-dir PATH, or install
without a UI using --without-frontend."
  else
    die "No frontend assets found at $DEFAULT_FRONTEND.
Pass --frontend-dir PATH, or install without a UI using --without-frontend."
  fi
fi

if [[ -n "$FRONTEND_DIR" ]]; then
  [[ -d "$FRONTEND_DIR" ]] || die "Frontend directory does not exist: $FRONTEND_DIR"
  [[ -f "$FRONTEND_DIR/index.html" ]] || \
    die "Frontend directory has no index.html: $FRONTEND_DIR
This is not a built Angular app. Point --frontend-dir at the browser output
(the directory containing index.html), not at the dist/ root."
fi

need_cmd install
need_cmd rsync
need_cmd systemctl

log "Ensuring required packages are installed"
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-17-jre-headless rsync >/dev/null
fi

# Verify a usable Java runtime is present (after the optional apt install above).
need_cmd java
java_major() {
  # Parses "17.0.10", "1.8.0_392" etc. from `java -version` into a major number.
  local raw
  raw="$(java -version 2>&1 | head -n1 | sed -E 's/.*version "([0-9._]+)".*/\1/')"
  if [[ "$raw" == 1.* ]]; then
    printf '%s' "${raw#1.}" | cut -d. -f1
  else
    printf '%s' "$raw" | cut -d. -f1
  fi
}
JAVA_MAJOR="$(java_major)"
if [[ -z "$JAVA_MAJOR" || ! "$JAVA_MAJOR" =~ ^[0-9]+$ ]]; then
  die "Could not determine the installed Java version. Install OpenJDK $MIN_JAVA_VERSION or newer."
fi
if (( JAVA_MAJOR < MIN_JAVA_VERSION )); then
  die "Java $MIN_JAVA_VERSION or newer is required (found major version $JAVA_MAJOR)."
fi
log "Using Java major version $JAVA_MAJOR"

log "Creating moddex user and directories"
if ! id -u moddex >/dev/null 2>&1; then
  useradd -r -M -s /usr/sbin/nologin -d "$APP_DIR" moddex
fi

install -d -m 0755 -o moddex -g moddex "$APP_DIR"
install -d -m 0755 -o moddex -g moddex "$DATA_DIR"
install -d -m 0755 -o moddex -g moddex "$LOG_DIR"
# The web UI belongs to the application, not to the instance data: it is
# replaced wholesale on every upgrade and the service must never be able to
# rewrite what browsers are served. Hence root-owned under /opt and only
# readable by the service (Moddex#59).
install -d -m 0755 -o root -g root "$UI_DIR"
# Config is root-owned but group-readable by the service so secrets in moddex.env
# are not world-readable.
install -d -m 0750 -o root -g moddex "$CONFIG_DIR"

# One-time migration: older installs logged to /var/lib/moddex/logs.
if [[ -d "$DATA_DIR/logs" && ! -e "$LOG_DIR/backend.out.log" ]]; then
  log "Migrating existing logs from $DATA_DIR/logs to $LOG_DIR"
  cp -a "$DATA_DIR/logs/." "$LOG_DIR/" 2>/dev/null || true
  chown -R moddex:moddex "$LOG_DIR"
fi

log "Deploying backend artifact"
install -m 0644 "$BACKEND_JAR" "$APP_DIR/app.jar"
chown moddex:moddex "$APP_DIR/app.jar"

# Record the installed version so update.sh can compare against the latest tag.
VERSION_STRING="${VERSION:-}"
if [[ -z "$VERSION_STRING" && -f "$PROJECT_ROOT/VERSION" ]]; then
  VERSION_STRING="$(sed -n '1p' "$PROJECT_ROOT/VERSION" | tr -d '\r\n')"
fi
[[ -n "$VERSION_STRING" ]] || VERSION_STRING="dev"
printf '%s\n' "$VERSION_STRING" > "$APP_DIR/VERSION"
chown moddex:moddex "$APP_DIR/VERSION"
log "Installed version: $VERSION_STRING"

if [[ -n "$FRONTEND_DIR" ]]; then
  log "Deploying frontend assets to $UI_DIR"
  rsync -a --delete --chown=root:root "$FRONTEND_DIR/" "$UI_DIR/"
  find "$UI_DIR" -type d -exec chmod 0755 {} +
  find "$UI_DIR" -type f -exec chmod 0644 {} +
elif [[ -n "$(ls -A "$UI_DIR" 2>/dev/null)" ]]; then
  # A backend-only re-install over an existing installation must not leave the
  # previous UI in place: the backend would keep serving an old frontend against
  # a newer API.
  log "Removing the previously installed web UI from $UI_DIR (--without-frontend)"
  find "$UI_DIR" -mindepth 1 -delete
fi

# One-time migration: earlier installs put the UI in the instance data
# directory, where nothing served it and the service could write to it.
if [[ -d "$DATA_DIR/ui" ]]; then
  log "Removing the obsolete UI directory at $DATA_DIR/ui (now served from $UI_DIR)"
  rm -rf "$DATA_DIR/ui"
fi

case "$MODE" in
  local) SERVER_ADDRESS="127.0.0.1" ;;
  lan|public) SERVER_ADDRESS="0.0.0.0" ;;
esac

# Machine-local runtime configuration. On a fresh install it is written once. On
# a re-install it is only rewritten when the operator passes an explicit
# --mode/--port (or MODDEX_MODE/MODDEX_PORT); otherwise it is preserved so plain
# upgrades never disturb operator settings.
write_env_file() {
  umask 027
  cat > "$ENV_FILE" <<EOF
# Moddex machine-local configuration. Managed by the operator.
# The installer rewrites this file only when --mode/--port (or MODDEX_MODE/
# MODDEX_PORT) are given explicitly; plain upgrades leave it untouched.
MODDEX_MODE=$MODE
# Drives the backend's CORS/security policy (moddex.security.mode); must match
# MODDEX_MODE so a lan/public install does not run with the local default.
MODDEX_SECURITY_MODE=$MODE
MODDEX_ROOT=$DATA_DIR
MODDEX_CONFIG_DIR=$CONFIG_DIR
MODDEX_LOG_DIR=$LOG_DIR
MODDEX_UI_DIR=$UI_DIR
SERVER_ADDRESS=$SERVER_ADDRESS
SERVER_PORT=$SERVER_PORT
# Transport security (Moddex-Backend#50). Behind a TLS-terminating reverse
# proxy declare it; without a proxy enable native HTTPS with a PEM cert/key.
#MODDEX_TLS_TERMINATED=true
#MODDEX_TLS_ENABLED=true
#MODDEX_TLS_CERT=/etc/letsencrypt/live/example.com/fullchain.pem
#MODDEX_TLS_KEY=/etc/letsencrypt/live/example.com/privkey.pem
EOF
  umask 022
  chown root:moddex "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
}

# Update (or append) a single KEY=value line in $ENV_FILE in place, leaving every
# other line untouched. Used when an operator changes only --mode/--port so any
# custom keys they added (e.g. MODDEX_CORS_ALLOWED_ORIGINS) are preserved.
upsert_env_key() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  awk -v k="$key" -v v="$value" '
    index($0, k"=") == 1 { print k"="v; done=1; next }
    { print }
    END { if (!done) print k"="v }
  ' "$ENV_FILE" > "$tmp"
  chown root:moddex "$tmp" 2>/dev/null || true
  chmod 0640 "$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

if [[ "$CONFIG_EXISTS" -eq 1 ]]; then
  # Baseline values from the existing file.
  # shellcheck disable=SC1090
  EXISTING_PORT="$(. "$ENV_FILE" 2>/dev/null; printf '%s' "${SERVER_PORT:-}")"
  # shellcheck disable=SC1090
  EXISTING_ADDR="$(. "$ENV_FILE" 2>/dev/null; printf '%s' "${SERVER_ADDRESS:-}")"

  if [[ "$MODE_EXPLICIT" -eq 1 || "$PORT_EXPLICIT" -eq 1 ]]; then
    # Honor explicit overrides; keep non-overridden values from the existing file.
    [[ "$PORT_EXPLICIT" -eq 1 || -z "$EXISTING_PORT" ]] || SERVER_PORT="$EXISTING_PORT"
    # SERVER_ADDRESS was derived from MODE above. If the mode was not overridden,
    # keep the operator's existing bind address rather than recomputing it.
    [[ "$MODE_EXPLICIT" -eq 1 || -z "$EXISTING_ADDR" ]] || SERVER_ADDRESS="$EXISTING_ADDR"
    log "Updating configuration at $ENV_FILE (explicit --mode/--port given)"
    # Touch only the managed connection keys; preserve any operator-added lines.
    upsert_env_key MODDEX_MODE "$MODE"
    upsert_env_key MODDEX_SECURITY_MODE "$MODE"
    upsert_env_key SERVER_ADDRESS "$SERVER_ADDRESS"
    upsert_env_key SERVER_PORT "$SERVER_PORT"
  else
    log "Preserving existing configuration at $ENV_FILE (pass --mode/--port to change it)"
    [[ -n "$EXISTING_PORT" ]] && SERVER_PORT="$EXISTING_PORT"
    [[ -n "$EXISTING_ADDR" ]] && SERVER_ADDRESS="$EXISTING_ADDR"
  fi
else
  log "Writing configuration to $ENV_FILE"
  write_env_file
fi

SERVICE_FILE=/etc/systemd/system/moddex-backend.service
log "Writing systemd service to $SERVICE_FILE"
install -m 0644 "$SYSTEMD_DIR/moddex-backend.service" "$SERVICE_FILE"

# Install the administrative CLI into PATH (idempotent overwrite).
if [[ -f "$SCRIPT_DIR/moddex" ]]; then
  log "Installing CLI to $CLI_PATH"
  install -m 0755 "$SCRIPT_DIR/moddex" "$CLI_PATH"
else
  log "CLI script not found next to installer; skipping CLI installation"
fi

log "Reloading systemd and starting backend"
systemctl daemon-reload
systemctl enable moddex-backend.service
# `enable --now` starts a stopped unit but does not restart a running one, so an
# upgrade would leave the old JVM serving the old JAR and the old environment.
# That is bad enough on its own; combined with the UI migration above it is
# worse, because the previous UI directory is already gone while the running
# process does not know about the new one. An explicit restart is the only thing
# that makes an upgrade take effect. (Staging, readiness and rollback around
# this are tracked in #62.)
systemctl restart moddex-backend.service

if [[ "$MODE" != "local" ]]; then
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$SERVER_PORT"/tcp || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$SERVER_PORT"/tcp || true
    firewall-cmd --reload || true
  else
    log "Firewall not detected. Ensure TCP $SERVER_PORT is reachable if needed."
  fi
fi

log "Installation complete"
# The backend serves the web UI on the same port as the API (Moddex#59), so
# there is one address to hand the operator, not two.
case "$MODE" in
  local) printf 'Web UI and API: http://127.0.0.1:%s\n' "$SERVER_PORT" ;;
  lan)   printf 'Web UI and API: http://<server-ip>:%s\n' "$SERVER_PORT" ;;
  public) printf 'Web UI and API: http://<public-host>:%s (no TLS configured)\n' "$SERVER_PORT" ;;
esac
printf 'Systemd unit: moddex-backend.service\n'
printf 'Configuration: %s\n' "$ENV_FILE"
printf 'Logs: %s\n' "$LOG_DIR"
if command -v moddex >/dev/null 2>&1 || [[ -x "$CLI_PATH" ]]; then
  printf 'CLI installed: run "moddex status" or "moddex help".\n'
fi
if [[ -n "$FRONTEND_DIR" ]]; then
  printf 'Web UI served from: %s (no separate web server needed)\n' "$UI_DIR"
else
  printf 'Installed without a web UI (--without-frontend); the API is available, the browser interface is not.\n'
fi
printf 'Complete the first-run setup in the web UI to set an admin password. Then verify a protected endpoint returns 401 without a token, e.g.:\n'
printf '  curl -i http://127.0.0.1:%s/api/v1/instance\n' "$SERVER_PORT"
printf 'Do not rely on app auth alone: restrict access via firewall/router and put Moddex behind a reverse proxy with TLS beyond localhost/trusted LAN. See "Private Linux Operation" in the README.\n'

exit 0
