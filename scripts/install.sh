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
DATA_DIR=/var/lib/moddex
CONFIG_DIR=/etc/moddex
LOG_DIR=/var/log/moddex
ENV_FILE="$CONFIG_DIR/moddex.env"
CLI_PATH=/usr/local/bin/moddex
MIN_JAVA_VERSION=17

MODE="${MODE:-${MODDEX_MODE:-}}"
BACKEND_JAR="${BACKEND_JAR:-${MODDEX_BACKEND_JAR:-}}"
FRONTEND_DIR="${FRONTEND_DIR:-${MODDEX_FRONTEND_DIR:-}}"
SERVER_PORT="${PORT:-${MODDEX_PORT:-8080}}"

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
    --mode) [[ $# -ge 2 ]] || die "Missing value for --mode"; MODE="$2"; shift 2 ;;
    --backend-jar) [[ $# -ge 2 ]] || die "Missing value for --backend-jar"; BACKEND_JAR="$2"; shift 2 ;;
    --frontend-dir) [[ $# -ge 2 ]] || die "Missing value for --frontend-dir"; FRONTEND_DIR="$2"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || die "Missing value for --port"; SERVER_PORT="$2"; shift 2 ;;
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

if [[ -z "$BACKEND_JAR" ]]; then
  DEFAULT_JAR="$PROJECT_ROOT/backend/Moddex-Backend.jar"
  [[ -f "$DEFAULT_JAR" ]] || die "Backend JAR not found. Provide --backend-jar."
  BACKEND_JAR="$DEFAULT_JAR"
fi

if [[ -z "$FRONTEND_DIR" ]]; then
  DEFAULT_FRONTEND="$PROJECT_ROOT/frontend"
  if [[ -d "$DEFAULT_FRONTEND" && -f "$DEFAULT_FRONTEND/index.html" ]]; then
    FRONTEND_DIR="$DEFAULT_FRONTEND"
  else
    FRONTEND_DIR=""
  fi
fi

if [[ -n "$FRONTEND_DIR" ]]; then
  [[ -d "$FRONTEND_DIR" && -f "$FRONTEND_DIR/index.html" ]] || die "Frontend directory invalid. Use --frontend-dir."
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
install -d -m 0755 -o moddex -g moddex "$DATA_DIR/ui"
install -d -m 0755 -o moddex -g moddex "$LOG_DIR"
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
  log "Deploying frontend assets from $FRONTEND_DIR"
  rsync -a --delete --chown=moddex:moddex "$FRONTEND_DIR/" "$DATA_DIR/ui/"
else
  log "Skipping frontend asset deployment (no build directory provided)"
fi

case "$MODE" in
  local) SERVER_ADDRESS="127.0.0.1" ;;
  lan|public) SERVER_ADDRESS="0.0.0.0" ;;
esac

# Machine-local runtime configuration. Written once; left untouched on upgrades
# so operator settings survive. To change mode/port later, edit this file (or
# re-run with --mode/--port) and restart the service.
if [[ "$CONFIG_EXISTS" -eq 1 ]]; then
  log "Preserving existing configuration at $ENV_FILE (edit it to change mode/port)"
  # shellcheck disable=SC1090
  SERVER_PORT="$(. "$ENV_FILE" 2>/dev/null; printf '%s' "${SERVER_PORT:-$SERVER_PORT}")"
else
  log "Writing configuration to $ENV_FILE"
  umask 027
  cat > "$ENV_FILE" <<EOF
# Moddex machine-local configuration. Managed by the operator.
# The installer does NOT overwrite this file on upgrades.
MODDEX_MODE=$MODE
MODDEX_ROOT=$DATA_DIR
MODDEX_CONFIG_DIR=$CONFIG_DIR
MODDEX_LOG_DIR=$LOG_DIR
SERVER_ADDRESS=$SERVER_ADDRESS
SERVER_PORT=$SERVER_PORT
EOF
  umask 022
  chown root:moddex "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
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
systemctl enable --now moddex-backend.service

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
case "$MODE" in
  local) printf 'Backend API reachable at: http://127.0.0.1:%s\n' "$SERVER_PORT" ;;
  lan)   printf 'Backend API reachable at: http://<server-ip>:%s\n' "$SERVER_PORT" ;;
  public) printf 'Backend API reachable at: http://<public-host>:%s (no TLS configured)\n' "$SERVER_PORT" ;;
esac
printf 'Systemd unit: moddex-backend.service\n'
printf 'Configuration: %s\n' "$ENV_FILE"
printf 'Logs: %s\n' "$LOG_DIR"
if command -v moddex >/dev/null 2>&1 || [[ -x "$CLI_PATH" ]]; then
  printf 'CLI installed: run "moddex status" or "moddex help".\n'
fi
if [[ -n "$FRONTEND_DIR" ]]; then
  printf 'Static frontend copied to %s/ui (serve separately).\n' "$DATA_DIR"
fi
printf 'Complete the first-run setup in the web UI to set an admin password. Then verify a protected endpoint returns 401 without a token, e.g.:\n'
printf '  curl -i http://127.0.0.1:%s/api/v1/instance\n' "$SERVER_PORT"
printf 'Do not rely on app auth alone: restrict access via firewall/router and put Moddex behind a reverse proxy with TLS beyond localhost/trusted LAN. See "Private Linux Operation" in the README.\n'

exit 0
