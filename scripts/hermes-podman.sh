#!/bin/bash
# Run podman as hermes from bucephalus3 without "cannot chdir to /home/bucephalus3".
# Usage: ~/hermes-assistant/scripts/hermes-podman.sh inspect hermes-assistant
#        ~/hermes-assistant/scripts/hermes-podman.sh ps -a

set -euo pipefail

TARGET_USER="${HERMES_TARGET_USER:-hermes}"
TARGET_HOME="${HERMES_TARGET_HOME:-/home/${TARGET_USER}}"

if [[ "$(id -u)" -eq 0 ]]; then
  cd "$TARGET_HOME"
  exec runuser -u "$TARGET_USER" -- podman "$@"
fi

# Avoid sudo --chdir (-D): some sudoers rules block it with podman.
exec sudo -u "$TARGET_USER" bash -c 'cd "$1" && shift && exec podman "$@"' bash "$TARGET_HOME" "$@"
