#!/usr/bin/env bash
# Run Codex to review a plan.
# Usage: run-codex-plan-review.sh <workdir> <plan_version>
#
# Round 1: full prompt, saves thread_id for subsequent rounds.
# Round 2+: resumes previous thread with only the new plan + resolution.
# Falls back to stateless full prompt if resume fails.
#
# Reads: request.md, plan.vN.md, resolution.v(N-1).md, review.plan.v(N-1).json
# Writes: review.plan.vN.json (or review.plan.vN.raw.txt on failure)
# Manages: codex-plan-thread.id
#
# Requires: codex-cli >= 0.79.0

set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
WORKDIR="${1:?Usage: run-codex-plan-review.sh <workdir> <plan_version>}"
VERSION="${2:?Usage: run-codex-plan-review.sh <workdir> <plan_version>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

PLAN_FILE="${WORKDIR}/plan.v${VERSION}.md"
REQUEST_FILE="${WORKDIR}/request.md"
OUTPUT_FILE="${WORKDIR}/review.plan.v${VERSION}.json"
RAW_FILE="${WORKDIR}/review.plan.v${VERSION}.raw.txt"
THREAD_FILE="${WORKDIR}/codex-plan-thread.id"
CODEX_OUTPUT="${WORKDIR}/.codex-plan-output.txt"

# Validate inputs
if [ ! -f "$PLAN_FILE" ]; then
  echo "ERROR: Plan file not found: $PLAN_FILE" >&2
  exit 1
fi
if [ ! -f "$REQUEST_FILE" ]; then
  echo "ERROR: Request file not found: $REQUEST_FILE" >&2
  exit 1
fi

# --- Helper: extract thread_id from JSONL output (M1 fix: use sys.argv) ---
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

# --- Helper: extract and validate JSON from codex output ---
extract_json() {
  local raw="$1"

  # Try: raw output is already valid JSON
  if echo "$raw" | python3 -m json.tool > /dev/null 2>&1; then
    echo "$raw"
    return 0
  fi

  # Try: extract first JSON object
  local json_output
  json_output=$(echo "$raw" | sed -n '/^[[:space:]]*{/,/^[[:space:]]*}/p')
  if [ -n "$json_output" ] && echo "$json_output" | python3 -m json.tool > /dev/null 2>&1; then
    echo "$json_output"
    return 0
  fi

  # Try: strip markdown code fences
  json_output=$(echo "$raw" | sed -n '/```json/,/```/p' | sed '1d;$d')
  if [ -n "$json_output" ] && echo "$json_output" | python3 -m json.tool > /dev/null 2>&1; then
    echo "$json_output"
    return 0
  fi

  return 1
}

# --- Helper: run codex with read-only sandbox (B1 fix) ---
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

# --- Helper: resume codex thread ---
run_codex_resume() {
  local thread_id="$1"
  local prompt="$2"
  local jsonl_tmp="${WORKDIR}/.codex-jsonl-$$.tmp"

  echo "$prompt" | "$CODEX_BIN" exec resume --sandbox read-only --json -o "$CODEX_OUTPUT" "$thread_id" - > "$jsonl_tmp" 2>/dev/null
  local exit_code=$?

  rm -f "$jsonl_tmp"
  return $exit_code
}

# --- Build prompt based on round ---
PREV_VERSION=$((VERSION - 1))

if [ "$VERSION" -eq 1 ]; then
  # ===== ROUND 1: Full prompt =====
  TEMPLATE=$(cat "${TEMPLATE_DIR}/codex-plan-review-prompt.md")
  REQUEST=$(cat "$REQUEST_FILE")
  PLAN=$(cat "$PLAN_FILE")

  PROMPT="${TEMPLATE}"
  PROMPT="${PROMPT//\{\{REQUEST\}\}/$REQUEST}"
  PROMPT="${PROMPT//\{\{PLAN\}\}/$PLAN}"
  PROMPT="${PROMPT//\{\{PREVIOUS_REVIEW_CONTEXT\}\}/}"

  echo "Running Codex plan review Round 1 (new session)..." >&2

else
  # ===== ROUND 2+: Try resume, fallback to full prompt =====
  PLAN=$(cat "$PLAN_FILE")
  RESOLUTION=""
  if [ -f "${WORKDIR}/resolution.v${PREV_VERSION}.md" ]; then
    RESOLUTION=$(cat "${WORKDIR}/resolution.v${PREV_VERSION}.md")
  fi

  # Check if we have a thread to resume
  if [ -f "$THREAD_FILE" ]; then
    THREAD_ID=$(cat "$THREAD_FILE")
    RESUME_PROMPT="Here is the updated plan (v${VERSION}) incorporating your feedback, along with my resolution of your previous issues.

## Resolution of Round ${PREV_VERSION} Issues

${RESOLUTION}

## Updated Plan (v${VERSION})

${PLAN}

Please review this updated plan. Verify that previously raised blocking/major issues have been addressed. Do not re-raise resolved issues. Output valid JSON only, same format as before."

    echo "Running Codex plan review Round ${VERSION} (resuming thread ${THREAD_ID})..." >&2

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

  # Fallback: full stateless prompt
  TEMPLATE=$(cat "${TEMPLATE_DIR}/codex-plan-review-prompt.md")
  REQUEST=$(cat "$REQUEST_FILE")

  PREVIOUS_REVIEW_CONTEXT=""
  PREV_REVIEW_FILE="${WORKDIR}/review.plan.v${PREV_VERSION}.json"
  PREV_RESOLUTION_FILE="${WORKDIR}/resolution.v${PREV_VERSION}.md"

  if [ -f "$PREV_REVIEW_FILE" ]; then
    PREV_REVIEW_CONTENT=$(cat "$PREV_REVIEW_FILE")
    PREVIOUS_REVIEW_CONTEXT="### Previous Review (Round ${PREV_VERSION})

This is a follow-up round. Your previous review raised the issues below. Verify whether blocking/major issues have been addressed. Do not re-raise resolved issues.

\`\`\`json
${PREV_REVIEW_CONTENT}
\`\`\`"
  fi

  if [ -f "$PREV_RESOLUTION_FILE" ]; then
    PREVIOUS_REVIEW_CONTEXT="${PREVIOUS_REVIEW_CONTEXT}

### Claude's Resolution (Round ${PREV_VERSION})

${RESOLUTION}"
  fi

  PROMPT="${TEMPLATE}"
  PROMPT="${PROMPT//\{\{REQUEST\}\}/$REQUEST}"
  PROMPT="${PROMPT//\{\{PLAN\}\}/$PLAN}"
  PROMPT="${PROMPT//\{\{PREVIOUS_REVIEW_CONTEXT\}\}/$PREVIOUS_REVIEW_CONTEXT}"

  echo "Running Codex plan review Round ${VERSION} (stateless fallback)..." >&2
fi

# --- Execute (for Round 1 or fallback) ---
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

# Both attempts failed
echo "Both attempts failed to produce valid JSON. Saving raw output." >&2
RAW=$(cat "$CODEX_OUTPUT" 2>/dev/null || echo "(no output captured)")
echo "$RAW" > "$RAW_FILE"
echo "Raw output saved to: $RAW_FILE" >&2
rm -f "$CODEX_OUTPUT"
exit 1
