#!/bin/bash
# Rewrite hermes-agent.lock from a local hermes-agent git checkout.
#   scripts/update-hermes-agent-pin.sh
#   scripts/update-hermes-agent-pin.sh /path/to/hermes-agent

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-${HERMES_REPO_SRC:-$HOME/0_Development/hermes-agent}}"
LOCK="${ROOT}/hermes-agent.lock"

if [[ ! -d "${SOURCE}/.git" ]]; then
  printf 'ERROR: not a git checkout: %s\n' "$SOURCE" >&2
  exit 1
fi

commit="$(git -C "$SOURCE" rev-parse HEAD)"
ref="$(git -C "$SOURCE" describe --tags --always 2>/dev/null || echo "$commit")"
version="unknown"
if [[ -f "${SOURCE}/pyproject.toml" ]]; then
  version="$(awk -F'"' '/^version = / { print $2; exit }' "${SOURCE}/pyproject.toml")"
fi
repo="$(git -C "$SOURCE" remote get-url origin 2>/dev/null || echo https://github.com/nousresearch/hermes-agent)"

cat >"$LOCK" <<EOF
# Pinned NousResearch/hermes-agent used as the Docker build context.
# Python/Node installs inside the image use that commit's uv.lock and
# package-lock.json (\`uv sync --frozen\`, npm lockfile). Do not vendor
# .venv or node_modules in this kit.
#
# Refresh after pulling upstream:
#   scripts/update-hermes-agent-pin.sh
# Then: sudo bash scripts/prepare-build-context.sh && wrapper recreate

HERMES_AGENT_REPO=${repo}
HERMES_AGENT_VERSION=${version}
HERMES_AGENT_COMMIT=${commit}
HERMES_AGENT_REF=${ref}
EOF

printf 'Wrote %s\n  repo    %s\n  version %s\n  commit  %s\n  ref     %s\n' \
  "$LOCK" "$repo" "$version" "$commit" "$ref"
