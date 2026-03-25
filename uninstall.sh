#!/usr/bin/env bash
# Uninstall codex-plan-loop skill from a project.
# Usage: bash uninstall.sh [project_root]

set -euo pipefail

PROJECT_ROOT="${1:-$(pwd)}"
TARGET_DIR="${PROJECT_ROOT}/.claude/skills/codex-plan-loop"

if [ -d "$TARGET_DIR" ]; then
  rm -rf "$TARGET_DIR"
  echo "Removed: $TARGET_DIR"
else
  echo "Skill not found at: $TARGET_DIR"
fi

echo ""
echo "Note: .codex-plan-loop/ working directories and .gitignore entry were left in place."
echo "Remove manually if desired."
