#!/usr/bin/env bash
# tools/opencode/generate-agents.sh — regenerate the open-code/agents/ overlay.
# Thin wrapper at the documented path; the real generator lives in
# shared/scripts/generate-agents.sh (sources: shared/agents/*.body.md +
# shared/scripts/opencode-frontmatter/*.yaml + open-code/agents-src/).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$REPO_ROOT/shared/scripts/generate-agents.sh" --target=opencode "$@"
