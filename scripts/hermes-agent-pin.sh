#!/bin/bash
# Load and verify hermes-agent.lock (sourced by wrapper / prepare-build-context).
# Bypass: HERMES_SKIP_UPSTREAM_PIN=1

hermes_agent_lock_path() {
  local root="${HERMES_ASSISTANT_ROOT:-${HERMES_OPERATOR_KIT:-$HOME/hermes-assistant}}"
  printf '%s\n' "${root}/hermes-agent.lock"
}

hermes_load_agent_lock() {
  local lock line key val
  lock="$(hermes_agent_lock_path)"
  if [[ ! -f "$lock" ]]; then
    printf 'ERROR: missing pin file %s\n' "$lock" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      HERMES_AGENT_REPO|HERMES_AGENT_VERSION|HERMES_AGENT_COMMIT|HERMES_AGENT_REF)
        printf '%s=%s\n' "$key" "$val"
        ;;
    esac
  done <"$lock"
}

hermes_lock_get() {
  local want="$1" key val
  while IFS='=' read -r key val; do
    if [[ "$key" == "$want" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  done < <(hermes_load_agent_lock)
  return 1
}

hermes_git_commit() {
  local dir="$1"
  git -C "$dir" rev-parse HEAD 2>/dev/null
}

# Resolve a tree to check: git checkout, or stamp written by prepare-build-context.
hermes_pinned_commit_at() {
  local dir="$1"
  local stamp="${dir}/.hermes-agent-commit"
  if [[ -d "${dir}/.git" ]] || git -C "$dir" rev-parse HEAD >/dev/null 2>&1; then
    hermes_git_commit "$dir"
    return 0
  fi
  if [[ -f "$stamp" ]]; then
    tr -d '[:space:]' <"$stamp"
    return 0
  fi
  return 1
}

hermes_check_agent_pin() {
  local src="${1:-}"
  local expected actual
  if [[ "${HERMES_SKIP_UPSTREAM_PIN:-}" == "1" ]]; then
    printf 'WARN: skipping hermes-agent pin check (HERMES_SKIP_UPSTREAM_PIN=1)\n' >&2
    return 0
  fi
  expected="$(hermes_lock_get HERMES_AGENT_COMMIT)" || return 1
  if [[ -z "$src" ]]; then
    printf 'ERROR: no hermes-agent tree to pin-check\n' >&2
    return 1
  fi
  if ! actual="$(hermes_pinned_commit_at "$src")"; then
    printf 'ERROR: cannot verify hermes-agent pin at %s (not a git checkout and no .hermes-agent-commit stamp)\n' "$src" >&2
    printf '  Expected commit %s (see hermes-agent.lock)\n' "$expected" >&2
    printf '  Checkout that SHA, or: HERMES_SKIP_UPSTREAM_PIN=1\n' >&2
    return 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    printf 'ERROR: hermes-agent at %s is %s, lock wants %s\n' "$src" "$actual" "$expected" >&2
    printf '  git -C %s checkout %s\n' "$src" "$expected" >&2
    printf '  or refresh the pin: scripts/update-hermes-agent-pin.sh\n' >&2
    printf '  or bypass: HERMES_SKIP_UPSTREAM_PIN=1\n' >&2
    return 1
  fi
  printf 'Hermes-agent pin OK: %s (%s)\n' "$expected" "$(hermes_lock_get HERMES_AGENT_VERSION 2>/dev/null || true)" >&2
}
