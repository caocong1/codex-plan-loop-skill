#!/usr/bin/env bash
# Run Codex to review code changes.
# Usage: run-codex-code-review.sh <workdir> <review_version> <project_root>
#
# Round 1: full prompt with plan + diff + summary, saves thread_id.
# Round 2+: resumes thread with updated diff + summary.
# Falls back to stateless full prompt if resume fails.
#
# Reads: final plan, change-summary.md, git diff (scoped to baseline), test-results.txt
# Writes: review.code.vN.json (or review.code.vN.raw.txt on failure)
# Manages: codex-code-thread.id
#
# Requires: codex-cli >= 0.79.0

set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
WORKDIR="${1:?Usage: run-codex-code-review.sh <workdir> <review_version> <project_root>}"
VERSION="${2:?Usage: run-codex-code-review.sh <workdir> <review_version> <project_root>}"
PROJECT_ROOT="${3:?Usage: run-codex-code-review.sh <workdir> <review_version> <project_root>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

OUTPUT_FILE="${WORKDIR}/review.code.v${VERSION}.json"
RAW_FILE="${WORKDIR}/review.code.v${VERSION}.raw.txt"
CHANGE_SUMMARY="${WORKDIR}/change-summary.md"
THREAD_FILE="${WORKDIR}/codex-code-thread.id"
CODEX_OUTPUT="${WORKDIR}/.codex-code-output.txt"
BASELINE_FILE="${WORKDIR}/.git-baseline"

# Find the latest plan version
LATEST_PLAN=""
for i in 5 4 3 2 1; do
  if [ -f "${WORKDIR}/plan.v${i}.md" ]; then
    LATEST_PLAN="${WORKDIR}/plan.v${i}.md"
    break
  fi
done

if [ -z "$LATEST_PLAN" ]; then
  echo "ERROR: No plan file found in $WORKDIR" >&2
  exit 1
fi

# --- Helpers ---
extract_thread_id() {
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        tid = obj.get('thread_id') or obj.get('session_id')
        if tid:
            print(tid)
            sys.exit(0)
    except Exception: pass
sys.exit(1)
PY
}

extract_json() {
  local raw="$1"
  if echo "$raw" | python3 -m json.tool > /dev/null 2>&1; then
    echo "$raw"; return 0
  fi
  local json_output
  json_output=$(echo "$raw" | sed -n '/^[[:space:]]*{/,/^[[:space:]]*}/p')
  if [ -n "$json_output" ] && echo "$json_output" | python3 -m json.tool > /dev/null 2>&1; then
    echo "$json_output"; return 0
  fi
  json_output=$(echo "$raw" | sed -n '/```json/,/```/p' | sed '1d;$d')
  if [ -n "$json_output" ] && echo "$json_output" | python3 -m json.tool > /dev/null 2>&1; then
    echo "$json_output"; return 0
  fi
  return 1
}

run_codex_exec() {
  local prompt="$1"
  local jsonl_tmp="${WORKDIR}/.codex-jsonl-$$.tmp"
  echo "$prompt" | "$CODEX_BIN" exec --sandbox read-only --json -o "$CODEX_OUTPUT" - > "$jsonl_tmp" 2>/dev/null
  local exit_code=$?
  local tid
  tid=$(extract_thread_id "$jsonl_tmp") && echo "$tid" > "$THREAD_FILE"
  rm -f "$jsonl_tmp"
  return $exit_code
}

run_codex_resume() {
  local thread_id="$1"
  local prompt="$2"
  local jsonl_tmp="${WORKDIR}/.codex-jsonl-$$.tmp"
  echo "$prompt" | "$CODEX_BIN" exec resume --sandbox read-only --json -o "$CODEX_OUTPUT" "$thread_id" - > "$jsonl_tmp" 2>/dev/null
  local exit_code=$?
  rm -f "$jsonl_tmp"
  return $exit_code
}

# --- Gather diff context (B2 fix: scoped to baseline) ---
gather_diff_context() {
  local plan summary diff_stat diff test_results

  plan=$(cat "$LATEST_PLAN")
  summary=""
  if [ -f "$CHANGE_SUMMARY" ]; then
    summary=$(cat "$CHANGE_SUMMARY")
  fi

  # Determine diff baseline
  local diff_base="HEAD"
  if [ -f "$BASELINE_FILE" ]; then
    diff_base=$(cat "$BASELINE_FILE")
    echo "Using baseline commit for scoped diff: $diff_base" >&2
  fi

  # Scoped diff: only changes since this run started (B2 fix)
  diff_stat=$(cd "$PROJECT_ROOT" && git diff --stat "$diff_base" 2>/dev/null || echo "(no changes)")
  local full_diff
  full_diff=$(cd "$PROJECT_ROOT" && git diff "$diff_base" 2>/dev/null || echo "(no diff)")

  # Include new untracked files in diff output (B2 fix)
  local untracked
  untracked=$(cd "$PROJECT_ROOT" && git ls-files --others --exclude-standard 2>/dev/null || true)
  if [ -n "$untracked" ]; then
    full_diff="${full_diff}

--- Untracked new files ---
${untracked}"
  fi

  local diff_lines
  diff_lines=$(echo "$full_diff" | wc -l)
  if [ "$diff_lines" -gt 8000 ]; then
    diff=$(echo "$full_diff" | head -n 8000)
    diff="${diff}

... (truncated, ${diff_lines} total lines — see full diff via git diff)"
  else
    diff="$full_diff"
  fi

  test_results="(no test results captured)"
  if [ -f "${WORKDIR}/test-results.txt" ]; then
    test_results=$(cat "${WORKDIR}/test-results.txt")
  fi

  GATHERED_PLAN="$plan"
  GATHERED_SUMMARY="$summary"
  GATHERED_DIFF_STAT="$diff_stat"
  GATHERED_DIFF="$diff"
  GATHERED_TEST_RESULTS="$test_results"
}

