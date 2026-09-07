#!/bin/bash
# Migrate Hermes Assistant from bucephalus3 to dedicated user hermes.
# Usage: sudo bash /home/bucephalus3/hermes-assistant/scripts/migrate-to-hermes-user.sh

set -euo pipefail

SOURCE_USER="bucephalus3"
SOURCE_HOME="/home/${SOURCE_USER}"
TARGET_USER="hermes"
TARGET_HOME="/home/${TARGET_USER}"
SOURCE_BUILD_CONTEXT="${SOURCE_HOME}/0_Development/hermes-agent"
BUILD_CONTEXT="${TARGET_HOME}/hermes-agent"
ASSISTANT_SRC="${SOURCE_HOME}/hermes-assistant"
LOG="/tmp/hermes-migrate-$(date +%Y%m%d%H%M%S).log"

exec > >(tee -a "$LOG") 2>&1
log() { printf '[migrate] %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must run as root. Run:" >&2
  echo "  sudo bash $0" >&2
  exit 1
fi

log "Log file: $LOG"

if ! id "${TARGET_USER}" &>/dev/null; then
  log "Creating user ${TARGET_USER}"
  useradd -m -s /bin/bash -U "${TARGET_USER}"
else
  log "User ${TARGET_USER} already exists"
fi

TARGET_UID="$(id -u "${TARGET_USER}")"
TARGET_GID="$(id -g "${TARGET_USER}")"
log "hermes uid=${TARGET_UID} gid=${TARGET_GID}"

log "Stopping hermes-assistant containers (source user, if any)"
if [[ -d "${ASSISTANT_SRC}" ]]; then
  sudo -u "${SOURCE_USER}" bash -c "
    set -euo pipefail
    export PATH=\"/usr/bin:/bin:\$HOME/.local/bin:\$PATH\"
    if [[ -f '${ASSISTANT_SRC}/scripts/container-runtime.sh' ]]; then
      # shellcheck source=/dev/null
      source '${ASSISTANT_SRC}/scripts/container-runtime.sh'
      cd '${ASSISTANT_SRC}'
      \$HERMES_COMPOSE down 2>/dev/null || true
    fi
  " || true
fi

log "Copying deployment to ${TARGET_HOME}"
install -d -o "${TARGET_USER}" -g "${TARGET_USER}" -m 0750 "${TARGET_HOME}"
for item in hermes-assistant .hermes-assistant hermes-workspace; do
  if [[ -e "${SOURCE_HOME}/${item}" ]]; then
    rsync -a "${SOURCE_HOME}/${item}/" "${TARGET_HOME}/${item}/"
  fi
done
chmod +x "${TARGET_HOME}/hermes-assistant/scripts/"*.sh 2>/dev/null || true

COMPOSE="${TARGET_HOME}/hermes-assistant/docker-compose.yml"
if [[ -f "$COMPOSE" ]]; then
  log "Updating docker-compose.yml paths for ${TARGET_USER}"
  sed -i \
    -e "s|/home/bucephalus3/.hermes-assistant|/home/hermes/.hermes-assistant|g" \
    -e "s|/home/bucephalus3/hermes-workspace|/home/hermes/hermes-workspace|g" \
    -e "s|context: /home/bucephalus3/0_Development/hermes-agent|context: \${HERMES_BUILD_CONTEXT:-/home/hermes/hermes-agent}|g" \
    "$COMPOSE"
fi

log "Syncing hermes-agent build context into ${TARGET_HOME} (rootless Podman cannot read ${SOURCE_HOME})"
HERMES_REPO_SRC="${SOURCE_BUILD_CONTEXT}" HERMES_BUILD_CONTEXT="${BUILD_CONTEXT}" \
  bash "${ASSISTANT_SRC}/scripts/prepare-build-context.sh"

log "Ownership and permissions"
chown -R "${TARGET_USER}:${TARGET_USER}" \
  "${TARGET_HOME}/hermes-assistant" \
  "${TARGET_HOME}/.hermes-assistant" \
  "${TARGET_HOME}/hermes-workspace"
chmod 755 "${TARGET_HOME}"
chmod 700 "${TARGET_HOME}/.hermes-assistant"
chmod 600 "${TARGET_HOME}/.hermes-assistant/env.allowlist" 2>/dev/null || true
chmod 600 "${TARGET_HOME}/.hermes-assistant/compose.runtime.yml" 2>/dev/null || true

if getent group docker >/dev/null; then
  log "Adding ${TARGET_USER} to docker group"
  usermod -aG docker "${TARGET_USER}"
else
  log "No docker group; configuring rootless podman for ${TARGET_USER}"
  loginctl enable-linger "${TARGET_USER}" || true
fi

if command -v podman >/dev/null && ! getent group docker >/dev/null; then
  loginctl enable-linger "${TARGET_USER}" || true
fi

# Login-shell PATH from a user who already runs podman (often not in sudo's minimal PATH).
SOURCE_PATH="$(sudo -u "${SOURCE_USER}" bash -lc 'printf %s "$PATH"' 2>/dev/null || true)"
if [[ -z "${SOURCE_PATH}" ]]; then
  SOURCE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi
log "Using PATH from ${SOURCE_USER} for container CLI discovery"

log "Initializing rootless podman for ${TARGET_USER} (first login)"
sudo -u "${TARGET_USER}" bash -lc 'podman info >/dev/null 2>&1 || true' || true

# Pin container CLI if discoverable from source user's environment.
HERMES_CONTAINER_CLI=""
HERMES_COMPOSE=""
if sudo -u "${SOURCE_USER}" bash -lc 'podman compose version' >/dev/null 2>&1; then
  HERMES_CONTAINER_CLI="podman"
  HERMES_COMPOSE="podman compose"
elif sudo -u "${SOURCE_USER}" bash -lc 'podman-compose version' >/dev/null 2>&1; then
  HERMES_CONTAINER_CLI="podman"
  HERMES_COMPOSE="podman-compose"
elif sudo -u "${SOURCE_USER}" bash -lc 'docker compose version' >/dev/null 2>&1; then
  HERMES_CONTAINER_CLI="docker"
  HERMES_COMPOSE="docker compose"
fi
if [[ -n "${HERMES_COMPOSE}" ]]; then
  log "Detected compose: ${HERMES_COMPOSE}"
else
  log "WARN: could not detect compose from ${SOURCE_USER}; bootstrap will auto-detect"
fi

log "Bootstrap as ${TARGET_USER}"
sudo -u "${TARGET_USER}" env \
  HOME="${TARGET_HOME}" \
  HERMES_ASSISTANT_ROOT="${TARGET_HOME}/hermes-assistant" \
  HERMES_DATA_DIR="${TARGET_HOME}/.hermes-assistant" \
  HERMES_WORKSPACE_DIR="${TARGET_HOME}/hermes-workspace" \
  HERMES_BUILD_CONTEXT="${BUILD_CONTEXT}" \
  HERMES_REPO="${BUILD_CONTEXT}" \
  HERMES_CONTAINER_CLI="${HERMES_CONTAINER_CLI}" \
  HERMES_COMPOSE="${HERMES_COMPOSE}" \
  PATH="${SOURCE_PATH}" \
  bash "${TARGET_HOME}/hermes-assistant/scripts/bootstrap.sh"

log "Disabling ${SOURCE_USER} systemd unit"
sudo -u "${SOURCE_USER}" systemctl --user disable hermes-assistant-gateway.service 2>/dev/null || true
sudo -u "${SOURCE_USER}" systemctl --user stop hermes-assistant-gateway.service 2>/dev/null || true
rm -f "${SOURCE_HOME}/.config/systemd/user/hermes-assistant-gateway.service"
sudo -u "${SOURCE_USER}" systemctl --user daemon-reload 2>/dev/null || true

NOTE_BIN='#!/bin/bash
echo "Hermes Assistant runs as user hermes." >&2
echo "  su - hermes -c '\''hermes-assistant chat'\''" >&2
echo "  su - hermes -c '\''hermes-assistant-wrapper.sh status'\''" >&2
exit 1
'
for b in hermes-assistant hermes-assistant-wrapper.sh; do
  if [[ -f "${SOURCE_HOME}/bin/${b}" ]]; then
    mv "${SOURCE_HOME}/bin/${b}" "${SOURCE_HOME}/bin/${b}.migrated-$(date +%Y%m%d)" 2>/dev/null || true
  fi
  printf '%s\n' "$NOTE_BIN" > "${SOURCE_HOME}/bin/${b}"
  chmod 755 "${SOURCE_HOME}/bin/${b}"
  chown "${SOURCE_USER}:${SOURCE_USER}" "${SOURCE_HOME}/bin/${b}"
done

log "Removing migrated trees from ${SOURCE_HOME} (backup names)"
ts="$(date +%Y%m%d%H%M%S)"
for item in hermes-assistant .hermes-assistant hermes-workspace; do
  if [[ -e "${SOURCE_HOME}/${item}" ]]; then
    mv "${SOURCE_HOME}/${item}" "${SOURCE_HOME}/${item}.migrated-${ts}"
  fi
done

log "Container status as hermes:"
sudo -u "${TARGET_USER}" env HOME="${TARGET_HOME}" PATH="${SOURCE_PATH}" \
  bash "${TARGET_HOME}/bin/hermes-assistant-wrapper.sh" status || true

log "Done. hermes uid=${TARGET_UID} gid=${TARGET_GID}"
