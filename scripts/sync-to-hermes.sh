#!/bin/bash
# One-shot sync operator kit → /home/hermes (run with YOUR sudo / root password).
#   sudo bash ~/hermes-assistant/scripts/sync-to-hermes.sh
#
# Admin scripts (sudo entrypoints) install as root:root 0755 so hermes cannot
# rewrite them. Always invoke those from the kit path when running as root:
#   sudo bash ~/hermes-assistant/scripts/fix-home-permissions.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run: sudo bash $0" >&2
  exit 1
fi

KIT="${HERMES_OPERATOR_KIT:-/home/bucephalus3/hermes-assistant}"
TARGET_HOME="/home/hermes"
TARGET="${TARGET_HOME}/hermes-assistant"

[[ -d "$KIT" ]] || { echo "Missing kit: $KIT" >&2; exit 1; }
[[ -d "$TARGET" ]] || { echo "Missing $TARGET — migrate first." >&2; exit 1; }

# Executable by hermes; not rewritable into a root RCE.
ADMIN_SCRIPTS=(
  fix-home-permissions.sh
  fix-rootless-data-ownership.sh
  prepare-build-context.sh
  migrate-to-hermes-user.sh
)

is_admin_script() {
  local s="$1"
  local a
  for a in "${ADMIN_SCRIPTS[@]}"; do
    [[ "$s" == "$a" ]] && return 0
  done
  return 1
}

for script in verify-isolation.sh run-verify.sh hermes-podman.sh fix-home-permissions.sh \
  fix-rootless-data-ownership.sh hermes-assistant-wrapper.sh hermes-assistant-cli.sh \
  export-allowlisted-env.sh container-runtime.sh launch-with-host-env.sh \
  prepare-build-context.sh migrate-to-hermes-user.sh run-as-hermes-privileged.sh \
  install-autostart.sh hermes-agent-pin.sh update-hermes-agent-pin.sh; do
  [[ -f "${KIT}/scripts/${script}" ]] || continue
  if is_admin_script "$script" || [[ "$script" == "run-as-hermes-privileged.sh" ]]; then
    install -o root -g root -m 0755 "${KIT}/scripts/${script}" "${TARGET}/scripts/${script}"
  else
    install -o hermes -g hermes -m 0755 "${KIT}/scripts/${script}" "${TARGET}/scripts/${script}"
  fi
done

install -o hermes -g hermes -m 0755 "${KIT}/scripts/hermes-assistant-wrapper.sh" "${TARGET_HOME}/bin/hermes-assistant-wrapper.sh"
install -o hermes -g hermes -m 0755 "${KIT}/scripts/hermes-assistant-cli.sh" "${TARGET_HOME}/bin/hermes-assistant"
install -o hermes -g hermes -m 0644 "${KIT}/docker-compose.yml" "${TARGET}/docker-compose.yml"
if [[ -f "${KIT}/hermes-agent.lock" ]]; then
  install -o hermes -g hermes -m 0644 "${KIT}/hermes-agent.lock" "${TARGET}/hermes-agent.lock"
fi

if [[ -f "${KIT}/config/env.allowlist" ]]; then
  mkdir -p "${TARGET}/config"
  install -o hermes -g hermes -m 644 "${KIT}/config/env.allowlist" "${TARGET}/config/env.allowlist"
  install -o hermes -g hermes -m 600 "${KIT}/config/env.allowlist" "${TARGET_HOME}/.hermes-assistant/env.allowlist"
fi

echo "OK: synced ${KIT} → ${TARGET_HOME}"
echo "OK: admin scripts are root:root 0755 (run via kit path with sudo)"
