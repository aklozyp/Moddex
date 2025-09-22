#!/usr/bin/env bash
set -euo pipefail

# ---------- CLI args ----------
MODE="local"       # local|lan|public
DOMAIN=""          # for public
EMAIL=""           # for public (ACME)
PASSWORD=""        # Basic Auth
BACKEND_JAR=""     # optional override
FRONTEND_DIR=""    # optional override

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    --backend-jar) BACKEND_JAR="$2"; shift 2;;
    --frontend-dir) FRONTEND_DIR="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

MODE_LOWER="$(echo "$MODE" | tr '[:upper:]' '[:lower:]')"
TEMPLATE_DIR="$(dirname "$0")/../packaging/caddy"

# ---------- Packages ----------
echo "[1/6] Installing packages"
if command -v apt-get >/dev/null; then
  sudo apt-get update -y
  # curl, rsync, htpasswd, envsubst
  sudo apt-get install -y curl rsync apache2-utils gettext-base ca-certificates
  # Caddy from official repo (Cloudsmith)
  if ! command -v caddy >/dev/null; then
    sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https gnupg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | sudo tee /usr/share/keyrings/caddy-stable-archive-keyring.gpg >/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y caddy
  fi
else
  echo "Unsupported distro: please install Caddy, htpasswd, rsync, gettext-base manually."
  exit 1
fi
# refs: official Caddy install for Debian/Ubuntu, envsubst comes from gettext-base. :contentReference[oaicite:2]{index=2}

# ---------- Users/dirs ----------
echo "[2/6] Creating user and directories"
sudo useradd -r -s /usr/sbin/nologin moddex 2>/dev/null || true
sudo mkdir -p /opt/moddex /var/lib/moddex/ui /var/lib/moddex/logs /etc/moddex
sudo chown -R moddex:moddex /opt/moddex /var/lib/moddex /etc/moddex

# ---------- Deploy artifacts ----------
echo "[3/6] Deploying artifacts"
BACKEND_JAR="${BACKEND_JAR:-./backend/Moddex-Backend.jar}"
FRONTEND_DIR="${FRONTEND_DIR:-./frontend}"
sudo install -m 0644 "$BACKEND_JAR" /opt/moddex/app.jar
sudo rsync -a --delete "$FRONTEND_DIR"/ /var/lib/moddex/ui/

# ---------- Config / Basic Auth / Caddyfile ----------
echo "[4/6] Writing configuration"
[[ -n "$PASSWORD" ]] || { read -rs -p "Admin password: " PASSWORD; echo; }
# optional defaults
: | sudo tee /etc/moddex/serversettings.json >/dev/null
: | sudo tee /etc/moddex/clientsettings.json  >/dev/null

# htpasswd file and in-template hash (bcrypt)
sudo htpasswd -cbB /etc/moddex/htpasswd admin "$PASSWORD"
HASH_LINE="$(htpasswd -nbB admin "$PASSWORD")"
HTPASS_ADMIN_HASH="${HASH_LINE#admin:}"   # extract hash after "admin:"

# sanity for public mode
if [[ "$MODE_LOWER" == "public" ]]; then
  [[ -n "$DOMAIN" && -n "$EMAIL" ]] || { echo "--domain and --email required in public mode"; exit 2; }
fi

# render Caddyfile once (single source of truth)
sudo env MODE="$MODE_LOWER" DOMAIN="$DOMAIN" EMAIL="$EMAIL" HTPASS_ADMIN_HASH="$HTPASS_ADMIN_HASH" \
  bash -c 'envsubst < "'"$TEMPLATE_DIR"'/Caddyfile.tmpl" > /etc/moddex/Caddyfile'

# ---------- systemd ----------
echo "[5/6] Enabling services"
sudo install -m 0644 "$(dirname "$0")/../packaging/systemd/moddex-backend.service" /etc/systemd/system/
sudo install -m 0644 "$(dirname "$0")/../packaging/systemd/moddex-caddy.service"   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable moddex-backend moddex-caddy
sudo systemctl restart moddex-backend moddex-caddy

# ---------- Done ----------
echo "[6/6] Done. Connect at:"
case "$MODE_LOWER" in
  local)  echo "  https://127.0.0.1:8443" ;;
  lan)    echo "  https://<server-ip>:8443" ;;
  public) echo "  https://$DOMAIN" ;;
esac
