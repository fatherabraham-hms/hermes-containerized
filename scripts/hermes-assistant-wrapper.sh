#!/bin/bash
# Start/stop the isolated Hermes Assistant container stack.
#
# Credential model: names in config/env.allowlist; values from YOUR shell init
# (~/.bashrc by default). No secrets file on the data volume unless
# HERMES_LOAD_PERSISTED_ENV=1.

set -euo pipefail

ASSISTANT_ROOT="${HERMES_ASSISTANT_ROOT:-$HOME/hermes-assistant}"
export HERMES_ASSISTANT_ROOT="$ASSISTANT_ROOT"
HERMES_DATA="${HERMES_DATA_DIR:-$HOME/.hermes-assistant}"
WORKSPACE="${HERMES_WORKSPACE_DIR:-$HOME/hermes-workspace}"

cd "$ASSISTANT_ROOT"

# shellcheck source=container-runtime.sh
source "$ASSISTANT_ROOT/scripts/container-runtime.sh"
# shellcheck source=export-allowlisted-env.sh
source "$ASSISTANT_ROOT/scripts/export-allowlisted-env.sh"
# shellcheck source=hermes-agent-pin.sh
source "$ASSISTANT_ROOT/scripts/hermes-agent-pin.sh"

export HERMES_UID="${HERMES_UID:-$(id -u)}"
export HERMES_GID="${HERMES_GID:-$(id -g)}"
export HERMES_DATA_DIR="$HERMES_DATA"
export HERMES_WORKSPACE_DIR="$WORKSPACE"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9120}"

if [[ -z "${HERMES_BUILD_CONTEXT:-}" ]]; then
  if [[ -f "${HOME}/0_Development/hermes-agent/Dockerfile" ]]; then
    export HERMES_BUILD_CONTEXT="${HOME}/0_Development/hermes-agent"
  else
    export HERMES_BUILD_CONTEXT="/home/hermes/hermes-agent"
  fi
fi

hermes_prepare_persist_dirs
HERMES_DATA="$HERMES_DATA_DIR"
WORKSPACE="$HERMES_WORKSPACE_DIR"
hermes_write_compose_env "$ASSISTANT_ROOT"

hermes_load_allowlisted_exports || true
hermes_sync_operator_allowlist 2>/dev/null || true

hermes_compose() {
  local -a file_args=()
  hermes_unset_empty_compose_vars
  while IFS= read -r arg; do
    file_args+=("$arg")
  done < <(hermes_compose_file_args "$ASSISTANT_ROOT")
  $HERMES_COMPOSE "${file_args[@]}" "$@"
}

# Old kits emitted a ghost `dashboard:` service in compose.runtime.yml. Compose
# then tries to pull docker.io/library/hermes-assistant_dashboard:latest.
hermes_purge_stale_dashboard() {
  local id
  # Force-remove any leftover containers from the old two-service layout.
  for id in hermes-assistant_dashboard_1 hermes-assistant-dashboard \
    hermes-assistant_dashboard; do
    $HERMES_CONTAINER_CLI rm -f "$id" 2>/dev/null || true
  done
  # Drop dangling images named after the phantom service (ignore pull failures).
  $HERMES_CONTAINER_CLI rmi hermes-assistant_dashboard:latest 2>/dev/null || true
}

