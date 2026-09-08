#!/bin/bash
# Rootless Podman: remap bind-mount ownership into the container user namespace.
#
# Host files owned by uid 1001 appear as container root (0). The supervised
# gateway and `hermes chat` run as container uid HERMES_UID (1001) and cannot
# read them until ownership is set via podman unshare.
#
# Run AFTER fix-home-permissions.sh.
# From bucephalus3 (preferred — kit path; do NOT use ~ under sudo for wrong home):
#   sudo bash /home/bucephalus3/hermes-assistant/scripts/fix-rootless-data-ownership.sh
# Deployed copy is root:root 0755 (hermes can execute, not rewrite):
#   sudo -u hermes bash /home/hermes/hermes-assistant/scripts/fix-rootless-data-ownership.sh

set -euo pipefail

TARGET_USER="${HERMES_TARGET_USER:-${SUDO_USER:-${USER}}}"
TARGET_HOME="${HERMES_TARGET_HOME:-/home/${TARGET_USER}}"
KIT_ROOT="${HERMES_OPERATOR_KIT:-/home/bucephalus3/hermes-assistant}"
DEPLOYED_SCRIPT="${TARGET_HOME}/hermes-assistant/scripts/fix-rootless-data-ownership.sh"
KIT_SCRIPT="${KIT_ROOT}/scripts/fix-rootless-data-ownership.sh"

if [[ "$(id -un)" != "${TARGET_USER}" ]]; then
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run with sudo: sudo bash ${KIT_SCRIPT}" >&2
    exit 1
  fi
  if [[ -f "$KIT_SCRIPT" ]]; then
    mkdir -p "$(dirname "$DEPLOYED_SCRIPT")"
    # root:root so hermes cannot rewrite this into a confused-deputy payload
    install -o root -g root -m 0755 "$KIT_SCRIPT" "$DEPLOYED_SCRIPT"
  fi
  # -H + explicit cd: operator cwd is often under /home/bucephalus3 (unreadable to
  # hermes). podman unshare chdir's to cwd and fails with Permission denied.
  exec sudo -u "${TARGET_USER}" -H bash -c \
    'cd "$1" && shift && exec bash "$@"' \
    _ "${TARGET_HOME}" "$DEPLOYED_SCRIPT" "$@"
fi

command -v podman >/dev/null 2>&1 || {
  echo "ERROR: podman not found for ${TARGET_USER}" >&2
  exit 1
}

# Ensure cwd is traversable by hermes / the user namespace (see sudo re-exec above).
if ! cd "$TARGET_HOME" 2>/dev/null; then
  echo "ERROR: cannot cd to ${TARGET_HOME}" >&2
  exit 1
fi

UID_GID="$(id -u)"
DATA="${TARGET_HOME}/.hermes-assistant"
WORKSPACE="${TARGET_HOME}/hermes-workspace"

# Also ensure host-side config is hermes-readable before remapping (container
# --user hermes must be able to grep config.yaml during verify-isolation).
if [[ -d "$DATA" ]]; then
  for f in config.yaml .env auth.json gateway_state.json env.allowlist; do
    if [[ -f "${DATA}/${f}" && ! -L "${DATA}/${f}" ]]; then
      chown "${UID_GID}:${UID_GID}" "${DATA}/${f}" 2>/dev/null || true
      chmod 600 "${DATA}/${f}" 2>/dev/null || true
    fi
  done
fi

for dir in "$DATA" "$WORKSPACE"; do
  [[ -d "$dir" ]] || continue
  echo "Remapping ${dir} for container uid ${UID_GID} (podman unshare chown)..."
  podman unshare chown -R "${UID_GID}:${UID_GID}" "$dir"
done

echo "OK: data volumes remapped for rootless Podman (container uid ${UID_GID})"
