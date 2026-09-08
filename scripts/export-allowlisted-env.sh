#!/bin/bash
# Build a compose runtime overlay from env.allowlist (names only).
# Values are taken from the invoking shell at start time — never written to disk.

set -euo pipefail

hermes_allowlist_path() {
  local root="${HERMES_ASSISTANT_ROOT:-}"
  local data="${HERMES_DATA_DIR:-$HOME/.hermes-assistant}/env.allowlist"
  if [[ -n "$root" && -r "${root}/config/env.allowlist" ]]; then
    printf '%s\n' "${root}/config/env.allowlist"
    return
  fi
  if [[ -n "${HERMES_ENV_ALLOWLIST:-}" && -r "${HERMES_ENV_ALLOWLIST}" ]]; then
    printf '%s\n' "${HERMES_ENV_ALLOWLIST}"
    return
  fi
  if [[ -r "$data" ]]; then
    printf '%s\n' "$data"
    return
  fi
  if [[ -n "$root" && -f "${root}/config/env.allowlist" ]]; then
    printf '%s\n' "${root}/config/env.allowlist"
    return
  fi
  printf '%s\n' "$data"
}

hermes_load_persisted_env_from_stream() {
  local line name val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" != *=* ]] && continue
    name="${line%%=*}"
    val="${line#*=}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    # Strip optional matching quotes
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
      val="${val:1:${#val}-2}"
    fi
    if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [[ -z "${!name-}" ]]; then
      export "$name=$val"
    fi
  done
}

hermes_shell_init_path() {
  if [[ -n "${HERMES_SHELL_INIT:-}" && -f "${HERMES_SHELL_INIT}" ]]; then
    printf '%s\n' "${HERMES_SHELL_INIT}"
    return 0
  fi
  if [[ -f "${HOME}/.bashrc" ]]; then
    printf '%s\n' "${HOME}/.bashrc"
    return 0
  fi
  if [[ -f "${HOME}/.profile" ]]; then
    printf '%s\n' "${HOME}/.profile"
    return 0
  fi
  return 1
}

