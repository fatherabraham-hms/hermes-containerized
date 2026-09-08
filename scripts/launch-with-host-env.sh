#!/bin/bash
# Run the hermes wrapper as user hermes, forwarding allowlisted credentials.
#
# Run as bucephalus3 (your account), NOT as hermes / root.
#
# Interactive:
#   source ~/.bashrc
#   ~/hermes-assistant/scripts/launch-with-host-env.sh start
#
# Systemd / non-interactive:
#   Keys come from config/env.secrets (see install-autostart.sh).
#   Uses passwordless sudo → /usr/local/sbin/hermes-assistant-privileged.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSISTANT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=export-allowlisted-env.sh
source "${ASSISTANT_ROOT}/scripts/export-allowlisted-env.sh"

TARGET_USER="${HERMES_TARGET_USER:-hermes}"
TARGET_HOME="${HERMES_TARGET_HOME:-/home/${TARGET_USER}}"
TARGET_ASSISTANT="${TARGET_HOME}/hermes-assistant"
ACTION="${1:-start}"
OPERATOR_ALLOWLIST="${ASSISTANT_ROOT}/config/env.allowlist"
OPERATOR_SECRETS="${ASSISTANT_ROOT}/config/env.secrets"
HERMES_ALLOWLIST="${TARGET_HOME}/.hermes-assistant/env.allowlist"
OPERATOR_USER="${HERMES_OPERATOR_USER:-bucephalus3}"
SBIN_HELPER="${HERMES_PRIVILEGED_HELPER:-/usr/local/sbin/hermes-assistant-privileged.sh}"
KIT_HELPER="${ASSISTANT_ROOT}/scripts/run-as-hermes-privileged.sh"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Run as ${OPERATOR_USER} (not root)." >&2
  exit 1
fi

if [[ "$(id -un)" == "${TARGET_USER}" ]]; then
  echo "Run this as ${OPERATOR_USER}, not as ${TARGET_USER}." >&2
  echo "  ${TARGET_HOME}/bin/hermes-assistant-wrapper.sh ${ACTION}" >&2
  exit 1
fi

if ! id "$TARGET_USER" &>/dev/null; then
  echo "User ${TARGET_USER} does not exist." >&2
  exit 1
fi

if [[ ! -d "$TARGET_ASSISTANT" ]]; then
  echo "ERROR: missing ${TARGET_ASSISTANT}" >&2
  exit 1
fi

# Fill missing allowlisted vars from env.secrets (systemd has no ~/.bashrc).
hermes_load_env_secrets() {
  local secrets="$1"
  [[ -f "$secrets" ]] || return 0
  local line key val
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
  done < "$secrets"
}

hermes_load_env_secrets "$OPERATOR_SECRETS"

ALLOWLIST=""
if [[ -f "$OPERATOR_ALLOWLIST" ]]; then
  ALLOWLIST="$OPERATOR_ALLOWLIST"
elif [[ -f "${TARGET_ASSISTANT}/config/env.allowlist" ]]; then
  ALLOWLIST="${TARGET_ASSISTANT}/config/env.allowlist"
elif [[ -r "$HERMES_ALLOWLIST" ]]; then
  ALLOWLIST="$HERMES_ALLOWLIST"
fi

mapfile -t names < <(hermes_read_allowlist_names "$ALLOWLIST" || true)
preserve=()
missing=()
for name in "${names[@]}"; do
  if [[ -n "${!name-}" ]]; then
    export "$name"
    preserve+=("$name")
  else
    missing+=("$name")
  fi
done

