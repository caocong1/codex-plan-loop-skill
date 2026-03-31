#!/usr/bin/env bash
# Shared helper functions for Codex review scripts.
# Source this file before using any functions.
#
# Required env vars:
#   CODEX_BIN        — path to codex binary (default: codex)
#   CODEX_TIMEOUT    — timeout in seconds for codex exec (default: 300)
#   CODEX_MODEL      — optional Codex model override

CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_TIMEOUT="${CODEX_TIMEOUT:-300}"
CODEX_MODEL="${CODEX_MODEL:-}"

# --- Helper: extract thread_id from JSONL output ---
extract_thread_id() {
  local jsonl_file="$1"
  python3 - "$jsonl_file" <<'PY' 2>/dev/null
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        tid = obj.get('thread_id') or obj.get('session_id')
        if tid:
            print(tid)
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PY
}

# --- Helper: extract and validate JSON from codex output ---
# Returns 0 and prints JSON on stdout on success, 1 on failure.
extract_json() {
  local raw="$1"
  python3 - "$raw" <<'PY' 2>/dev/null
import json, re, sys

raw = sys.argv[1]

# Try: raw output is already valid JSON
try:
    json.loads(raw)
    print(raw, end='')
    sys.exit(0)
except Exception:
    pass

# Try: find first complete JSON object (handles nested structures)
for m in re.finditer(r'\{', raw):
    start = m.start()
    for end in range(len(raw), start, -1):
        candidate = raw[start:end]
        try:
            json.loads(candidate)
            print(candidate, end='')
            sys.exit(0)
        except Exception:
            pass

# Try: strip markdown code fences
for fence in ['```json\n', '```json\r\n', '```\n', '```\r\n']:
    if fence.strip('` \n\r') in raw:
        inner = raw
        first_fence = inner.find('```')
        if first_fence >= 0:
            inner = inner[first_fence + 3:]
            lines = inner.split('\n', 1)
            if len(lines) > 1:
                inner = lines[1]
            last_fence = inner.rfind('```')
            if last_fence >= 0:
                inner = inner[:last_fence]
            inner = inner.strip()
            try:
                json.loads(inner)
                print(inner, end='')
                sys.exit(0)
            except Exception:
                pass

sys.exit(1)
PY
  return $?
}

# --- Helper: safe template replacement using Python ---
# Replaces all {{KEY}} placeholders in template with provided values.
# Handles special characters (slashes, quotes, newlines) safely.
# Usage: safe_template_replace "template" "KEY1=value1" "KEY2=value2" ...
safe_template_replace() {
  local template="$1"
  shift

  # Build replacements dict and apply in one Python script
  python3 - "$template" "$@" <<'PY' 2>/dev/null
import json, re, sys

template = sys.argv[1]
pairs = sys.argv[2:]

replacements = {}
for pair in pairs:
    if '=' not in pair:
        continue
    key, value = pair.split('=', 1)
    replacements[key] = value

result = template
for key, value in replacements.items():
    placeholder = '{{' + key + '}}'
    result = result.replace(placeholder, value)
print(result, end='')
PY
}

# --- Helper: build codex exec arguments ---
_codex_args() {
  local sandbox_mode="${1:-read-only}"
  local args=(--sandbox "$sandbox_mode" --json)
  if [ -n "$CODEX_TIMEOUT" ]; then
    args+=(--timeout "$CODEX_TIMEOUT")
  fi
  if [ -n "$CODEX_MODEL" ]; then
    args+=(--model "$CODEX_MODEL")
  fi
  printf '%s\n' "${args[@]}"
}

# --- Helper: run codex exec ---
run_codex_exec() {
  local prompt="$1"
  local sandbox_mode="${2:-read-only}"
  local jsonl_tmp="${WORKDIR}/.codex-jsonl-$$.tmp"
  local prompt_tmp="${WORKDIR}/.codex-prompt-$$.tmp"
  local stderr_log="${WORKDIR}/.codex-stderr.log"
  local output_file="${3:-${CODEX_OUTPUT:-${WORKDIR}/.codex-output.txt}}"

  local args
  args=$(_codex_args "$sandbox_mode")

  # Write prompt to temp file to avoid shell pipe issues with large/special-char content
  printf '%s' "$prompt" > "$prompt_tmp"

  # shellcheck disable=SC2086
  cat "$prompt_tmp" | "$CODEX_BIN" exec ${args} -o "$output_file" - > "$jsonl_tmp" 2>"$stderr_log"
  local exit_code=$?

  rm -f "$prompt_tmp"

  if [ $exit_code -ne 0 ] && [ -s "$stderr_log" ]; then
    echo "CODEX STDERR:" >&2
    cat "$stderr_log" >&2
  fi

  # Try to extract and save thread_id
  if ! tid=$(extract_thread_id "$jsonl_tmp"); then
    echo "WARNING: Could not extract thread_id from Codex output. Resume may not work in subsequent rounds." >&2
  else
    echo "$tid" > "$THREAD_FILE"
  fi

  rm -f "$jsonl_tmp"
  return $exit_code
}

# --- Helper: resume codex thread ---
run_codex_resume() {
  local thread_id="$1"
  local prompt="$2"
  local sandbox_mode="${3:-read-only}"
  local jsonl_tmp="${WORKDIR}/.codex-jsonl-$$.tmp"
  local prompt_tmp="${WORKDIR}/.codex-prompt-$$.tmp"
  local stderr_log="${WORKDIR}/.codex-stderr.log"
  local output_file="${4:-${CODEX_OUTPUT:-${WORKDIR}/.codex-output.txt}}"

  local args
  args=$(_codex_args "$sandbox_mode")

  # Write prompt to temp file to avoid shell pipe issues with large/special-char content
  printf '%s' "$prompt" > "$prompt_tmp"

  # shellcheck disable=SC2086
  cat "$prompt_tmp" | "$CODEX_BIN" exec resume ${args} "$thread_id" - > "$jsonl_tmp" 2>"$stderr_log"
  local exit_code=$?

  rm -f "$prompt_tmp"

  if [ $exit_code -ne 0 ] && [ -s "$stderr_log" ]; then
    echo "CODEX STDERR:" >&2
    cat "$stderr_log" >&2
  fi

  # Update thread_id (it may change on resume)
  if tid=$(extract_thread_id "$jsonl_tmp"); then
    echo "$tid" > "$THREAD_FILE"
  fi

  rm -f "$jsonl_tmp"
  return $exit_code
}
