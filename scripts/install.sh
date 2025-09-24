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

trap 'echo "ERROR: installation aborted." >&2; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEMD_DIR="$PROJECT_ROOT/packaging/systemd"

MODE="local"
DOMAIN=""
EMAIL=""
PASSWORD="${MODDEX_ADMIN_PASSWORD:-}"
BACKEND_JAR=""
FRONTEND_DIR=""

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Options:
  --mode MODE           Installation mode: local, lan, or public (default: local)
  --domain DOMAIN       Public domain (required when --mode public)
  --email EMAIL         ACME contact email (required when --mode public)
  --password PASS       Admin password for HTTP basic auth (defaults to prompt)
  --backend-jar PATH    Path to backend jar (default: ../backend/Moddex-Backend.jar)
  --frontend-dir PATH   Path to built frontend directory (default: ../frontend)
  -h, --help            Show this help message

You can also set MODDEX_ADMIN_PASSWORD to supply the password non-interactively.
USAGE
}

log() { printf '[moddex-install] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || die "Missing value for --mode"
      MODE="$2"
      shift 2
      ;;
    --domain)
      [[ $# -ge 2 ]] || die "Missing value for --domain"
      DOMAIN="$2"
      shift 2
      ;;
    --email)
      [[ $# -ge 2 ]] || die "Missing value for --email"
      EMAIL="$2"
      shift 2
      ;;
    --password)
      [[ $# -ge 2 ]] || die "Missing value for --password"
      PASSWORD="$2"
      shift 2
      ;;
    --backend-jar)
      [[ $# -ge 2 ]] || die "Missing value for --backend-jar"
      BACKEND_JAR="$2"
      shift 2
      ;;
    --frontend-dir)
      [[ $# -ge 2 ]] || die "Missing value for --frontend-dir"
      FRONTEND_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

MODE="${MODE,,}"
case "$MODE" in
  local|lan|public) ;;
  *) die "Invalid --mode value: $MODE (expected local, lan, or public)" ;;
esac

if [[ "$MODE" == "public" ]]; then
  [[ -n "$DOMAIN" && -n "$EMAIL" ]] || die "--domain and --email are required when --mode public"
fi

BACKEND_JAR="${BACKEND_JAR:-$PROJECT_ROOT/backend/Moddex-Backend.jar}"
FRONTEND_DIR="${FRONTEND_DIR:-$PROJECT_ROOT/frontend}"

[[ -f "$BACKEND_JAR" ]] || die "Backend artifact not found at $BACKEND_JAR"
[[ -d "$FRONTEND_DIR" ]] || die "Frontend directory not found at $FRONTEND_DIR"
[[ -f "$SYSTEMD_DIR/moddex-backend.service" ]] || die "Missing unit file: $SYSTEMD_DIR/moddex-backend.service"
[[ -f "$SYSTEMD_DIR/moddex-caddy.service" ]] || die "Missing unit file: $SYSTEMD_DIR/moddex-caddy.service"

if ! command -v apt-get >/dev/null 2>&1; then
  die "Unsupported distribution: expected apt-get to be available"
fi

APT_UPDATED=0
apt_update() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    log "Updating apt package lists"
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    APT_UPDATED=1
  fi
}
apt_install() {
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

log "Installing required packages"
apt_install curl rsync apache2-utils ca-certificates

ensure_caddy_repo() {
  local list_file="/etc/apt/sources.list.d/caddy-stable.list"
  if [[ ! -f "$list_file" ]]; then
    log "Configuring the official Caddy repository"
    apt_install debian-keyring debian-archive-keyring apt-transport-https gnupg
    install -d /usr/share/keyrings /etc/apt/sources.list.d
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$list_file"
    APT_UPDATED=0
  fi
}

ensure_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    return
  fi
  ensure_caddy_repo
  apt_install caddy
}

ensure_caddy

need_cmd rsync
need_cmd htpasswd
need_cmd systemctl
need_cmd install
need_cmd id

log "Creating moddex user and directories"
if ! id -u moddex >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin moddex
fi

install -d -m 0755 -o moddex -g moddex /opt/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/ui
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/logs
install -d -m 0750 -o moddex -g moddex /etc/moddex

log "Deploying application artifacts"
# Record version if the bundle provides it
if [[ -f "$PROJECT_ROOT/VERSION" ]]; then
  install -m 0644 "$PROJECT_ROOT/VERSION" /opt/moddex/VERSION
  chown moddex:moddex /opt/moddex/VERSION
fi

install -m 0644 "$BACKEND_JAR" /opt/moddex/app.jar
chown moddex:moddex /opt/moddex/app.jar
rsync -a --delete "${FRONTEND_DIR}/" /var/lib/moddex/ui/
chown -R moddex:moddex /var/lib/moddex/ui

create_if_missing() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    install -m 0640 -o moddex -g moddex /dev/null "$path"
  fi
}

log "Preparing configuration"
create_if_missing /etc/moddex/serversettings.json
create_if_missing /etc/moddex/clientsettings.json

if [[ -z "$PASSWORD" ]]; then
  read -r -s -p "Admin password (will be stored as bcrypt hash): " PASSWORD
  echo
fi
[[ -n "$PASSWORD" ]] || die "Admin password cannot be empty"

htpasswd -cbB /etc/moddex/htpasswd admin "$PASSWORD" >/dev/null
HTPASS_ADMIN_HASH="$(htpasswd -nbB admin "$PASSWORD" | cut -d':' -f2-)"

log "Generating Caddyfile"
{
    if [[ "$MODE" == "public" ]]; then
        echo "$DOMAIN {"
        echo "  email $EMAIL"
    else
        echo ":8443 {"
        echo "  local_certs"
    fi

    echo "    encode zstd gzip"
    echo "    basic_auth /* {"
    printf '        admin %s\n' "$HTPASS_ADMIN_HASH"
    echo "    }"
    echo "    handle_path / {"
    echo "        root * /var/lib/moddex/ui"
    echo "        file_server"
    echo "    }"
    echo "    handle /api/* {"
    echo "        rewrite * /{path}"
    echo "        reverse_proxy 127.0.0.1:8080"
    echo "    }"

    if [[ "$MODE" == "public" ]]; then
        echo '    header { Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" }'
    fi

    echo "    log { output file /var/lib/moddex/logs/access.log }"
    echo "}"
} > /etc/moddex/Caddyfile

chmod 0644 /etc/moddex/Caddyfile

log "Installing systemd units"
install -m 0644 "$SYSTEMD_DIR/moddex-backend.service" /etc/systemd/system/moddex-backend.service
install -m 0644 "$SYSTEMD_DIR/moddex-caddy.service" /etc/systemd/system/moddex-caddy.service
systemctl daemon-reload
systemctl enable --now moddex-backend moddex-caddy

trap - ERR

log "Installation complete"
case "$MODE" in
  local)
    printf 'Visit https://127.0.0.1:8443\n'
    ;;
  lan)
    printf 'Visit https://<server-ip>:8443\n'
    ;;
  public)
    printf 'Visit https://%s\n' "$DOMAIN"
    ;;
esac

printf 'Admin user: admin (password as provided above)\n'