if ((${#names[@]})); then
  echo "Read ${#names[@]} name(s) from ${ALLOWLIST}." >&2
fi

if ((${#preserve[@]})); then
  echo "Forwarding ${#preserve[@]} allowlisted var(s) into hermes." >&2
elif ((${#names[@]})); then
  echo "WARN: allowlist names found but none are set." >&2
  echo "  Interactive: source ~/.bashrc && retry" >&2
  echo "  Autostart:   edit ${OPERATOR_SECRETS} (see env.secrets.example)" >&2
  printf '  Missing:' >&2
  for name in "${missing[@]}"; do printf ' %s' "$name" >&2; done
  printf '\n' >&2
fi

# Systemd NOPASSWD must target /usr/local/sbin (root:root), not a user-writable kit path.
if [[ "${HERMES_SYSTEMD:-}" == "1" || "${HERMES_NONINTERACTIVE:-}" == "1" ]]; then
  if [[ ! -x "$SBIN_HELPER" ]]; then
    echo "ERROR: missing ${SBIN_HELPER}" >&2
    echo "  Run: sudo bash ${ASSISTANT_ROOT}/scripts/install-autostart.sh" >&2
    echo "  (installs /usr/local/sbin/hermes-assistant-privileged.sh for NOPASSWD sudo)" >&2
    exit 1
  fi
  exec sudo -n "$SBIN_HELPER" "$ACTION"
fi

if [[ -x "$SBIN_HELPER" ]] && sudo -n true 2>/dev/null; then
  exec sudo -n "$SBIN_HELPER" "$ACTION"
fi

# --- Legacy interactive path (sudo → root → runuser) ---
TARGET_UID="$(id -u "$TARGET_USER")"
RUNTIME_DIR="/run/user/${TARGET_UID}"
HERMES_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${TARGET_HOME}/bin"

HERMES_CONTAINER_CLI="podman"
HERMES_COMPOSE=""
if command -v podman-compose >/dev/null 2>&1; then
  HERMES_COMPOSE="podman-compose"
elif bash -lc 'podman compose version' >/dev/null 2>&1; then
  HERMES_COMPOSE="podman compose"
else
  echo "ERROR: podman-compose or podman compose not found" >&2
  exit 1
fi

sudo_preserve=()
if ((${#preserve[@]})); then
  preserve_csv="$(IFS=,; echo "${preserve[*]}")"
  sudo_preserve=(--preserve-env="$preserve_csv")
fi

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
)

wrapper_inner="cd \"${TARGET_ASSISTANT}\" && exec \"${TARGET_HOME}/bin/hermes-assistant-wrapper.sh\" \"${ACTION}\""

can_sudo_root() {
  sudo -u root -n true 2>/dev/null
}

sync_deployed_tree() {
  if [[ "$ASSISTANT_ROOT" == "$TARGET_ASSISTANT" ]]; then
    return 0
  fi
  local script
  local -a admin_scripts=(
    fix-home-permissions.sh
    fix-rootless-data-ownership.sh
    prepare-build-context.sh
    migrate-to-hermes-user.sh
  )
  is_admin_script() {
    local s="$1" a
    for a in "${admin_scripts[@]}"; do
      [[ "$s" == "$a" ]] && return 0
    done
    return 1
  }
  for script in verify-isolation.sh run-verify.sh hermes-podman.sh fix-home-permissions.sh \
    fix-rootless-data-ownership.sh hermes-assistant-wrapper.sh hermes-assistant-cli.sh \
    export-allowlisted-env.sh container-runtime.sh launch-with-host-env.sh \
    prepare-build-context.sh migrate-to-hermes-user.sh \
    hermes-agent-pin.sh update-hermes-agent-pin.sh; do
    [[ -f "${ASSISTANT_ROOT}/scripts/${script}" ]] || continue
    if is_admin_script "$script"; then
      install -o root -g root -m 0755 \
        "${ASSISTANT_ROOT}/scripts/${script}" "${TARGET_ASSISTANT}/scripts/${script}"
    else
      install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
        "${ASSISTANT_ROOT}/scripts/${script}" "${TARGET_ASSISTANT}/scripts/${script}"
    fi
  done
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "${ASSISTANT_ROOT}/scripts/hermes-assistant-wrapper.sh" "${TARGET_HOME}/bin/hermes-assistant-wrapper.sh"
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
    "${ASSISTANT_ROOT}/scripts/hermes-assistant-cli.sh" "${TARGET_HOME}/bin/hermes-assistant"
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
    "${ASSISTANT_ROOT}/docker-compose.yml" "${TARGET_ASSISTANT}/docker-compose.yml"
  if [[ -f "${ASSISTANT_ROOT}/hermes-agent.lock" ]]; then
    install -o "$TARGET_USER" -g "$TARGET_USER" -m 0644 \
      "${ASSISTANT_ROOT}/hermes-agent.lock" "${TARGET_ASSISTANT}/hermes-agent.lock"
  fi
  if [[ -f "$OPERATOR_ALLOWLIST" ]]; then
    mkdir -p "${TARGET_ASSISTANT}/config"
    install -o "$TARGET_USER" -g "$TARGET_USER" -m 644 \
      "$OPERATOR_ALLOWLIST" "${TARGET_ASSISTANT}/config/env.allowlist"
    install -o "$TARGET_USER" -g "$TARGET_USER" -m 600 \
      "$OPERATOR_ALLOWLIST" "$HERMES_ALLOWLIST"
  fi
  if [[ ! -d "$RUNTIME_DIR" ]]; then
    loginctl enable-linger "$TARGET_USER" 2>/dev/null || true
  fi
}

if can_sudo_root; then
  echo "Using sudo → root → runuser ${TARGET_USER} (enter YOUR password)." >&2
  # Prefer sbin helper; fall back to kit copy for interactive sudo.
  PRIVILEGED="$SBIN_HELPER"
  if [[ ! -x "$PRIVILEGED" ]]; then
    PRIVILEGED="$KIT_HELPER"
  fi
  if [[ -x "$PRIVILEGED" ]]; then
    exec sudo "${sudo_preserve[@]}" "$PRIVILEGED" "$ACTION"
  fi
  # shellcheck disable=SC2016
  sudo "${sudo_preserve[@]}" bash -c "$(declare -f sync_deployed_tree); sync_deployed_tree; exec runuser -u \"${TARGET_USER}\" -- env $(printf '%q ' "${hermes_env[@]}") bash -c $(printf '%q' "$wrapper_inner")"
  exit 0
fi

echo "Using sudo → ${TARGET_USER} (enter ${TARGET_USER}'s password if asked)." >&2
echo "For autostart, run: sudo bash ${ASSISTANT_ROOT}/scripts/install-autostart.sh" >&2

exec sudo "${sudo_preserve[@]}" -u "$TARGET_USER" \
  env "${hermes_env[@]}" bash -c "$wrapper_inner"