hermes_load_allowlisted_from_shell() {
  # Pull allowlisted values from the operator shell init file (default ~/.bashrc).
  # Uses bash -ic so exports below bashrc's "non-interactive return" still load.
  # Does not overwrite variables already exported in the current environment.
  #
  # IMPORTANT: each probe must be a single line. Joining multi-line if/then/fi
  # with ";" produces "then;" which is a bash syntax error — under systemd that
  # silently yielded zero exports and empty -e VAR= into the container.
  local allowlist="${1:-$(hermes_allowlist_path)}"
  local init line key loaded=0
  local -a names=() script=()
  local tmp_err

  mapfile -t names < <(hermes_read_allowlist_names "$allowlist" || true)
  ((${#names[@]})) || return 0

  init="$(hermes_shell_init_path)" || {
    printf 'WARN: no shell init file (~/.bashrc); allowlisted vars may be missing\n' >&2
    return 0
  }

  script+=("source $(printf '%q' "$init") >/dev/null 2>&1 || true")
  for key in "${names[@]}"; do
    script+=("if [[ -n \${${key}+x} && -n \"\${${key}}\" ]]; then printf '%s=%q\\n' '${key}' \"\${${key}}\"; fi")
  done

  tmp_err="$(mktemp "${TMPDIR:-/tmp}/hermes-shell-init.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key-}" ]] && continue
    # shellcheck disable=SC2086
    eval "export ${line}"
    loaded=$((loaded + 1))
  done < <(bash -ic "$(printf '%s\n' "${script[@]}")" 2>"$tmp_err" || true)

  if ((loaded == 0)); then
    printf 'WARN: loaded 0 allowlisted vars from %s\n' "$init" >&2
    if grep -q 'syntax error' "$tmp_err" 2>/dev/null; then
      printf 'WARN: shell-init probe failed: %s\n' "$(grep -m1 'syntax error' "$tmp_err")" >&2
    fi
  else
    printf 'Hermes shell init: loaded %d allowlisted var(s) from %s\n' "$loaded" "$init" >&2
  fi
  rm -f "$tmp_err"
}

hermes_load_allowlisted_exports() {
  # Default credential source: operator shell init (bashrc). Opt-in disk fallback only
  # when HERMES_LOAD_PERSISTED_ENV=1 (legacy ~/.hermes-assistant/.env path).
  hermes_load_allowlisted_from_shell
  if [[ "${HERMES_LOAD_PERSISTED_ENV:-}" == "1" ]]; then
    hermes_load_persisted_env
  fi
}

hermes_load_persisted_env() {
  # Opt-in legacy path — not used unless HERMES_LOAD_PERSISTED_ENV=1.
  local envfile="${HERMES_DATA_DIR:-$HOME/.hermes-assistant}/.env"
  local container="${HERMES_ASSISTANT_CONTAINER:-hermes-assistant}"

  if [[ -f "$envfile" && -r "$envfile" ]]; then
    hermes_load_persisted_env_from_stream < "$envfile"
    return 0
  fi

  if command -v podman >/dev/null 2>&1 \
    && podman inspect "$container" >/dev/null 2>&1; then
    hermes_load_persisted_env_from_stream < <(
      podman exec "$container" cat /opt/data/.env 2>/dev/null || true
    )
  fi
}

hermes_sync_operator_allowlist() {
  local root="${HERMES_ASSISTANT_ROOT:-}"
  local src="${root}/config/env.allowlist"
  local dest="${HERMES_DATA_DIR:-$HOME/.hermes-assistant}/env.allowlist"
  [[ -f "$src" ]] || return 0
  mkdir -p "${HERMES_DATA_DIR:-$HOME/.hermes-assistant}"
  if [[ -w "$(dirname "$dest")" ]]; then
    cp "$src" "$dest"
    chmod 600 "$dest" 2>/dev/null || true
  elif [[ -w "$dest" ]]; then
    cp "$src" "$dest"
    chmod 600 "$dest" 2>/dev/null || true
  elif command -v sudo >/dev/null 2>&1 && [[ "$(id -u)" -ne 0 ]]; then
    # Non-interactive callers (systemd) must not hang on sudo password prompts.
    if sudo -n install -o "$(id -un)" -g "$(id -gn)" -m 600 "$src" "$dest" 2>/dev/null; then
      :
    elif [[ "${HERMES_SYSTEMD:-}" == "1" ]]; then
      printf 'WARN: cannot sync env.allowlist to %s (skip under systemd)\n' "$dest" >&2
    else
      sudo install -o hermes -g hermes -m 600 "$src" "$dest" 2>/dev/null || true
    fi
  elif [[ "$(id -u)" -eq 0 ]]; then
    install -o hermes -g hermes -m 600 "$src" "$dest"
  fi
}

hermes_runtime_compose_path() {
  local root="${HERMES_ASSISTANT_ROOT:-$HOME/hermes-assistant}"
  printf '%s\n' "${HERMES_COMPOSE_RUNTIME:-${root}/compose.runtime.yml}"
}

hermes_allowlist_contents() {
  local allowlist="$1"

  if [[ -r "$allowlist" ]]; then
    cat "$allowlist"
    return 0
  fi
  if [[ -f "$allowlist" ]] && command -v sudo >/dev/null 2>&1; then
    if sudo -n cat "$allowlist" 2>/dev/null; then
      return 0
    fi
    if sudo cat "$allowlist" 2>/dev/null; then
      return 0
    fi
    printf 'WARN: cannot read %s (sudo failed — edit ~/hermes-assistant/config/env.allowlist instead)\n' "$allowlist" >&2
  fi
  return 1
}

hermes_read_allowlist_names() {
  local allowlist="$1"
  local line

  if ! hermes_allowlist_contents "$allowlist" >/dev/null 2>&1; then
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf '%s\n' "$line"
    else
      printf 'WARN: ignoring invalid env name in allowlist: %q\n' "$line" >&2
    fi
  done < <(hermes_allowlist_contents "$allowlist")
}

hermes_prepare_allowlisted_compose() {
  local allowlist runtime name
  local -a names=()

  allowlist="$(hermes_allowlist_path)"
  runtime="$(hermes_runtime_compose_path)"

  if ! hermes_allowlist_contents "$allowlist" >/dev/null 2>&1; then
    printf 'WARN: cannot read env allowlist at %s\n' "$allowlist" >&2
  else
    mapfile -t names < <(hermes_read_allowlist_names "$allowlist")
  fi

  local passed=0 missing=0
  local -a present=()

  for name in "${names[@]}"; do
    if [[ -n "${!name-}" ]]; then
      export "$name"
      present+=("$name")
      passed=$((passed + 1))
    else
      missing=$((missing + 1))
      printf '  allowlist (not in shell): %s\n' "$name" >&2
    fi
  done

  {
    printf 'services:\n'
    printf '  gateway:\n    environment:\n'
    if ((${#present[@]})); then
      # Only emit vars that are actually set — otherwise compose injects -e VAR=
      # (empty string) and the agent sees blank values.
      for name in "${present[@]}"; do
        printf '      - %s=${%s}\n' "$name" "$name"
      done
    else
      # Empty mapping — do NOT emit a phantom `dashboard:` service.
      # Compose is gateway-only; dashboard runs inside gateway via HERMES_DASHBOARD=1.
      printf '      []\n'
    fi
  } >"$runtime"
  chmod 600 "$runtime" 2>/dev/null || true

  if ((${#names[@]})); then
    printf 'Hermes env allowlist: %d name(s), %d present in this shell, %d missing\n' \
      "${#names[@]}" "$passed" "$missing" >&2
  fi
}

hermes_compose_file_args() {
  local assistant_root="${1:?}"
  local runtime
  runtime="$(hermes_runtime_compose_path)"

  printf '%s\n' "-f" "${assistant_root}/docker-compose.yml"
  if [[ -f "$runtime" ]]; then
    printf '%s\n' "-f" "$runtime"
  fi
}
