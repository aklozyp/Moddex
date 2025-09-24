#!/usr/bin/env bash
set -Eeuo pipefail

# This installer must run with root privileges.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if [[ -z "${MODDEX_INSTALL_REEXEC:-}" ]] && command -v sudo >/dev/null 2>&1; then
    export MODDEX_INSTALL_REEXEC=1
    exec sudo -E "$0" "$@"
  fi
  echo "This installer must run with root privileges." >&2
  exit 1
fi
unset MODDEX_INSTALL_REEXEC

# Abort on error
on_error() {
  local exit_code="$1" line="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    printf '[ERROR] Installation aborted (exit %s at line %s)\n' "$exit_code" "$line" >&2
  fi
}
trap 'on_error $? $LINENO' ERR

umask 022

# --- Configuration & Defaults ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEMD_DIR="$PROJECT_ROOT/packaging/systemd"

MODE="${MODE:-${MODDEX_MODE:-}}"
DOMAIN="${DOMAIN:-${MODDEX_DOMAIN:-}}"
EMAIL="${EMAIL:-${MODDEX_ACME_EMAIL:-}}"
CADDY_USER="${CADDY_USER:-${MODDEX_CADDY_USER:-}}"
CADDY_PASS="${CADDY_PASS:-${MODDEX_CADDY_PASS:-}}"
BACKEND_JAR="${BACKEND_JAR:-${MODDEX_BACKEND_JAR:-}}"
FRONTEND_DIR="${FRONTEND_DIR:-${MODDEX_FRONTEND_DIR:-}}"

# --- Helper Functions ---
log() { printf '[moddex-install] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Options:
  --mode MODE           Deployment mode: local, lan, public
  --domain DOMAIN       Public domain name (required for --mode public)
  --email EMAIL         ACME contact email (required for --mode public)
  --caddy-user USER     Admin username for Caddy basic auth
  --caddy-pass PASS     Admin password for Caddy basic auth
  --backend-jar PATH    Path to the backend JAR to install
  --frontend-dir PATH   Path to the directory with built frontend assets
  -h, --help            Show this help and exit

Environment overrides:
  MODDEX_MODE, MODDEX_DOMAIN, MODDEX_ACME_EMAIL, MODDEX_CADDY_USER,
  MODDEX_CADDY_PASS, MODDEX_BACKEND_JAR, MODDEX_FRONTEND_DIR
USAGE
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) [[ $# -ge 2 ]] || die "Missing value for --mode"; MODE="$2"; shift 2 ;;
    --domain) [[ $# -ge 2 ]] || die "Missing value for --domain"; DOMAIN="$2"; shift 2 ;;
    --email) [[ $# -ge 2 ]] || die "Missing value for --email"; EMAIL="$2"; shift 2 ;;
    --caddy-user) [[ $# -ge 2 ]] || die "Missing value for --caddy-user"; CADDY_USER="$2"; shift 2 ;;
    --caddy-pass) [[ $# -ge 2 ]] || die "Missing value for --caddy-pass"; CADDY_PASS="$2"; shift 2 ;;
    --backend-jar) [[ $# -ge 2 ]] || die "Missing value for --backend-jar"; BACKEND_JAR="$2"; shift 2 ;;
    --frontend-dir) [[ $# -ge 2 ]] || die "Missing value for --frontend-dir"; FRONTEND_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# --- Interactive Prompts ---
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

if [[ -z "$CADDY_USER" ]]; then
  read -r -p "Please enter the admin username for the web interface: " CADDY_USER
  [[ -n "$CADDY_USER" ]] || die "Username cannot be empty."
fi

if [[ -z "$CADDY_PASS" ]]; then
  read -r -s -p "Please enter the admin password: " CADDY_PASS
  echo
  [[ -n "$CADDY_PASS" ]] || die "Password cannot be empty."
fi

# --- Validate Configuration ---
MODE="${MODE,,}"
case "$MODE" in
  local|lan|public) ;;
  *) die "Invalid --mode value: $MODE (expected local, lan, or public)" ;;
esac

if [[ "$MODE" == "public" ]]; then
  if [[ -z "$DOMAIN" ]]; then
    read -r -p "Enter public domain name (e.g., moddex.example.com): " DOMAIN
    [[ -n "$DOMAIN" ]] || die "--domain is required for public mode"
  fi
  if [[ -z "$EMAIL" ]]; then
    read -r -p "Enter ACME contact email (for SSL certs): " EMAIL
    [[ -n "$EMAIL" ]] || die "--email is required for public mode"
  fi
fi

[[ -n "$BACKEND_JAR" && -f "$BACKEND_JAR" ]] || die "Backend JAR not found or not specified. Use --backend-jar."
[[ -n "$FRONTEND_DIR" && -d "$FRONTEND_DIR" && -f "$FRONTEND_DIR/index.html" ]] || die "Frontend directory not found, invalid, or missing index.html. Use --frontend-dir."

# --- Dependency Installation ---
log "Checking and installing dependencies..."
need_cmd install
need_cmd rsync
need_cmd systemctl
need_cmd curl
need_cmd gpg

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
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}
ensure_package() {
  dpkg -s "$1" >/dev/null 2>&1 || apt_install "$1"
}

ensure_caddy_repo() {
  local key_file=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
  local list_file=/etc/apt/sources.list.d/caddy-stable.list
  if [[ -f "$key_file" && -f "$list_file" ]]; then return; fi

  log "Configuring Caddy APT repository"
  ensure_package debian-keyring
  ensure_package debian-archive-keyring
  ensure_package apt-transport-https
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor > /tmp/caddy.gpg
  install -m 0644 /tmp/caddy.gpg "$key_file"
  rm -f /tmp/caddy.gpg
  cat > "$list_file" <<__CADDY__
deb [signed-by=$key_file] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
__CADDY__
  APT_UPDATED=0
}

ensure_package ca-certificates
ensure_package openjdk-17-jre-headless
ensure_caddy_repo
ensure_package caddy

need_cmd java
need_cmd caddy

# --- System Setup ---
log "Creating moddex user and directories"
if ! id -u moddex >/dev/null 2>&1; then
  useradd -r -M -s /usr/sbin/nologin -d /opt/moddex moddex
fi

install -d -m 0755 -o moddex -g moddex /opt/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/ui
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/logs
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/caddy
install -d -m 0750 -o root -g moddex /etc/moddex

# --- Deployment ---
log "Deploying backend artifact"
install -m 0644 "$BACKEND_JAR" /opt/moddex/app.jar
chown moddex:moddex /opt/moddex/app.jar

log "Deploying frontend assets from $FRONTEND_DIR"
rsync -a --delete --chown=moddex:moddex "$FRONTEND_DIR/" /var/lib/moddex/ui/

# --- Caddy Configuration ---
log "Generating Caddy configuration"
HTPASS_HASH=$(caddy hash-password --plaintext "$CADDY_PASS")

# Use Caddyfile template from packaging dir
CADDY_TEMPLATE="$PROJECT_ROOT/packaging/caddy/Caddyfile.tmpl"
[[ -f "$CADDY_TEMPLATE" ]] || die "Caddyfile template not found at $CADDY_TEMPLATE"

# Create a temporary Caddyfile from the template
CADDYFILE_CONTENT=$(<"$CADDY_TEMPLATE")
CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$DOMAIN:8443\}/${DOMAIN:-:8443}}"
CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$HTPASS_ADMIN_HASH\}/$HTPASS_HASH}"
CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$EMAIL\}/$EMAIL}"

