#!/bin/bash
# Host CLI for Hermes running inside the isolated container.
# Usage: hermes-assistant chat | hermes-assistant gateway status | ...

set -euo pipefail

ASSISTANT_ROOT="${HERMES_ASSISTANT_ROOT:-$HOME/hermes-assistant}"
# shellcheck source=container-runtime.sh
source "$ASSISTANT_ROOT/scripts/container-runtime.sh"

CONTAINER="${HERMES_ASSISTANT_CONTAINER:-hermes-assistant}"

if ! $HERMES_CONTAINER_CLI inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Container $CONTAINER is not running. Start with:" >&2
  echo "  hermes-assistant-wrapper.sh start" >&2
  echo "  # or: systemctl --user start hermes-assistant-gateway.service" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  set -- chat
fi

exec $HERMES_CONTAINER_CLI exec -it --user hermes \
  -e HERMES_HOME=/opt/data \
  -e HOME=/opt/data/home \
  -w /opt/data/workspace \
  "$CONTAINER" \
  hermes "$@"
