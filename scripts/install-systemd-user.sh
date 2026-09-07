#!/bin/bash
# Install user-level systemd unit for bucephalus3 (direct Podman, no hermes user).
#
#   bash ~/hermes-assistant/scripts/install-systemd-user.sh
#
# Then:
#   systemctl --user enable --now hermes-assistant-gateway.service
#   systemctl --user restart hermes-assistant-gateway.service
#
# Rebuild image (rare, slow): ~/hermes-assistant/scripts/hermes-assistant-wrapper.sh recreate

set -euo pipefail

ASSISTANT_ROOT="${HERMES_ASSISTANT_ROOT:-$HOME/hermes-assistant}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="hermes-assistant-gateway.service"

mkdir -p "$UNIT_DIR"

src="${ASSISTANT_ROOT}/systemd/${UNIT}"
[[ -f "$src" ]] || { echo "Missing ${src}" >&2; exit 1; }
install -m 0644 "$src" "${UNIT_DIR}/${UNIT}"
echo "Installed ${UNIT_DIR}/${UNIT}"

# Drop the old two-service layout if present.
if [[ -f "${UNIT_DIR}/hermes-assistant-recreate.service" ]]; then
  systemctl --user disable hermes-assistant-recreate.service 2>/dev/null || true
  rm -f "${UNIT_DIR}/hermes-assistant-recreate.service"
  echo "Removed ${UNIT_DIR}/hermes-assistant-recreate.service"
fi

mkdir -p "${HOME}/bin"
ln -sfn "${ASSISTANT_ROOT}/scripts/hermes-assistant-wrapper.sh" \
  "${HOME}/bin/hermes-assistant-wrapper.sh"

systemctl --user daemon-reload
echo ""
echo "OK. Common commands:"
echo "  systemctl --user enable --now hermes-assistant-gateway.service"
echo "  systemctl --user restart hermes-assistant-gateway.service"
echo "  journalctl --user -u hermes-assistant-gateway.service -f"
echo ""
echo "Rebuild after upstream changes (manual, not systemd):"
echo "  ~/hermes-assistant/scripts/hermes-assistant-wrapper.sh recreate"
echo ""
echo "Secrets: export allowlisted names in ~/.bashrc (see config/env.allowlist)."