gather_diff_context

# --- Build prompt based on round ---
if [ "$VERSION" -eq 1 ]; then
  TEMPLATE=$(cat "${TEMPLATE_DIR}/codex-code-review-prompt.md")
  PROMPT="${TEMPLATE}"
  PROMPT="${PROMPT//\{\{PLAN\}\}/$GATHERED_PLAN}"
  PROMPT="${PROMPT//\{\{CHANGE_SUMMARY\}\}/$GATHERED_SUMMARY}"
  PROMPT="${PROMPT//\{\{DIFF_STAT\}\}/$GATHERED_DIFF_STAT}"
  PROMPT="${PROMPT//\{\{DIFF\}\}/$GATHERED_DIFF}"
  PROMPT="${PROMPT//\{\{TEST_RESULTS\}\}/$GATHERED_TEST_RESULTS}"

  echo "Running Codex code review Round 1 (new session)..." >&2

else
  if [ -f "$THREAD_FILE" ]; then
    THREAD_ID=$(cat "$THREAD_FILE")
    RESUME_PROMPT="The code has been updated based on your previous review. Please review the changes again.

## Updated Change Summary

${GATHERED_SUMMARY}

## Updated Diff Stats

${GATHERED_DIFF_STAT}

## Updated Diff

${GATHERED_DIFF}

## Test Results

${GATHERED_TEST_RESULTS}

Please review the updated code. Verify that previously raised blocking/major issues have been fixed. Do not re-raise resolved issues. Output valid JSON only, same format as before."

    echo "Running Codex code review Round ${VERSION} (resuming thread ${THREAD_ID})..." >&2

    if run_codex_resume "$THREAD_ID" "$RESUME_PROMPT"; then
      RAW=$(cat "$CODEX_OUTPUT" 2>/dev/null || echo "")
      if JSON=$(extract_json "$RAW"); then
        echo "$JSON" | python3 -m json.tool > "$OUTPUT_FILE"
        echo "Review written to: $OUTPUT_FILE" >&2
        rm -f "$CODEX_OUTPUT"
        exit 0
      fi
    fi

    echo "Resume failed, falling back to stateless full prompt..." >&2
  fi

  TEMPLATE=$(cat "${TEMPLATE_DIR}/codex-code-review-prompt.md")
  PROMPT="${TEMPLATE}"
  PROMPT="${PROMPT//\{\{PLAN\}\}/$GATHERED_PLAN}"
  PROMPT="${PROMPT//\{\{CHANGE_SUMMARY\}\}/$GATHERED_SUMMARY}"
  PROMPT="${PROMPT//\{\{DIFF_STAT\}\}/$GATHERED_DIFF_STAT}"
  PROMPT="${PROMPT//\{\{DIFF\}\}/$GATHERED_DIFF}"
  PROMPT="${PROMPT//\{\{TEST_RESULTS\}\}/$GATHERED_TEST_RESULTS}"

  echo "Running Codex code review Round ${VERSION} (stateless fallback)..." >&2
fi

# --- Execute ---
attempt=1
while [ "$attempt" -le 2 ]; do
  echo "Attempt ${attempt}..." >&2

  if run_codex_exec "$PROMPT"; then
    RAW=$(cat "$CODEX_OUTPUT" 2>/dev/null || echo "")
    if JSON=$(extract_json "$RAW"); then
      echo "$JSON" | python3 -m json.tool > "$OUTPUT_FILE"
      echo "Review written to: $OUTPUT_FILE" >&2
      rm -f "$CODEX_OUTPUT"
      exit 0
    fi
  fi

  echo "Attempt ${attempt} failed or invalid JSON." >&2
  attempt=$((attempt + 1))
done

echo "Both attempts failed to produce valid JSON. Saving raw output." >&2
RAW=$(cat "$CODEX_OUTPUT" 2>/dev/null || echo "(no output captured)")
echo "$RAW" > "$RAW_FILE"
echo "Raw output saved to: $RAW_FILE" >&2
rm -f "$CODEX_OUTPUT"
exit 1
