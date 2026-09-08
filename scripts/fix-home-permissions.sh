#!/bin/bash
# Fix /home/hermes permissions after migrate (run with sudo).
# - /home/hermes: 755 (listable; secrets stay behind 700 .hermes-assistant)
# - .hermes-assistant: 700 (hermes-only traverse)
# - hermes-workspace: 750 (hermes + group; not world-listable)
#
# SECURITY: always invoke the operator kit copy — never the deployed tree:
#   sudo bash /home/bucephalus3/hermes-assistant/scripts/fix-home-permissions.sh
# After chown -R hermes, scripts under /home/hermes are hermes-writable; running
# those as root is arbitrary code execution as root.

set -euo pipefail

TARGET_HOME="/home/hermes"
TARGET_USER="hermes"
OPERATOR_KIT="${HERMES_OPERATOR_KIT:-/home/bucephalus3/hermes-assistant}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo bash ${OPERATOR_KIT}/scripts/fix-home-permissions.sh" >&2
  exit 1
fi

# Refuse hermes-writable / deployed copies. Root must run the trusted kit path.
SELF="$(realpath -e "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"
case "$SELF" in
  "${OPERATOR_KIT}/scripts/"*)
    ;;
  *)
    echo "ERROR: refusing to run as root from untrusted path:" >&2
    echo "  ${SELF}" >&2
    echo "Run the operator kit copy instead:" >&2
    echo "  sudo bash ${OPERATOR_KIT}/scripts/fix-home-permissions.sh" >&2
    exit 1
    ;;
esac

if [[ ! -d "$TARGET_HOME" ]]; then
  echo "Missing $TARGET_HOME — run migrate first." >&2
  exit 1
fi

if ! id "$TARGET_USER" &>/dev/null; then
  echo "Missing user ${TARGET_USER} — run migrate first." >&2
  exit 1
fi

