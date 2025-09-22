#!/usr/bin/env bash
set -euo pipefail
read -p "Wirklich deinstallieren? [y/N] " a
[[ "${a,,}" == "y" ]] || exit 0
sudo systemctl disable --now moddex-backend moddex-caddy || true
sudo rm -f /etc/systemd/system/moddex-backend.service /etc/systemd/system/moddex-caddy.service
sudo systemctl daemon-reload || true
sudo rm -rf /opt/moddex /var/lib/moddex /etc/moddex
sudo userdel moddex 2>/dev/null || true
echo "Moddex entfernt."
