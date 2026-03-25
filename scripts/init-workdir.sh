#!/usr/bin/env bash
# Initialize a working directory for a codex-plan-loop run.
# Usage: init-workdir.sh <project_root> [slug]
# Outputs the created directory path to stdout.
# Saves git baseline (HEAD commit) for scoped diffs later.

set -euo pipefail

PROJECT_ROOT="${1:?Usage: init-workdir.sh <project_root> [slug]}"
SLUG="${2:-run}"

# Sanitize slug: lowercase, replace spaces/special chars with hyphens, truncate
SLUG=$(echo "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 40)

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
WORKDIR="${PROJECT_ROOT}/.codex-plan-loop/${TIMESTAMP}-${SLUG}"

mkdir -p "$WORKDIR"

# Save git baseline for scoped diffs
if cd "$PROJECT_ROOT" && git rev-parse HEAD > /dev/null 2>&1; then
  git rev-parse HEAD > "$WORKDIR/.git-baseline"
  echo "Baseline commit saved: $(cat "$WORKDIR/.git-baseline")" >&2
fi

echo "$WORKDIR"
