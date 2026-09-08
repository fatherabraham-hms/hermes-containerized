#!/bin/bash
# Copy hermes-agent source into /home/hermes for rootless Podman builds.
# hermes cannot read /home/bucephalus3/... — build context must live under /home/hermes.
#
# Usage: sudo bash prepare-build-context.sh
#
# Copies source only (no node_modules / .venv). Image install uses the commit's
# uv.lock + package-lock.json. Refuses to sync if SOURCE HEAD ≠ hermes-agent.lock
# unless HERMES_SKIP_UPSTREAM_PIN=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export HERMES_ASSISTANT_ROOT="${HERMES_ASSISTANT_ROOT:-$KIT}"

SOURCE_USER="${HERMES_SOURCE_USER:-bucephalus3}"
SOURCE="${HERMES_REPO_SRC:-/home/${SOURCE_USER}/0_Development/hermes-agent}"
TARGET="${HERMES_BUILD_CONTEXT:-/home/hermes/hermes-agent}"
TARGET_USER="${HERMES_TARGET_USER:-hermes}"

# shellcheck source=hermes-agent-pin.sh
source "${SCRIPT_DIR}/hermes-agent-pin.sh"

log() { printf '[prepare-build-context] %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

if [[ ! -f "${SOURCE}/Dockerfile" ]]; then
  echo "ERROR: Dockerfile not found at ${SOURCE}" >&2
  echo "Clone or restore hermes-agent there, or set HERMES_REPO_SRC=/path/to/hermes-agent" >&2
  exit 1
fi

hermes_check_agent_pin "$SOURCE"

log "Syncing ${SOURCE} -> ${TARGET} (source + lockfiles, not downloaded trees)"
mkdir -p "${TARGET}"
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'node_modules/' \
  --exclude '.venv/' \
  --exclude 'venv/' \
  --exclude '__pycache__/' \
  --exclude '.uv-cache/' \
  --exclude '.pip-cache/' \
  --exclude '.pytest_cache/' \
  --exclude 'hermes_cli/web_dist/' \
  --exclude '.hermes-docker/' \
  "${SOURCE}/" "${TARGET}/"

hermes_lock_get HERMES_AGENT_COMMIT > "${TARGET}/.hermes-agent-commit"
# Stamp is not a secret; hermes must be able to read it on --build.
chmod 644 "${TARGET}/.hermes-agent-commit"

if ! id "${TARGET_USER}" &>/dev/null; then
  echo "ERROR: user ${TARGET_USER} does not exist" >&2
  exit 1
fi

chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET}"
log "Done. Build context: ${TARGET} pin=$(tr -d '[:space:]' < "${TARGET}/.hermes-agent-commit")"
