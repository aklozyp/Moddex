#!/usr/bin/env bash
set -euo pipefail

MODE=""
BACKEND_JAR=""
FRONTEND_DIR=""
NONINTERACTIVE="false"
SERVER_PORT="7870"
SERVER_ADDRESS=""

print_usage() {
  cat <<'USAGE'
Usage: install-moddex.sh [options]

Options:
  --mode <local|lan|public>   Installation mode (prompts if omitted)
  --backend-jar <path>        Path to the backend jar (defaults to target/*.jar)
  --frontend-dir <path>       Path to built frontend assets (defaults to ../Moddex-Frontend/dist)
  --port <number>             TCP port the backend should listen on (default: 8080)
  --non-interactive           Fail instead of prompting when required values missing
  -h, --help                  Show this help
USAGE
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "This installer must be run as root."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="$2"; shift 2;
        ;;
      --backend-jar)
        BACKEND_JAR="$2"; shift 2;
        ;;
      --frontend-dir)
        FRONTEND_DIR="$2"; shift 2;
        ;;
      --port)
        SERVER_PORT="$2"; shift 2;
        ;;
      --non-interactive)
        NONINTERACTIVE="true"; shift;
        ;;
      -h|--help)
        print_usage; exit 0;
        ;;
      *)
        fail "Unknown argument: $1";
        ;;
    esac
  done
}

prompt_mode() {
  if [[ -n "$MODE" ]]; then
    case "$MODE" in
      local|lan|public) return;;
      *) fail "Invalid mode: $MODE";;
    esac
  fi
  if [[ "$NONINTERACTIVE" == "true" ]]; then
    fail "--mode is required in non-interactive mode"
  fi
  echo "Choose installation mode:"
  echo "  1) local-only (bind 127.0.0.1)"
  echo "  2) lan (bind 0.0.0.0)"
  echo "  3) public (bind 0.0.0.0)"
  read -rp "Selection [1-3]: " choice
  case "$choice" in
    1) MODE="local";;
    2) MODE="lan";;
    3) MODE="public";;
    *) fail "Invalid selection";;
  esac
}

resolve_backend_jar() {
  if [[ -n "$BACKEND_JAR" ]]; then
    return
  fi
  local candidate
  candidate=$(ls -1 Moddex-Backend/target/Moddex-Backend-*.jar 2>/dev/null | head -n1 || true)
  if [[ -z "$candidate" ]]; then
    fail "Could not locate backend jar. Build the project or pass --backend-jar."
  fi
  BACKEND_JAR="$candidate"
}

resolve_frontend_dir() {
  if [[ -n "$FRONTEND_DIR" ]]; then
    return
  fi
  if [[ -d Moddex-Frontend/dist ]]; then
    FRONTEND_DIR="Moddex-Frontend/dist"
    return
  fi
  if [[ -d Moddex-Frontend/dist/moddex-frontend ]]; then
    FRONTEND_DIR="Moddex-Frontend/dist/moddex-frontend"
    return
  fi
  echo "Warning: Could not locate frontend build artifacts. Run the Angular build or pass --frontend-dir." >&2
  FRONTEND_DIR=""
}

resolve_binding() {
  case "$MODE" in
    local)
      SERVER_ADDRESS="127.0.0.1"
      ;;
    lan|public)
      SERVER_ADDRESS="0.0.0.0"
      ;;
    *)
      fail "Unsupported mode: $MODE"
      ;;
  esac
}

ensure_packages() {
  if command_exists apt-get; then
    if ! command_exists rsync; then
      echo "Installing rsync ..."
      apt-get install -y rsync >/dev/null
    fi
  else
    if ! command_exists rsync; then
      echo "Warning: rsync not found. Please install it manually before rerunning." >&2
      fail "Missing dependency: rsync"
    fi
  fi
}

ensure_user() {
  if ! id -u moddex >/dev/null 2>&1; then
    useradd --system --home /var/lib/moddex --shell /usr/sbin/nologin moddex
  fi
}

create_directories() {
  install -d -o moddex -g moddex /var/lib/moddex
  install -d -o moddex -g moddex /var/lib/moddex/ui
  install -d -o moddex -g moddex /var/lib/moddex/logs
  install -d -o moddex -g moddex /opt/moddex
  install -d -o moddex -g moddex /etc/moddex
}

install_artifacts() {
  echo "Deploying backend jar from $BACKEND_JAR"
  install -m 0644 "$BACKEND_JAR" /opt/moddex/moddex-backend.jar
  chown moddex:moddex /opt/moddex/moddex-backend.jar

  if [[ -n "$FRONTEND_DIR" ]]; then
    echo "Deploying frontend assets from $FRONTEND_DIR"
    rsync -a --delete "$FRONTEND_DIR"/ /var/lib/moddex/ui/
    chown -R moddex:moddex /var/lib/moddex/ui
  else
    echo "Skipping frontend asset deployment (no build directory provided)."
  fi
}

configure_systemd() {
  cat > /etc/systemd/system/moddex-backend.service <<UNIT
[Unit]
Description=Moddex Backend API
After=network.target

[Service]
User=moddex
Group=moddex
WorkingDirectory=/opt/moddex
Environment=MODDEX_ROOT=/var/lib/moddex
Environment=MODDEX_LOG_DIR=/var/lib/moddex/logs
Environment=SERVER_ADDRESS=$SERVER_ADDRESS
Environment=SERVER_PORT=$SERVER_PORT
ExecStart=/usr/bin/env java -jar /opt/moddex/moddex-backend.jar
Restart=on-failure
RestartSec=5
SuccessExitStatus=143 130
StandardOutput=append:/var/lib/moddex/logs/backend.out.log
StandardError=append:/var/lib/moddex/logs/backend.err.log

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable moddex-backend.service
}

configure_firewall() {
  if [[ "$MODE" == "local" ]]; then
    return
  fi
  if command_exists ufw; then
    ufw allow "$SERVER_PORT"/tcp || true
  elif command_exists firewall-cmd; then
    firewall-cmd --permanent --add-port="$SERVER_PORT"/tcp || true
    firewall-cmd --reload || true
  else
    echo "Warning: Unable to configure firewall automatically. Please allow TCP $SERVER_PORT manually." >&2
  fi
}

start_services() {
  systemctl restart moddex-backend.service
}

summary() {
  local endpoint
  case "$MODE" in
    local) endpoint="http://127.0.0.1:$SERVER_PORT";;
    lan) endpoint="http://<server-ip>:$SERVER_PORT";;
    public) endpoint="http://$SERVER_ADDRESS:$SERVER_PORT";;
  esac
  cat <<EOF
Installation complete.

Mode: $MODE
Backend JAR: /opt/moddex/moddex-backend.jar
Backend API: $endpoint
Logs: /var/lib/moddex/logs
Systemd service: moddex-backend

Authentication is disabled. Protect the host via network policies if exposed publicly.
EOF
  if [[ -n "$FRONTEND_DIR" ]]; then
    echo "Static frontend assets installed to /var/lib/moddex/ui (serve them with your web server of choice)."
  fi
}

main() {
  parse_args "$@"
  ensure_root
  prompt_mode
  resolve_backend_jar
  resolve_frontend_dir
  ensure_packages
  ensure_user
  resolve_binding
  create_directories
  install_artifacts
  configure_systemd
  configure_firewall
  start_services
  summary
}

main "$@"
