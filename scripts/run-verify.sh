#!/bin/bash
# Run verification on the host as user hermes (from bucephalus3 or root).
# Does NOT use podman exec — avoids in-container sudo/password issues.

set -euo pipefail

TARGET_HOME="${HERMES_TARGET_HOME:-/home/hermes}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -eq 0 ]]; then
  exec runuser -u hermes -- env \
    HERMES_ASSISTANT_ROOT="${TARGET_HOME}/hermes-assistant" \
    HERMES_DATA_DIR="${TARGET_HOME}/.hermes-assistant" \
    HERMES_WORKSPACE_DIR="${TARGET_HOME}/hermes-workspace" \
    bash -c "cd '${TARGET_HOME}/hermes-assistant' && exec ./scripts/verify-isolation.sh"
fi

exec sudo -u hermes env \
  HERMES_ASSISTANT_ROOT="${TARGET_HOME}/hermes-assistant" \
  HERMES_DATA_DIR="${TARGET_HOME}/.hermes-assistant" \
  HERMES_WORKSPACE_DIR="${TARGET_HOME}/hermes-workspace" \
  bash -c "cd '${TARGET_HOME}/hermes-assistant' && exec ./scripts/verify-isolation.sh"
