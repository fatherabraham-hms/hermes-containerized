#!/bin/bash
# Root-only half of launch-with-host-env.sh (sync kit → hermes, then runuser).
# Installed for passwordless sudo from the operator systemd unit:
#   bucephalus3 ALL=(root) NOPASSWD: /home/bucephalus3/hermes-assistant/scripts/run-as-hermes-privileged.sh
#
# Usage (as root):
#   run-as-hermes-privileged.sh start|stop|restart|recreate|status|logs

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root (via sudo)." >&2
  exit 1
fi

ACTION="${1:-start}"
OPERATOR_KIT="${HERMES_OPERATOR_KIT:-/home/bucephalus3/hermes-assistant}"
OPERATOR_USER="${HERMES_OPERATOR_USER:-bucephalus3}"
TARGET_USER="${HERMES_TARGET_USER:-hermes}"
TARGET_HOME="${HERMES_TARGET_HOME:-/home/${TARGET_USER}}"
TARGET_ASSISTANT="${TARGET_HOME}/hermes-assistant"
OPERATOR_ALLOWLIST="${OPERATOR_KIT}/config/env.allowlist"
OPERATOR_SECRETS="${OPERATOR_KIT}/config/env.secrets"
HERMES_ALLOWLIST="${TARGET_HOME}/.hermes-assistant/env.allowlist"

# shellcheck source=export-allowlisted-env.sh
source "${OPERATOR_KIT}/scripts/export-allowlisted-env.sh"

if ! id "$TARGET_USER" &>/dev/null; then
  echo "Missing user ${TARGET_USER}" >&2
  exit 1
fi

TARGET_UID="$(id -u "$TARGET_USER")"
RUNTIME_DIR="/run/user/${TARGET_UID}"
HERMES_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${TARGET_HOME}/bin"

# Load secrets file (systemd has no interactive shell). Prefer already-exported
# env from the caller; fill gaps from env.secrets.
if [[ -f "$OPERATOR_SECRETS" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key-}" ]] && continue
    val="${line#*=}"
    if [[ "$val" =~ ^\".*\"$ || "$val" =~ ^\'.*\'$ ]]; then
      val="${val:1:-1}"
    fi
    export "${key}=${val}"
  done < "$OPERATOR_SECRETS"
fi

HERMES_CONTAINER_CLI="podman"
if command -v podman-compose >/dev/null 2>&1; then
  HERMES_COMPOSE="podman-compose"
elif runuser -u "$TARGET_USER" -- bash -lc 'podman compose version' >/dev/null 2>&1; then
  HERMES_COMPOSE="podman compose"
else
  echo "ERROR: podman-compose / podman compose not found for ${TARGET_USER}" >&2
  exit 1
fi

# Sync kit → deployed tree (admin scripts root:root).
ADMIN_SCRIPTS=(
  fix-home-permissions.sh
  fix-rootless-data-ownership.sh
  prepare-build-context.sh
  migrate-to-hermes-user.sh
)
is_admin_script() {
  local s="$1" a
  for a in "${ADMIN_SCRIPTS[@]}"; do
    [[ "$s" == "$a" ]] && return 0
  done
  return 1
}

if [[ -d "$OPERATOR_KIT/scripts" && -d "$TARGET_ASSISTANT" ]]; then
  for script in verify-isolation.sh run-verify.sh hermes-podman.sh fix-home-permissions.sh \
    fix-rootless-data-ownership.sh hermes-assistant-wrapper.sh hermes-assistant-cli.sh \
    export-allowlisted-env.sh container-runtime.sh launch-with-host-env.sh \
    prepare-build-context.sh migrate-to-hermes-user.sh run-as-hermes-privileged.sh; do
    [[ -f "${OPERATOR_KIT}/scripts/${script}" ]] || continue
    if is_admin_script "$script" || [[ "$script" == "run-as-hermes-privileged.sh" ]]; then
      install -o root -g root -m 0755 \
        "${OPERATOR_KIT}/scripts/${script}" "${TARGET_ASSISTANT}/scripts/${script}"
    else
      install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
        "${OPERATOR_KIT}/scripts/${script}" "${TARGET_ASSISTANT}/scripts/${script}"
    fi
  done
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "${OPERATOR_KIT}/scripts/hermes-assistant-wrapper.sh" "${TARGET_HOME}/bin/hermes-assistant-wrapper.sh"
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "${OPERATOR_KIT}/scripts/hermes-assistant-cli.sh" "${TARGET_HOME}/bin/hermes-assistant"
  [[ -f "${OPERATOR_KIT}/docker-compose.yml" ]] && \
    install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
      "${OPERATOR_KIT}/docker-compose.yml" "${TARGET_ASSISTANT}/docker-compose.yml"
  if [[ -f "$OPERATOR_ALLOWLIST" ]]; then
    mkdir -p "${TARGET_ASSISTANT}/config" "${TARGET_HOME}/.hermes-assistant"
    install -o "$TARGET_USER" -g "$TARGET_USER" -m 644 \
      "$OPERATOR_ALLOWLIST" "${TARGET_ASSISTANT}/config/env.allowlist"
    install -o "$TARGET_USER" -g "$TARGET_USER" -m 600 \
      "$OPERATOR_ALLOWLIST" "$HERMES_ALLOWLIST"
  fi
fi

if [[ ! -d "$RUNTIME_DIR" ]]; then
  loginctl enable-linger "$TARGET_USER" 2>/dev/null || true
fi

# Forward only allowlisted names that are set.
mapfile -t names < <(hermes_read_allowlist_names "$OPERATOR_ALLOWLIST" || true)
forward_env=()
for name in "${names[@]}"; do
  if [[ -n "${!name-}" ]]; then
    forward_env+=("${name}=${!name}")
  fi
done

hermes_env=(
  "HOME=${TARGET_HOME}"
  "USER=${TARGET_USER}"
  "LOGNAME=${TARGET_USER}"
  "PWD=${TARGET_ASSISTANT}"
  "XDG_RUNTIME_DIR=${RUNTIME_DIR}"
  "PATH=${HERMES_PATH}"
  "HERMES_ASSISTANT_ROOT=${TARGET_ASSISTANT}"
  "HERMES_DATA_DIR=${TARGET_HOME}/.hermes-assistant"
  "HERMES_WORKSPACE_DIR=${TARGET_HOME}/hermes-workspace"
  "HERMES_BUILD_CONTEXT=${TARGET_HOME}/hermes-agent"
  "HERMES_CONTAINER_CLI=${HERMES_CONTAINER_CLI}"
  "HERMES_COMPOSE=${HERMES_COMPOSE}"
  "HERMES_OPERATOR_ALLOWLIST=${OPERATOR_ALLOWLIST}"
  "${forward_env[@]}"
)

wrapper_inner="cd \"${TARGET_ASSISTANT}\" && exec \"${TARGET_HOME}/bin/hermes-assistant-wrapper.sh\" \"${ACTION}\""

echo "run-as-hermes-privileged: action=${ACTION} forward=${#forward_env[@]} secret(s)" >&2
exec runuser -u "$TARGET_USER" -- env "${hermes_env[@]}" bash -c "$wrapper_inner"