# After up, config.yaml is often root:root 0600 (stage2 chown fails on rootless
# binds; old :U mounts made it worse). Repair so --user hermes can read it.
#
# Skip when the operator runs rootless Podman directly (bucephalus3 layout):
# chown hermes:hermes inside the container remaps bind-mount files to subuid
# 100999 on the host, locking the operator out of ~/.hermes-assistant and
# breaking systemd EnvironmentFile + hermes_load_persisted_env.
hermes_repair_data_ownership() {
  if [[ "${HERMES_SKIP_DATA_CHOWN:-}" == "1" ]]; then
    return 0
  fi
  if [[ "$(id -u)" -eq "${HERMES_UID:-$(id -u)}" && "$(id -un)" != "hermes" ]]; then
    return 0
  fi
  local c="${HERMES_ASSISTANT_CONTAINER:-hermes-assistant}"
  local tries=0
  while ! $HERMES_CONTAINER_CLI inspect "$c" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [[ "$tries" -ge 30 ]] && return 1
    sleep 1
  done
  # Wait until stage2 has at least created/seeded config if missing.
  tries=0
  while ! $HERMES_CONTAINER_CLI exec "$c" test -f /opt/data/config.yaml 2>/dev/null; do
    tries=$((tries + 1))
    [[ "$tries" -ge 60 ]] && break
    sleep 1
  done
  $HERMES_CONTAINER_CLI exec -u root "$c" sh -c '
    for f in /opt/data/config.yaml /opt/data/.env /opt/data/auth.json \
             /opt/data/gateway_state.json /opt/data/env.allowlist; do
      [ -f "$f" ] || continue
      chown hermes:hermes "$f" 2>/dev/null || true
      chmod 640 "$f" 2>/dev/null || true
    done
    # Directory must be traversable by hermes
    chown hermes:hermes /opt/data 2>/dev/null || true
    chmod 755 /opt/data 2>/dev/null || true
    if [ -d /opt/data/workspace ]; then
      chown hermes:hermes /opt/data/workspace 2>/dev/null || true
      chmod 755 /opt/data/workspace 2>/dev/null || true
    fi
  ' 2>/dev/null || true
}

hermes_bring_up() {
  local -a up_args=(up -d --remove-orphans)
  local c="${HERMES_ASSISTANT_CONTAINER:-hermes-assistant}"
  local dash_port="${HERMES_DASHBOARD_PORT:-9119}"
  if command -v ss >/dev/null 2>&1 \
    && ss -tln 2>/dev/null | grep -q "127.0.0.1:${dash_port} "; then
    printf 'WARN: port %s already in use on the host (network_mode: host).\n' "$dash_port" >&2
    printf '  An old Hermes dashboard (often under user hermes) may still be running.\n' >&2
    printf '  Stop it: sudo -u hermes podman stop hermes-assistant\n' >&2
    printf '  Or:     sudo kill $(pgrep -f "hermes dashboard --host 127.0.0.1 --port %s")\n' "$dash_port" >&2
    printf '  Then:   systemctl --user restart hermes-assistant-gateway.service\n' >&2
  fi
  if [[ "${1:-}" == "--build" ]]; then
    up_args+=(--build)
    hermes_check_agent_pin "${HERMES_BUILD_CONTEXT}"
  fi
  # Regenerate runtime BEFORE down/up so compose no longer sees `dashboard:`.
  hermes_prepare_allowlisted_compose
  hermes_purge_stale_dashboard
  # Never pass --volumes / -v: that removes anonymous volumes if a bind failed
  # to attach (image VOLUME ["/opt/data"] fallback). Host bind contents are
  # never deleted by `down` without -v.
  hermes_compose down --remove-orphans 2>/dev/null || hermes_compose down || true
  hermes_purge_stale_dashboard
  # Clear stale/exited containers that block `podman run --name=hermes-assistant`.
  $HERMES_CONTAINER_CLI rm -f "$c" 2>/dev/null || true
  hermes_compose "${up_args[@]}"
  hermes_repair_data_ownership
  if [[ "${HERMES_SKIP_VERIFY:-}" == "1" ]]; then
    return 0
  fi
  local tries=0
  until bash "${ASSISTANT_ROOT}/scripts/verify-isolation.sh"; do
    tries=$((tries + 1))
    if [[ "$tries" -ge 12 ]]; then
      return 1
    fi
    sleep 5
  done
}

case "${1:-start}" in
  start)
    hermes_bring_up
    ;;
  stop)
    hermes_prepare_allowlisted_compose 2>/dev/null || true
    # No --volumes / -v — see hermes_bring_up.
    hermes_compose down --remove-orphans 2>/dev/null || hermes_compose down || true
    hermes_purge_stale_dashboard
    ;;
  restart)
    hermes_bring_up
    ;;
  recreate)
    hermes_bring_up --build
    ;;
  status)
    hermes_compose ps
    ;;
  logs)
    hermes_compose logs -f "${2:-gateway}"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|recreate|status|logs [service]}" >&2
    echo "Start/restart must be run from a shell that already exports your keys." >&2
    echo "From bucephalus3: ~/hermes-assistant/scripts/launch-with-host-env.sh start" >&2
    exit 1
    ;;
esac
