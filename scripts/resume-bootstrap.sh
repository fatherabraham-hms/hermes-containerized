#!/bin/bash
# Finish bootstrap after a partial migrate (files already under ~/hermes-assistant).
# Run as user hermes:  ./scripts/resume-bootstrap.sh

set -euo pipefail

ASSISTANT_ROOT="${HERMES_ASSISTANT_ROOT:-$HOME/hermes-assistant}"
exec "${ASSISTANT_ROOT}/scripts/bootstrap.sh"
