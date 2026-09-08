#!/bin/bash
# Quick health check for the Hermes dashboard on localhost:9120.
# Run as bucephalus3 or with sudo for hermes podman state.

set -euo pipefail

TARGET_USER="${HERMES_TARGET_USER:-hermes}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || true)"
PORT="${HERMES_DASHBOARD_PORT:-9120}"

echo "== Port ${PORT} =="
if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
  ss -tlnp | grep ":${PORT} " || true
else
  echo "NOT LISTENING on ${PORT}"
fi

echo ""
echo "== HTTP probe =="
if command -v curl >/dev/null 2>&1; then
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 2 "http://127.0.0.1:${PORT}/" || echo "curl failed"
else
  echo "curl not installed"
fi

if [[ -z "${TARGET_UID}" ]]; then
  echo ""
  echo "User ${TARGET_USER} not found — skipping podman checks."
  exit 0
fi

echo ""
echo "== Podman (as ${TARGET_USER}) =="
run_as_hermes() {
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$TARGET_USER" -- bash -lc "export XDG_RUNTIME_DIR=/run/user/${TARGET_UID}; $*"
  else
    sudo -u "$TARGET_USER" bash -lc "export XDG_RUNTIME_DIR=/run/user/${TARGET_UID}; $*"
  fi
}

run_as_hermes 'podman ps -a --format "table {{.Names}}\t{{.Status}}"' || echo "podman ps failed (stuck sudo/runuser?)"

echo ""
echo "== Recent container logs (gateway) =="
run_as_hermes 'podman logs --tail 30 hermes-assistant 2>&1' || true

echo ""
echo "If port is down but containers show Up:"
echo "  - stage2 chown may still be running (wait 2-5 min after start)"
echo "  - fix data ownership: sudo bash ~/hermes-assistant/scripts/fix-home-permissions.sh"
echo "  - restart: source ~/.bashrc && ~/hermes-assistant/scripts/launch-with-host-env.sh start"
