#!/usr/bin/env bash
# Install codex-plan-loop skill into any Claude Code project.
#
# Usage:
#   git clone https://github.com/<user>/codex-plan-loop-skill.git /tmp/cpl && bash /tmp/cpl/install.sh [project_root]
#
# Environment variables:
#   REPO_URL  — override the git clone URL (for forks)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/nicobailon/codex-plan-loop-skill.git}"

# Determine source directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine target project root
PROJECT_ROOT="${1:-$(pwd)}"

# If running via curl (no local files), clone first
if [ ! -f "$SCRIPT_DIR/SKILL.md" ]; then
  echo "Cloning codex-plan-loop-skill from $REPO_URL ..."
  TMPDIR=$(mktemp -d)
  git clone --depth 1 "$REPO_URL" "$TMPDIR" 2>/dev/null
  SCRIPT_DIR="$TMPDIR"
fi

TARGET_DIR="${PROJECT_ROOT}/.claude/skills/codex-plan-loop"

echo "Installing codex-plan-loop skill..."
echo "  Source: $SCRIPT_DIR"
echo "  Target: $TARGET_DIR"

# Create target directory
mkdir -p "$TARGET_DIR/scripts" "$TARGET_DIR/templates"

# Copy files
cp "$SCRIPT_DIR/SKILL.md" "$TARGET_DIR/"
cp "$SCRIPT_DIR/README.md" "$TARGET_DIR/"
cp "$SCRIPT_DIR"/scripts/*.sh "$TARGET_DIR/scripts/"
cp "$SCRIPT_DIR"/templates/*.md "$TARGET_DIR/templates/"
cp "$SCRIPT_DIR/uninstall.sh" "$TARGET_DIR/" 2>/dev/null || true

# Make scripts executable
chmod +x "$TARGET_DIR/scripts/"*.sh
chmod +x "$TARGET_DIR/uninstall.sh" 2>/dev/null || true

# Add .codex-plan-loop/ to .gitignore if not already there
GITIGNORE="${PROJECT_ROOT}/.gitignore"
if [ -f "$GITIGNORE" ]; then
  if ! grep -q "codex-plan-loop" "$GITIGNORE"; then
    echo "" >> "$GITIGNORE"
    echo "# Codex plan loop working directories" >> "$GITIGNORE"
    echo ".codex-plan-loop/" >> "$GITIGNORE"
    echo "  Added .codex-plan-loop/ to .gitignore"
  fi
else
  echo ".codex-plan-loop/" > "$GITIGNORE"
  echo "  Created .gitignore with .codex-plan-loop/"
fi

echo ""
echo "Done! Skill installed at: $TARGET_DIR"
echo ""
echo "Usage:"
echo "  /codex-plan-loop <task description>"
echo "  /codex-plan-loop --plan-only <task description>  (plan only, no execution)"
echo ""
echo "Prerequisites:"
echo "  - codex CLI >= 0.79.0 (brew install codex)"
echo "  - python3 (for JSON validation)"
echo ""
echo "To uninstall:"
echo "  bash $TARGET_DIR/uninstall.sh $PROJECT_ROOT"
