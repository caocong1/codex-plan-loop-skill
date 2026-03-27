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

# Detect project type
detect_project_type() {
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    echo "nodejs"
  elif [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    echo "rust"
  elif [ -f "$PROJECT_ROOT/go.mod" ]; then
    echo "go"
  elif [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/build.gradle.kts" ]; then
    echo "java"
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ] || [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    echo "python"
  elif [ -f "$PROJECT_ROOT/pubspec.yaml" ]; then
    echo "dart"
  elif [ -f "$PROJECT_ROOT/mix.exs" ]; then
    echo "elixir"
  else
    echo "unknown"
  fi
}

PROJECT_TYPE=$(detect_project_type)
echo "$PROJECT_TYPE" > "$WORKDIR/project-type.txt"
echo "Project type detected: $PROJECT_TYPE" >&2

echo "$WORKDIR"
