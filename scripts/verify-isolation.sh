#!/bin/bash
# Isolation + persistence checks — run on the HOST, not inside the container.

set -euo pipefail

if [[ -f /run/.containerenv ]] || [[ -f /.dockerenv ]]; then
  echo "ERROR: run this on the host, not via podman exec." >&2
  echo "  sudo -u hermes bash /home/hermes/hermes-assistant/scripts/verify-isolation.sh" >&2
  echo "  ~/hermes-assistant/scripts/run-verify.sh" >&2
  exit 1
fi

ASSISTANT_ROOT="${HERMES_ASSISTANT_ROOT:-$HOME/hermes-assistant}"
# Default to the operator running this script (bucephalus3 direct layout).
# Set HERMES_TARGET_USER=hermes when verifying the hermes-user install.
TARGET_USER="${HERMES_TARGET_USER:-$(id -un)}"
TARGET_HOME="${HERMES_TARGET_HOME:-$HOME}"
HERMES_DATA="${HERMES_DATA_DIR:-${TARGET_HOME}/.hermes-assistant}"
HERMES_WORKSPACE="${HERMES_WORKSPACE_DIR:-${TARGET_HOME}/hermes-workspace}"
ADMIN_HOME="${HERMES_ADMIN_HOME:-/home/bucephalus3}"
CONTAINER="${HERMES_ASSISTANT_CONTAINER:-hermes-assistant}"
FAIL=0
if [[ -d "$HERMES_DATA" && -x "$HERMES_DATA" ]]; then
  HERMES_DATA="$(cd "$HERMES_DATA" && pwd -P)"
fi
if [[ -d "$HERMES_WORKSPACE" && -x "$HERMES_WORKSPACE" ]]; then
  HERMES_WORKSPACE="$(cd "$HERMES_WORKSPACE" && pwd -P)"
fi

cd "$ASSISTANT_ROOT"

# shellcheck source=container-runtime.sh
source "${ASSISTANT_ROOT}/scripts/container-runtime.sh"

hermes_podman() {
  # Prefer the caller's rootless podman when the container is visible there
  # (bucephalus3 direct install). Fall back to hermes-podman.sh for the
  # operator→hermes delegated layout.
  if podman inspect "$CONTAINER" >/dev/null 2>&1; then
    podman "$@"
  elif [[ "$(id -un)" == "${TARGET_USER}" ]]; then
    podman "$@"
  else
    "${ASSISTANT_ROOT}/scripts/hermes-podman.sh" "$@"
  fi
}

hermes_exec() {
  hermes_podman exec --user hermes "$CONTAINER" "$@"
}

check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    FAIL=1
  fi
}

check_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s (expected %q, got %q)\n' "$name" "$expected" "$actual"
    FAIL=1
  fi
}

check_no_char() {
  local name="$1" value="$2" char="$3"
  case "$value" in
    *"$char"*) printf 'FAIL  %s\n' "$name"; FAIL=1 ;;
    *) printf 'PASS  %s\n' "$name" ;;
  esac
}

mount_source() {
  local dest="$1"
  hermes_podman inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "'"$dest"'"}}{{.Source}}{{end}}{{end}}' 2>/dev/null
}

mount_type() {
  local dest="$1"
  hermes_podman inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "'"$dest"'"}}{{.Type}}{{end}}{{end}}' 2>/dev/null
}

echo "Hermes verification (host)"
echo "  container:  ${CONTAINER}"
echo "  data dir:   ${HERMES_DATA}"
echo "  workspace:  ${HERMES_WORKSPACE}"
echo ""

if ! hermes_podman inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "FAIL  container ${CONTAINER} is not running — start the stack first." >&2
  exit 1
fi

opt_data_src="$(mount_source /opt/data)"
workspace_src="$(mount_source /opt/data/workspace)"
opt_data_type="$(mount_type /opt/data)"
workspace_type="$(mount_type /opt/data/workspace)"

check_eq "/opt/data bind mount" "$HERMES_DATA" "$opt_data_src"
check_eq "workspace bind mount (/opt/data/workspace)" "$HERMES_WORKSPACE" "$workspace_src"
check_eq "/opt/data mount type is bind" "bind" "$opt_data_type"
check_eq "workspace mount type is bind" "bind" "$workspace_type"
check_no_char "/opt/data mount has no compose typo (no trailing })" "$opt_data_src" '}'
check_no_char "workspace mount has no compose typo (no trailing })" "$workspace_src" '}'

check "HERMES_HOME is /opt/data in container" \
  hermes_exec sh -c '[ "$HERMES_HOME" = /opt/data ]'

check "config.yaml on data volume" \
  hermes_exec test -f /opt/data/config.yaml

MARKER=".hermes-mount-test-$$"
check "data volume round-trip write" \
  hermes_exec sh -c "echo ok > /opt/data/${MARKER}"
check "data volume round-trip readback" \
  hermes_exec grep -q ok "/opt/data/${MARKER}"
hermes_exec rm -f "/opt/data/${MARKER}" 2>/dev/null || true

