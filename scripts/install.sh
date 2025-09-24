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

MODE="${MODE:-${MODDEX_MODE:-local}}"
DOMAIN="${DOMAIN:-${MODDEX_DOMAIN:-}}"
EMAIL="${EMAIL:-${MODDEX_ACME_EMAIL:-}}"
BACKEND_JAR="${BACKEND_JAR:-${MODDEX_BACKEND_JAR:-}}"
FRONTEND_DIR="${FRONTEND_DIR:-${MODDEX_FRONTEND_DIR:-$PROJECT_ROOT/frontend}}"
FRONTEND_BUILD_ROOT=""
usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Options:
  --mode MODE           Deployment mode: local, lan, public (default: local)
  --domain DOMAIN       Public domain name (required for --mode public)
  --email EMAIL         ACME contact email (required for --mode public)
  --backend-jar PATH    Backend JAR to install (default: bundle backend artifact)
  --frontend-dir PATH   Directory containing built frontend assets (default: bundle frontend)
  -h, --help            Show this help and exit

Environment overrides:
  MODDEX_MODE, MODDEX_DOMAIN, MODDEX_ACME_EMAIL,
  MODDEX_BACKEND_JAR, MODDEX_FRONTEND_DIR
USAGE
}

log() { printf '[moddex-install] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
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
  [[ -n "$DOMAIN" ]] || die "--domain is required when --mode public"
  [[ -n "$EMAIL" ]] || die "--email is required when --mode public"
fi
resolve_backend_artifact() {
  if [[ -n "$BACKEND_JAR" ]]; then
    [[ -f "$BACKEND_JAR" ]] || die "Backend artifact not found at $BACKEND_JAR"
    return
  fi
  local default="$PROJECT_ROOT/backend/Moddex-Backend.jar"
  if [[ -f "$default" ]]; then
    BACKEND_JAR="$default"
    return
  fi
  mapfile -t jars < <(find "$PROJECT_ROOT/backend" -maxdepth 2 -type f -name '*.jar' | sort)
  [[ ${#jars[@]} -gt 0 ]] || die "Unable to locate backend JAR under $PROJECT_ROOT/backend"
  BACKEND_JAR="${jars[0]}"
}

resolve_frontend_assets() {
  local search_root="$FRONTEND_DIR"
  [[ -d "$search_root" ]] || die "Frontend directory not found at $search_root"

  if [[ -f "$search_root/index.html" ]]; then
    FRONTEND_BUILD_ROOT="$search_root"
    return
  fi

  mapfile -t index_candidates < <(find "$search_root" -maxdepth 4 -type f -name index.html | sort)
  for candidate in "${index_candidates[@]}"; do
    case "$candidate" in
      *dist/*|*build/*|*browser/*)
        FRONTEND_BUILD_ROOT="$(dirname "$candidate")"
        return
        ;;
    esac
  done

  if [[ ${#index_candidates[@]} -gt 0 ]]; then
    FRONTEND_BUILD_ROOT="$(dirname "${index_candidates[0]}")"
    log "Warning: using frontend assets from $FRONTEND_BUILD_ROOT"
  else
    die "Unable to locate built frontend (index.html) beneath $search_root"
  fi
}

resolve_backend_artifact
resolve_frontend_assets

need_cmd install
need_cmd rsync
need_cmd systemctl
need_cmd awk
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

ensure_package() {
  local pkg="$1"
  dpkg -s "$pkg" >/dev/null 2>&1 || apt_install "$pkg"
}

ensure_caddy_repo() {
  local key_file=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
  local list_file=/etc/apt/sources.list.d/caddy-stable.list

  if [[ ! -f "$key_file" ]]; then
    log "Importing Caddy repository signing key"
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor > /tmp/caddy.gpg
    install -m 0644 /tmp/caddy.gpg "$key_file"
    rm -f /tmp/caddy.gpg
  fi

  if [[ ! -f "$list_file" ]] || ! grep -q 'dl.cloudsmith.io/public/caddy/stable' "$list_file"; then
    log "Configuring Caddy apt repository"
    cat > "$list_file" <<__CADDY__
deb [signed-by=$key_file] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
__CADDY__
    APT_UPDATED=0
  fi
}

log "Installing runtime dependencies"
ensure_package ca-certificates
ensure_package curl
ensure_package gnupg
ensure_package rsync
ensure_package openjdk-17-jre-headless
ensure_caddy_repo
ensure_package caddy

need_cmd java
need_cmd caddy
need_cmd gpg
log "Creating moddex user and directories"
if ! id -u moddex >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin moddex
fi

install -d -m 0755 -o moddex -g moddex /opt/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/ui
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/logs
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/caddy
install -d -m 0750 -o moddex -g moddex /etc/moddex

log "Deploying backend artifact"
install -m 0644 "$BACKEND_JAR" /opt/moddex/app.jar
chown moddex:moddex /opt/moddex/app.jar

if [[ -f "$PROJECT_ROOT/VERSION" ]]; then
  install -m 0644 "$PROJECT_ROOT/VERSION" /opt/moddex/VERSION
  chown moddex:moddex /opt/moddex/VERSION
fi

log "Deploying frontend assets from $FRONTEND_BUILD_ROOT"
rsync -a --delete "$FRONTEND_BUILD_ROOT/" /var/lib/moddex/ui/
chown -R moddex:moddex /var/lib/moddex/ui

create_if_missing() {
  local path="$1" perms="$2"
  if [[ ! -f "$path" ]]; then
    install -m "$perms" -o moddex -g moddex /dev/null "$path"
  fi
}

create_if_missing /etc/moddex/serversettings.json 0640
create_if_missing /etc/moddex/clientsettings.json 0640
render_caddyfile() {
  local listen
  case "$MODE" in
    local)
      listen="127.0.0.1:8443"
      ;;
    lan)
      listen=":8443"
      ;;
    public)
      listen="$DOMAIN"
      ;;
  esac

  printf '%s {\n' "$listen"
  if [[ "$MODE" == "public" ]]; then
    printf '  tls {\n    issuer acme\n    email %s\n  }\n' "$EMAIL"
  else
    printf '  tls internal\n'
  fi
  printf '  encode zstd gzip\n'
  printf '  header {\n'
  printf '    X-Content-Type-Options nosniff\n'
  printf '    X-Frame-Options DENY\n'
  printf '    Referrer-Policy no-referrer\n'
  printf '    Permissions-Policy "geolocation=()"\n'
  if [[ "$MODE" == "public" ]]; then
    printf '    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"\n'
  fi
  printf '  }\n\n'
  printf '  @api path /api/*\n'
  printf '  handle @api {\n'
  printf '    reverse_proxy 127.0.0.1:8080\n'
  printf '  }\n\n'
  printf '  handle {\n'
  printf '    root * /var/lib/moddex/ui\n'
  printf '    try_files {path} /index.html\n'
  printf '    file_server\n'
  printf '  }\n\n'
  printf '  log {\n'
  printf '    format json\n'
  printf '    output file /var/lib/moddex/logs/access.log\n'
  printf '  }\n'
  printf '}\n'
}

log "Generating Caddy configuration"
render_caddyfile > /etc/moddex/Caddyfile.tmp
install -m 0640 /etc/moddex/Caddyfile.tmp /etc/moddex/Caddyfile
rm -f /etc/moddex/Caddyfile.tmp
chown root:moddex /etc/moddex/Caddyfile
log "Installing systemd units"
install -m 0644 "$SYSTEMD_DIR/moddex-backend.service" /etc/systemd/system/moddex-backend.service
install -m 0644 "$SYSTEMD_DIR/moddex-caddy.service" /etc/systemd/system/moddex-caddy.service
systemctl daemon-reload
systemctl enable --now moddex-backend.service
systemctl enable --now moddex-caddy.service

trap - ERR

log "Installation complete"
case "$MODE" in
  local)
    printf 'Frontend: https://127.0.0.1:8443\n'
    ;;
  lan)
    printf 'Frontend: https://<server-ip>:8443\n'
    ;;
  public)
    printf 'Frontend: https://%s\n' "$DOMAIN"
    ;;
 esac
printf 'API backend forwarded to 127.0.0.1:8080 via Caddy.\n'
