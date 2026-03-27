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

# Check codex version
CODEX_BIN="${CODEX_BIN:-codex}"
if command -v "$CODEX_BIN" > /dev/null 2>&1; then
  CODEX_VERSION=$("$CODEX_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$CODEX_VERSION" ]; then
    # Compare versions: OK if CODEX_VERSION >= 0.79.0
    if [ "$(printf '%s\n' "0.79.0" "$CODEX_VERSION" | sort -V | head -n1)" != "0.79.0" ]; then
      echo "WARNING: codex version $CODEX_VERSION < 0.79.0. Skill may not work correctly." >&2
    else
      echo "Codex version: $CODEX_VERSION (OK)"
    fi
  else
    echo "WARNING: Could not determine codex version. Make sure codex >= 0.79.0 is installed." >&2
  fi
else
  echo "WARNING: codex not found in PATH. Install it with: brew install codex" >&2
fi

# Create target directory
mkdir -p "$TARGET_DIR/scripts/lib" "$TARGET_DIR/templates"

# Copy files
cp "$SCRIPT_DIR/SKILL.md" "$TARGET_DIR/"
cp "$SCRIPT_DIR/README.md" "$TARGET_DIR/"
cp "$SCRIPT_DIR"/scripts/*.sh "$TARGET_DIR/scripts/"
if [ -d "$SCRIPT_DIR/scripts/lib" ]; then
  cp "$SCRIPT_DIR"/scripts/lib/*.sh "$TARGET_DIR/scripts/lib/"
  chmod +x "$TARGET_DIR/scripts/lib/"*.sh
fi
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
echo "  /codex-plan-loop --resume <workdir>             (resume from existing run)"
echo ""
echo "Environment variables:"
echo "  CODEX_TIMEOUT=$CODEX_TIMEOUT         # seconds"
echo "  CODEX_DIFF_MAX_LINES=8000             # max diff lines for code review"
echo "  CODEX_MODEL=<model>                   # optional model override"
echo ""
echo "To uninstall:"
echo "  bash $TARGET_DIR/uninstall.sh $PROJECT_ROOT"
