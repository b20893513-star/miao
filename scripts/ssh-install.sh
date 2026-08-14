#!/usr/bin/env bash
# Installa l'ultimo .deb su iPhone via SSH (OpenSSH / NewTerm).
# Uso:
#   export PHONE_HOST=192.168.1.20
#   export PHONE_PORT=22
#   export PHONE_USER=mobile
#   ./scripts/ssh-install.sh packages/*.deb
set -euo pipefail

DEB="${1:-}"
if [[ -z "$DEB" || ! -f "$DEB" ]]; then
  echo "Usage: $0 path/to/package.deb" >&2
  exit 1
fi

HOST="${PHONE_HOST:?set PHONE_HOST}"
PORT="${PHONE_PORT:-22}"
USER="${PHONE_USER:-mobile}"
REMOTE_DEB="/var/mobile/Documents/$(basename "$DEB")"

echo ">> copy $DEB -> $USER@$HOST:$REMOTE_DEB"
scp -P "$PORT" -o StrictHostKeyChecking=accept-new "$DEB" "$USER@${HOST}:$REMOTE_DEB"

echo ">> dpkg -i + sbreload"
ssh -p "$PORT" -o StrictHostKeyChecking=accept-new "$USER@$HOST" "bash -lc 'dpkg -i \"$REMOTE_DEB\" && (sbreload || ldrestart || true)'"

echo ">> done"
