#!/bin/bash
# Bootstrap isolated Hermes Assistant (Option C — whole-process Docker).
# Safe to re-run; does not source ~/.bashrc.

set -euo pipefail

ASSISTANT_ROOT="${HERMES_ASSISTANT_ROOT:-$HOME/hermes-assistant}"
HERMES_DATA="${HERMES_DATA_DIR:-$HOME/.hermes-assistant}"
WORKSPACE="${HERMES_WORKSPACE_DIR:-$HOME/hermes-workspace}"
BUILD_CONTEXT="${HERMES_BUILD_CONTEXT:-/home/hermes/hermes-agent}"
REPO="${HERMES_REPO:-$BUILD_CONTEXT}"
BIN_DIR="${HOME}/bin"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=container-runtime.sh
source "$ASSISTANT_ROOT/scripts/container-runtime.sh"

export HERMES_DATA_DIR="$HERMES_DATA"
export HERMES_WORKSPACE_DIR="$WORKSPACE"
hermes_prepare_persist_dirs
HERMES_DATA="$HERMES_DATA_DIR"
WORKSPACE="$HERMES_WORKSPACE_DIR"

mkdir -p "$BIN_DIR"
chmod 700 "$HERMES_DATA"

if [[ ! -f "$HERMES_DATA/config.yaml" ]]; then
  cp "$ASSISTANT_ROOT/config/config.yaml" "$HERMES_DATA/config.yaml"
  log "Installed $HERMES_DATA/config.yaml"
else
  log "Keeping existing $HERMES_DATA/config.yaml"
fi

if [[ ! -f "$ASSISTANT_ROOT/config/env.allowlist" ]]; then
  cp "$ASSISTANT_ROOT/config/env.allowlist.example" "$ASSISTANT_ROOT/config/env.allowlist"
  log "Created $ASSISTANT_ROOT/config/env.allowlist — edit variable NAMES here (no values)"
fi
if [[ ! -f "$HERMES_DATA/env.allowlist" ]]; then
  cp "$ASSISTANT_ROOT/config/env.allowlist.example" "$HERMES_DATA/env.allowlist"
  chmod 600 "$HERMES_DATA/env.allowlist"
  log "Created $HERMES_DATA/env.allowlist"
fi
if [[ ! -f "$ASSISTANT_ROOT/config/env.allowlist" ]]; then
  cp "$ASSISTANT_ROOT/config/env.allowlist.example" "$ASSISTANT_ROOT/config/env.allowlist"
  log "Created $ASSISTANT_ROOT/config/env.allowlist — edit variable NAMES here (no values)"
fi

install -m 0755 "$ASSISTANT_ROOT/scripts/hermes-assistant-wrapper.sh" "$BIN_DIR/hermes-assistant-wrapper.sh"
install -m 0755 "$ASSISTANT_ROOT/scripts/hermes-assistant-cli.sh" "$BIN_DIR/hermes-assistant"

mkdir -p "${HOME}/.config/systemd/user"
install -m 0644 "$ASSISTANT_ROOT/systemd/hermes-assistant-gateway.service" \
  "${HOME}/.config/systemd/user/hermes-assistant-gateway.service"

export HERMES_UID="$(id -u)"
export HERMES_GID="$(id -g)"
export HERMES_DATA_DIR="$HERMES_DATA"
export HERMES_WORKSPACE_DIR="$WORKSPACE"
export HERMES_BUILD_CONTEXT="$BUILD_CONTEXT"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9120}"

hermes_prepare_persist_dirs
hermes_write_compose_env "$ASSISTANT_ROOT"

if [[ ! -f "${HERMES_BUILD_CONTEXT}/Dockerfile" ]]; then
  die "Build context missing Dockerfile at ${HERMES_BUILD_CONTEXT}. As admin run: sudo bash ${ASSISTANT_ROOT}/scripts/prepare-build-context.sh"
fi

log ""
log "Building and starting containers (first run may take several minutes)..."
cd "$ASSISTANT_ROOT"
hermes_unset_empty_compose_vars
$HERMES_COMPOSE build
$HERMES_COMPOSE up -d

if [[ "${HERMES_SKIP_VERIFY:-}" != "1" ]]; then
  log ""
  log "Running verification..."
  bash "${ASSISTANT_ROOT}/scripts/verify-isolation.sh"
fi

log ""
log "Bootstrap complete."
log "  Data:      $HERMES_DATA"
log "  Workspace: $WORKSPACE"
log "  Allowlist: $HERMES_DATA/env.allowlist (names only — values stay in your shell)"
log "  CLI:       hermes-assistant chat"
log "  Dashboard: http://127.0.0.1:9119 (after gateway is healthy)"
log ""
log "Start with keys from your shell (not .env files):"
log "  # edit allowlist names, load keys in shell, then:"
log "  hermes-assistant-wrapper.sh start"
log "  # from bucephalus3: ~/hermes-assistant/scripts/launch-with-host-env.sh start"
log ""
log "Enable systemd (optional):"
log "  systemctl --user daemon-reload"
log "  systemctl --user enable --now hermes-assistant-gateway.service"
log ""
log "Run isolation checks:"
log "  $ASSISTANT_ROOT/scripts/verify-isolation.sh"
