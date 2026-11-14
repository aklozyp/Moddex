#!/usr/bin/env bash
set -euo pipefail

TARGET="/usr/local/bin/moddex"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Installing moddex CLI helper to ${TARGET} ..."
install -m 0755 "${SRC_DIR}/bin/moddex" "$TARGET"
echo "Done. Run 'moddex help' for usage instructions."