# Handle mode-specific blocks
if [[ "$MODE" == "public" ]]; then
  CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$if MODE == "public"\}/}"
  CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$end\}/}"
  CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$if MODE != "public"\}/#}"
else
  CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$if MODE != "public"\}/}"
  CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$end\}/}"
  CADDYFILE_CONTENT="${CADDYFILE_CONTENT//\{\$if MODE == "public"\}/#}"
fi
# Simple replacement for the admin user
CADDYFILE_CONTENT="${CADDYFILE_CONTENT//admin/$CADDY_USER}"


echo "$CADDYFILE_CONTENT" > /etc/moddex/Caddyfile
chown root:moddex /etc/moddex/Caddyfile
chmod 0640 /etc/moddex/Caddyfile

# --- Service Installation ---
log "Installing systemd units"
install -m 0644 "$SYSTEMD_DIR/moddex-backend.service" /etc/systemd/system/moddex-backend.service
install -m 0644 "$SYSTEMD_DIR/moddex-caddy.service" /etc/systemd/system/moddex-caddy.service

log "Reloading systemd, enabling and starting services"
systemctl daemon-reload
systemctl enable --now moddex-backend.service moddex-caddy.service
systemctl restart moddex-backend.service moddex-caddy.service

trap - ERR

# --- Completion ---
log "Installation complete!"
log "Caddy logs: journalctl -u moddex-caddy -f"
log "Backend logs: /var/lib/moddex/logs/backend.*.log"

case "$MODE" in
  local)
    printf 'Frontend available at: https://localhost:8443 (or https://127.0.0.1:8443)\n'
    ;;
  lan)
    printf 'Frontend available at: https://<server-ip>:8443\n'
    ;;
  public)
    printf 'Frontend available at: https://%s\n' "$DOMAIN"
    ;;
esac
printf 'Login with username: %s\n' "$CADDY_USER"