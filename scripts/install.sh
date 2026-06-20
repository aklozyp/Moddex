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

if [[ -z "$MODE" ]]; then
  log "In which mode do you want to operate Moddex?"
  select mode_option in "lan (recommended)" "local (dev only)" "public"; do
    case "$mode_option" in
      "lan (recommended)") MODE="lan"; break ;;
      "local (dev only)") MODE="local"; break ;;
      "public") MODE="public"; break ;;
      *) echo "Invalid option. Please try again." ;;
    esac
  done
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
need_cmd java

log "Ensuring required packages are installed"
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-17-jre-headless rsync >/dev/null
fi

log "Creating moddex user and directories"
if ! id -u moddex >/dev/null 2>&1; then
  useradd -r -M -s /usr/sbin/nologin -d /opt/moddex moddex
fi

install -d -m 0755 -o moddex -g moddex /opt/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/ui
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/logs

log "Deploying backend artifact"
install -m 0644 "$BACKEND_JAR" /opt/moddex/app.jar
chown moddex:moddex /opt/moddex/app.jar

if [[ -n "$FRONTEND_DIR" ]]; then
  log "Deploying frontend assets from $FRONTEND_DIR"
  rsync -a --delete --chown=moddex:moddex "$FRONTEND_DIR/" /var/lib/moddex/ui/
else
  log "Skipping frontend asset deployment (no build directory provided)"
fi

case "$MODE" in
  local)
    SERVER_ADDRESS="127.0.0.1"
    ;;
  lan|public)
    SERVER_ADDRESS="0.0.0.0"
    ;;
esac

SERVICE_FILE=/etc/systemd/system/moddex-backend.service
log "Writing systemd service to $SERVICE_FILE"
install -m 0644 "$SYSTEMD_DIR/moddex-backend.service" "$SERVICE_FILE"
sed -i "s/^Environment=SERVER_ADDRESS=.*/Environment=SERVER_ADDRESS=$SERVER_ADDRESS/" "$SERVICE_FILE"
sed -i "s/^Environment=SERVER_PORT=.*/Environment=SERVER_PORT=$SERVER_PORT/" "$SERVICE_FILE"

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
  local)
    printf 'Backend API reachable at: http://127.0.0.1:%s\n' "$SERVER_PORT"
    ;;
  lan)
    printf 'Backend API reachable at: http://<server-ip>:%s\n' "$SERVER_PORT"
    ;;
  public)
    printf 'Backend API reachable at: http://<public-host>:%s (no TLS configured)\n' "$SERVER_PORT"
    ;;
esac
printf 'Systemd unit: moddex-backend.service\n'
if [[ -n "$FRONTEND_DIR" ]]; then
  printf 'Static frontend copied to /var/lib/moddex/ui (serve separately).\n'
fi
printf 'Complete the first-run setup in the web UI to set an admin password; the API requires authentication afterwards.\n'
printf 'For anything beyond localhost/trusted LAN, put Moddex behind a reverse proxy with TLS. See the "Private Linux Operation" section in the README.\n'

exit 0