# Host→container: a file on the host bind is readable at /opt/data.
# Rootless remap often makes the host dir unwritable from this uid; then
# bind Source/Type (above) is the persistence proof. This check does not
# recreate the container — see README recreate smoke.
HOST_MARKER=".hermes-host-reload-test-$$"
if [[ -w "$HERMES_DATA" ]]; then
  printf 'reload-ok\n' > "${HERMES_DATA}/${HOST_MARKER}"
  chmod 644 "${HERMES_DATA}/${HOST_MARKER}" 2>/dev/null || true
  check "host bind file readable at /opt/data" \
    hermes_exec grep -q reload-ok "/opt/data/${HOST_MARKER}"
  rm -f "${HERMES_DATA}/${HOST_MARKER}"
elif [[ -r "${HERMES_DATA}/config.yaml" ]]; then
  host_ck="$(cksum < "${HERMES_DATA}/config.yaml")"
  cont_ck="$(hermes_exec sh -c 'cksum < /opt/data/config.yaml')"
  check_eq "host config.yaml is the /opt/data bind" "$host_ck" "$cont_ck"
else
  printf 'PASS  host bind file readable at /opt/data (host data dir not accessible from this uid; bind Source/Type already checked)\n'
fi

if grep -vE '^\s*#' "${ASSISTANT_ROOT}/scripts/hermes-assistant-wrapper.sh" \
  | grep -q 'hermes_unset_empty_compose_vars'; then
  printf 'PASS  wrapper unsets empty compose vars before interpolate\n'
else
  printf 'FAIL  wrapper unsets empty compose vars before interpolate\n'
  FAIL=1
fi

if grep -vE '^\s*#' "${ASSISTANT_ROOT}/scripts/hermes-assistant-wrapper.sh" \
  | grep -E 'hermes_compose down[[:space:]].*(--volumes|[[:space:]]-v([[:space:]]|$))' >/dev/null; then
  printf 'FAIL  wrapper compose down must not pass --volumes / -v\n'
  FAIL=1
else
  printf 'PASS  wrapper compose down does not pass --volumes / -v\n'
fi

if hermes_exec sh -c 'touch /opt/data/workspace/.hermes-write-test && rm -f /opt/data/workspace/.hermes-write-test'; then
  printf 'PASS  workspace is writable\n'
else
  printf 'FAIL  workspace is writable\n'
  hermes_exec sh -c 'echo "      container uid: $(id -u) gid: $(id -g)"; ls -ld /opt/data/workspace; ls -la /opt/data/workspace | head -5' 2>/dev/null || true
  printf '      fix: recreate after workspace mount path update (launch-with-host-env.sh recreate)\n' >&2
  FAIL=1
fi

check "admin .bashrc not mounted" \
  hermes_exec test ! -r "${ADMIN_HOME}/.bashrc"

check "OpenClaw config not visible" \
  hermes_exec test ! -r "${ADMIN_HOME}/.openclaw/openclaw.json"

FAIL_CFG=0
if hermes_exec grep -q 'auto_source_bashrc: false' /opt/data/config.yaml 2>/dev/null; then
  printf 'PASS  auto_source_bashrc disabled\n'
else
  printf 'FAIL  auto_source_bashrc disabled\n'
  hermes_podman exec --user root "$CONTAINER" ls -la /opt/data/config.yaml 2>/dev/null || true
  FAIL=1
  FAIL_CFG=1
fi

if hermes_exec grep -q 'cwd: /opt/data/workspace' /opt/data/config.yaml 2>/dev/null; then
  printf 'PASS  terminal.cwd is /opt/data/workspace\n'
else
  printf 'FAIL  terminal.cwd is /opt/data/workspace\n'
  if [[ "$FAIL_CFG" -eq 0 ]]; then
    hermes_podman exec --user root "$CONTAINER" ls -la /opt/data/config.yaml 2>/dev/null || true
  fi
  FAIL=1
fi

if grep -vE '^\s*#' "${ASSISTANT_ROOT}/docker-compose.yml" 2>/dev/null \
  | grep -qE '\$\{[^}]+:-\$\{'; then
  printf 'FAIL  docker-compose.yml uses nested default expansion — podman-compose breaks mounts\n'
  FAIL=1
else
  printf 'PASS  docker-compose.yml uses plain env vars (no nested defaults)\n'
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "All checks passed — Hermes state persists on ${HERMES_DATA}"
  exit 0
fi

OPERATOR_KIT="${HERMES_OPERATOR_KIT:-/home/bucephalus3/hermes-assistant}"
echo "Some checks failed — try (from bucephalus3):"
echo "  sudo bash ${OPERATOR_KIT}/scripts/sync-to-hermes.sh"
echo "  sudo bash ${OPERATOR_KIT}/scripts/fix-home-permissions.sh"
echo "  source ~/.bashrc && ${OPERATOR_KIT}/scripts/launch-with-host-env.sh recreate"
echo "Do NOT sudo bash /home/hermes/.../fix-home-permissions.sh (refuses untrusted path)."
echo "If you see hermes-assistant_dashboard pull errors: stale compose.runtime.yml — sync + recreate regenerates it."
exit 1