# True if PATH is a regular file (not symlink) whose realpath stays under ROOT/.
hermes_safe_under() {
  local path="$1"
  local root="$2"
  local real
  [[ -e "$path" ]] || return 1
  [[ ! -L "$path" ]] || return 1
  [[ -f "$path" || -d "$path" ]] || return 1
  real="$(realpath -e "$path")" || return 1
  case "$real" in
    "${root}"|"${root}"/*) printf '%s\n' "$real"; return 0 ;;
    *) return 1 ;;
  esac
}

# Safe recursive delete: refuse symlinks; require realpath under ALLOWED_ROOT.
hermes_rm_rf_under() {
  local path="$1"
  local allowed_root="$2"
  local real
  [[ -e "$path" ]] || return 0
  if [[ -L "$path" ]]; then
    echo "WARN: refusing to delete symlink ${path}" >&2
    return 1
  fi
  real="$(hermes_safe_under "$path" "$allowed_root")" || {
    echo "WARN: refusing to delete outside ${allowed_root}: ${path}" >&2
    return 1
  }
  rm -rf -- "$real"
}

# Edit a hermes-owned config without following symlinks (temp + rename).
hermes_safe_sed_replace() {
  local path="$1"
  local root="$2"
  local from="$3"
  local to="$4"
  local real tmp
  real="$(hermes_safe_under "$path" "$root")" || {
    echo "WARN: skip unsafe config path ${path}" >&2
    return 1
  }
  tmp="$(mktemp "${real}.XXXXXX")"
  # shellcheck disable=SC2094
  if ! sed "s|${from}|${to}|" <"$real" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chown --reference="$real" "$tmp" 2>/dev/null || chown "${TARGET_USER}:${TARGET_USER}" "$tmp"
  chmod --reference="$real" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv -f -- "$tmp" "$real"
}

chmod 755 "$TARGET_HOME"
mkdir -p "${TARGET_HOME}/hermes-workspace"

# Nested duplicate from a bad migrate — delete only if safely under workspace.
hermes_rm_rf_under \
  "${TARGET_HOME}/hermes-workspace/hermes-workspace" \
  "${TARGET_HOME}/hermes-workspace" || true

[[ -d "${TARGET_HOME}/.hermes-assistant" ]] && chmod 700 "${TARGET_HOME}/.hermes-assistant"
# 750: hermes (+ group) only — not world-listable
[[ -d "${TARGET_HOME}/hermes-workspace" ]] && chmod 750 "${TARGET_HOME}/hermes-workspace"
[[ -f "${TARGET_HOME}/.hermes-assistant/env.allowlist" && ! -L "${TARGET_HOME}/.hermes-assistant/env.allowlist" ]] \
  && chmod 600 "${TARGET_HOME}/.hermes-assistant/env.allowlist"
[[ -f "${TARGET_HOME}/hermes-assistant/compose.runtime.yml" && ! -L "${TARGET_HOME}/hermes-assistant/compose.runtime.yml" ]] \
  && chmod 600 "${TARGET_HOME}/hermes-assistant/compose.runtime.yml"

# GNU chown -R does not follow symlinks by default (-P).
chown -R "${TARGET_USER}:${TARGET_USER}" "$TARGET_HOME"

# Re-harden root-only admin scripts so hermes cannot rewrite sudo entrypoints.
ADMIN_SCRIPTS=(
  fix-home-permissions.sh
  fix-rootless-data-ownership.sh
  prepare-build-context.sh
  migrate-to-hermes-user.sh
)
SCRIPTS_DIR="${TARGET_HOME}/hermes-assistant/scripts"
if [[ -d "$SCRIPTS_DIR" ]]; then
  for name in "${ADMIN_SCRIPTS[@]}"; do
    dest="${SCRIPTS_DIR}/${name}"
    src="${OPERATOR_KIT}/scripts/${name}"
    if [[ -f "$src" ]]; then
      install -o root -g root -m 0755 "$src" "$dest"
    elif [[ -f "$dest" && ! -L "$dest" ]]; then
      chown root:root "$dest"
      chmod 0755 "$dest"
    fi
  done
fi

# Fix files created as root during earlier rootless runs.
if [[ -d "${TARGET_HOME}/.hermes-assistant" ]]; then
  find "${TARGET_HOME}/.hermes-assistant" -user root -exec chown "${TARGET_USER}:${TARGET_USER}" {} + 2>/dev/null || true
  # Tighten common secret-bearing regular files (skip symlinks).
  find "${TARGET_HOME}/.hermes-assistant" -type f ! -type l \( \
      -name 'config.yaml' -o -name '.env' -o -name '.env.*' \
      -o -name 'auth.json' -o -name 'gateway_state.json' \
      -o -name 'credentials.json' -o -name '*.pem' -o -name '*.key' \
      -o -name 'env.allowlist' \
    \) -exec chmod 600 {} + 2>/dev/null || true
fi
if [[ -d "${TARGET_HOME}/hermes-workspace" ]]; then
  find "${TARGET_HOME}/hermes-workspace" -user root -exec chown "${TARGET_USER}:${TARGET_USER}" {} + 2>/dev/null || true
fi

for cfg in \
  "${TARGET_HOME}/.hermes-assistant/config.yaml" \
  "${TARGET_HOME}/hermes-assistant/config/config.yaml"; do
  if [[ -f "$cfg" ]] && [[ ! -L "$cfg" ]] && grep -qE 'cwd: /workspace$' "$cfg"; then
    if hermes_safe_sed_replace "$cfg" "$TARGET_HOME" 'cwd: /workspace' 'cwd: /opt/data/workspace'; then
      echo "OK: updated ${cfg} cwd -> /opt/data/workspace"
    fi
  fi
done

echo "OK: ${TARGET_HOME} is 755 (listable; secrets behind 700 .hermes-assistant)"
echo "OK: ${TARGET_HOME}/.hermes-assistant is 700 (hermes + root only)"
echo "OK: ${TARGET_HOME}/hermes-workspace is 750 (not world-listable)"
echo "OK: admin scripts under hermes-assistant/scripts are root:root 0755"
echo ""
echo "Rootless Podman: remapping bind-mount ownership for container uid..."
if command -v podman &>/dev/null; then
  KIT_ROOTLESS="${OPERATOR_KIT}/scripts/fix-rootless-data-ownership.sh"
  DEPLOYED_ROOTLESS="${SCRIPTS_DIR}/fix-rootless-data-ownership.sh"
  # Install root-owned copy hermes can execute but not modify, then run as hermes.
  if [[ -f "$KIT_ROOTLESS" ]]; then
    mkdir -p "$SCRIPTS_DIR"
    install -o root -g root -m 0755 "$KIT_ROOTLESS" "$DEPLOYED_ROOTLESS"
  fi
  if [[ -f "$DEPLOYED_ROOTLESS" ]]; then
    # Clear HERMES_OPERATOR_KIT so the deployed script does not re-exec via sudo
    # looking for the kit (already root-owned and trusted).
    # cd into TARGET_HOME: operator cwd under /home/bucephalus3 is unreadable to
    # hermes and makes `podman unshare` fail with "cannot chdir ... Permission denied".
    sudo -u "$TARGET_USER" -H env -u HERMES_OPERATOR_KIT bash -c \
      'cd "$1" && exec bash "$2"' _ "$TARGET_HOME" "$DEPLOYED_ROOTLESS" \
      || echo "WARN: fix-rootless-data-ownership.sh failed"
  else
    echo "WARN: missing ${DEPLOYED_ROOTLESS} — run: sudo bash ${KIT_ROOTLESS}"
  fi
fi
