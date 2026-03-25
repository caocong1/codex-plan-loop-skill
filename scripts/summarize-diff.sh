#!/usr/bin/env bash
# Generate a diff stat summary scoped to the run baseline.
# Usage: summarize-diff.sh <project_root> <workdir>
# Writes: diff-stat.txt (stats + changed file names + untracked files).

set -euo pipefail

PROJECT_ROOT="${1:?Usage: summarize-diff.sh <project_root> <workdir>}"
WORKDIR="${2:?Usage: summarize-diff.sh <project_root> <workdir>}"
BASELINE_FILE="${WORKDIR}/.git-baseline"

# Determine diff baseline
DIFF_BASE="HEAD"
if [ -f "$BASELINE_FILE" ]; then
  DIFF_BASE=$(cat "$BASELINE_FILE")
fi

cd "$PROJECT_ROOT"

{
  echo "## Diff Stats (since baseline ${DIFF_BASE:0:8})"
  git diff --stat "$DIFF_BASE" 2>/dev/null || echo "(no changes)"

  echo ""
  echo "## Files Changed"
  git diff --name-only "$DIFF_BASE" 2>/dev/null || true

  # Include untracked files
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)
  if [ -n "$UNTRACKED" ]; then
    echo ""
    echo "## New Untracked Files"
    echo "$UNTRACKED"
  fi
} > "${WORKDIR}/diff-stat.txt"

echo "Diff summary written to: ${WORKDIR}/diff-stat.txt" >&2
