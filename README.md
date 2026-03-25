# codex-plan-loop

A Claude Code skill that adds structured plan review and code review loops powered by OpenAI Codex CLI.

**Claude plans → Codex reviews → Claude revises → execute → Codex code review.**

## Install

```bash
# Clone and install into your project
git clone https://github.com/nicobailon/codex-plan-loop-skill.git /tmp/cpl
bash /tmp/cpl/install.sh /path/to/your/project

# Or install into current directory
bash /tmp/cpl/install.sh
```

For forks, set `REPO_URL`:
```bash
REPO_URL=https://github.com/yourname/codex-plan-loop-skill.git bash /tmp/cpl/install.sh
```

## Uninstall

```bash
bash .claude/skills/codex-plan-loop/uninstall.sh
# Or: rm -rf .claude/skills/codex-plan-loop
```

## Usage

```
/codex-plan-loop <task description>
```

Example:

```
/codex-plan-loop Add user role management with permission checks
```

## Workflow

```
[User Request]
     │
     ▼
[Claude: Generate Plan v1] ──────────────────┐
     │                                        │
     ▼                                        │
[Codex: Review Plan] ◄───────────────────┐    │
     │                                   │    │
     ├─ approved ──► [PHASE 3: Execute]  │    │
     │                                   │    │
     └─ needs_changes ──► [Claude: Write │    │
          Resolution + Next Plan] ───────┘    │
          (max 5 rounds)                      │
                                              │
[Claude: Execute Plan] ◄─────────────────────┘
     │
     ▼
[Claude: Write Change Summary]
     │
     ▼
[Codex: Code Review] ◄──────────────────┐
     │                                   │
     ├─ approved ──► [Final Report]      │
     │                                   │
     └─ needs_changes ──► [Claude: Fix   │
          + Re-test] ────────────────────┘
          (max 5 rounds)
```

## Prerequisites

| Dependency | Minimum Version | Check |
|-----------|----------------|-------|
| **codex** (OpenAI Codex CLI) | >= 0.79.0 | `codex --version` |
| **python3** | >= 3.6 | `python3 --version` |
| **git** | any | `git --version` |
| **bash** | >= 4.0 | `bash --version` |

Install codex: `brew install codex` or `npm i -g @openai/codex`

## What data is sent to Codex

During **plan review**, Codex receives:
- Your task description (`request.md`)
- The plan being reviewed (`plan.vN.md`)
- Previous review + resolution (for follow-up rounds)

During **code review**, Codex receives:
- The final plan
- Change summary written by Claude
- `git diff` scoped to changes made during this run (not the full repo history)
- Test output (if captured)

Codex runs in **read-only sandbox** mode — it cannot modify your files.

**Note:** Do not include secrets, credentials, or sensitive data in your task description or plan content. The diff sent to Codex is scoped to the run baseline (changes made since the skill started), not the entire repository.

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_BIN` | `codex` | Path to codex binary (use for npx or custom installs) |
| `REPO_URL` | *(GitHub URL)* | Override git clone URL in install.sh |

## Directory Structure

```
.claude/skills/codex-plan-loop/
├── SKILL.md                              # Main skill definition
├── README.md                             # This file
├── uninstall.sh                          # Uninstaller
├── scripts/
│   ├── init-workdir.sh                   # Create timestamped work directory + save baseline
│   ├── run-codex-plan-review.sh          # Run Codex plan review (read-only sandbox)
│   ├── run-codex-code-review.sh          # Run Codex code review (read-only sandbox)
│   └── summarize-diff.sh                 # Generate scoped diff summary
└── templates/
    ├── codex-plan-review-prompt.md       # Prompt template for plan review
    └── codex-code-review-prompt.md       # Prompt template for code review
```

## Artifacts (per run)

Each run creates a directory at `.codex-plan-loop/<timestamp>-<slug>/`:

| File | Description |
|------|-------------|
| `request.md` | Original user request |
| `.git-baseline` | Git commit hash at run start (for scoped diffs) |
| `plan.v1.md` ... `plan.v5.md` | Plan versions |
| `review.plan.v1.json` ... | Codex plan review output (structured JSON) |
| `resolution.v1.md` ... | Claude's response to each review |
| `execution-log.md` | Step-by-step execution log |
| `change-summary.md` | Summary of all changes made |
| `test-results.txt` | Test output (if tests were run) |
| `diff-stat.txt` | Git diff statistics (scoped to baseline) |
| `review.code.v1.json` ... | Codex code review output (structured JSON) |
| `final-report.md` | Final summary report |

## Troubleshooting

### `codex exec` fails

1. Check codex is available and version: `codex --version` (need >= 0.79.0)
2. Check raw output in `*.raw.txt` files in the work directory
3. Codex may need authentication — run `codex` interactively first to set up
4. If using npx: `CODEX_BIN="npx codex" /codex-plan-loop ...`

### Invalid JSON from Codex

The scripts automatically retry once. If both attempts fail:
- Raw output is saved to `review.plan.vN.raw.txt` or `review.code.vN.raw.txt`
- Claude will report the failure and ask how to proceed

### Large diffs

If `git diff` exceeds 8000 lines, the code review script truncates it and includes diff stats instead. For very large changes, consider breaking work into smaller tasks.

## Limitations

- Codex uses its default model configuration; no model override in the skill
- Plan and code review rounds are capped at 5 each
- Bash `${//}` substitution in prompt templates may have edge cases with very large artifacts containing special characters
- Tested with codex-cli 0.116.0; minimum supported version is 0.79.0
