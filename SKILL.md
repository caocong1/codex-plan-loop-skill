---
name: codex-plan-loop
description: "Claude plans -> Codex reviews -> Claude revises -> execute -> Codex code review. Iterative plan+code review loop with structured JSON artifacts. Use --plan-only to stop after plan approval without executing."
disable-model-invocation: true
effort: high
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
  - TodoWrite
---

# Codex Plan Loop

You are executing the **codex-plan-loop** workflow. This is a structured, artifact-driven workflow where Claude plans, Codex reviews, and iteration continues until quality gates are met.

**User request:** $ARGUMENTS

---

## Flags

Parse `$ARGUMENTS` for the following flags before extracting the user request:

- `--plan-only`: Stop after the plan is approved (skip execution and code review phases). Remove this flag from the user request text before saving to `request.md`.
- `--resume <path>`: Resume from an existing workdir. Detect the last completed phase from artifact files and continue from the next phase. When using this flag, skip PHASE 1 initialization and load state from the specified workdir.

Example: `/codex-plan-loop --plan-only refactor the auth module` → flag `plan-only` is set, user request is `refactor the auth module`.

**Resume detection logic:**
1. If `final-report.md` exists → workflow already completed, report to user and stop.
2. If `review.code.v*.json` exists → PHASE 4 (code review) was last. Detect latest round, continue from next code review round.
3. If `change-summary.md` exists → PHASE 3 (execution) was last. Run code review (PHASE 4).
4. If `execution-log.md` exists → PHASE 3 was interrupted. Resume from where it left off.
5. If `plan.v*.md` and `review.plan.v*.json` exist → PHASE 2 completed. Run execution (PHASE 3).
6. If only `plan.v*.md` exists → Plan was generated but not reviewed. Start plan review.
7. Otherwise → No artifacts found, start from PHASE 1.

Example: `/codex-plan-loop --resume /path/to/project/.codex-plan-loop/20260327-1200-my-task`

---

## Constants

- `MAX_PLAN_ROUNDS = 10`
- `MAX_CODE_REVIEW_ROUNDS = 10`
- `PROJECT_ROOT` = the current working directory
- `SKILL_DIR` = `.claude/skills/codex-plan-loop`
- `SCRIPTS_DIR` = `.claude/skills/codex-plan-loop/scripts`

---

## PHASE 1: Initialize

1. Create the working directory by running:
   ```bash
   WORKDIR=$("${SCRIPTS_DIR}/init-workdir.sh" "$PROJECT_ROOT" "<short-slug-from-task>")
   ```
2. Write the user's request to `$WORKDIR/request.md` verbatim.
3. Announce the working directory path to the user.

---

## PHASE 2: Plan + Review Loop

### Step 2.1: Generate Plan v1

Read the codebase as needed to understand the current state. Then write `$WORKDIR/plan.v1.md` containing:

- **Goal**: What we're trying to achieve
- **Scope**: What's included
- **Non-goals**: What's explicitly excluded
- **Risks**: Known risks and mitigations
- **Files to modify**: List of files expected to change
- **Implementation steps**: Numbered, concrete steps
- **Testing strategy**: How to verify correctness
- **Rollback strategy**: How to undo if needed (if applicable)

### Step 2.2: Codex Plan Review Loop

For `round = 1` to `MAX_PLAN_ROUNDS`:

1. **Run Codex review** by executing:
   ```bash
   bash "${SCRIPTS_DIR}/run-codex-plan-review.sh" "$WORKDIR" $round
   ```

2. **Read the review** from `$WORKDIR/review.plan.v${round}.json`.

3. **Check termination conditions:**
   - If `status == "approved"` OR (`blocking` is empty AND `major` is empty): **Plan approved. Exit loop.**
   - If `round == MAX_PLAN_ROUNDS` and there are still `blocking` or `major` issues:
     - **STOP. Tell the user** there are unresolved blocking/major issues after max rounds.
     - Show all unresolved blocking and major issues.
     - Ask the user whether to proceed with execution anyway or abort.
     - Do NOT silently proceed.

4. **Generate resolution**: Write `$WORKDIR/resolution.v${round}.md` addressing EVERY issue from the review:
   ```
   ## Resolution for Review Round {round}

   | ID | Severity | Decision | Action Taken | Rationale |
   |----|----------|----------|-------------|-----------|
   | P1 | blocking | accept   | Rewrote X   | Reviewer is correct, this was missing |
   | P2 | major    | partially_accept | Added Y but kept Z | Z is needed because... |
   | P3 | minor    | reject   | No change | This is intentional because... |
   ```

5. **Generate next plan version**: Write `$WORKDIR/plan.v${next_round}.md` incorporating accepted changes.

6. Continue to next round.

### Important rules for this phase:
- Do NOT start coding until the plan is approved.
- Do NOT skip writing resolution files.
- Do NOT feed entire chat history to Codex — only artifacts in the workdir.
- If the review script fails (exit code != 0), check for `*.raw.txt` files and report to user.

---

## PHASE 2.5: Plan-Only Exit

If the `--plan-only` flag is set and the plan is approved:

1. **Announce**: Tell the user the final approved plan version.
2. **Write `$WORKDIR/final-report.md`**:
   ```markdown
   # Final Report (Plan Only)

   ## Task
   <original user request>

   ## Plan
   - Final plan version: vN
   - Plan review rounds: N
   - Unresolved plan issues: <list or "none">

   ## Approved Plan
   <full content of the final approved plan>

   ## Next Steps
   To execute this plan, run the skill again without --plan-only, or manually follow the steps in the approved plan.
   ```
3. **Print a summary to the user** including:
   - Working directory path
   - How many plan rounds occurred
   - Final plan version
   - Any minor issues noted but not blocking
4. **Stop. Do NOT proceed to Phase 3, 4, or 5.**

---

## PHASE 3: Execution

Once the plan is approved (and `--plan-only` is NOT set):

1. **Announce**: Tell the user which plan version is final and that execution is starting.

2. **Execute the plan** step by step:
   - Use TodoWrite to track progress through implementation steps.
   - Make changes incrementally.
   - Run tests/lint/build as specified in the plan's testing strategy.
   - Log key actions to `$WORKDIR/execution-log.md` as you go. Format:
     ```
     ## Step N: <description>
     - Action: <what was done>
     - Result: <outcome>
     - Files changed: <list>
     ```

3. **Track acceptance checklist**: Read the final approved plan's `review.plan.v*.json` to find the `acceptance_checklist` field. Write each item as a checkbox in the execution log:
   ```
   ## Acceptance Checklist
   - [ ] <checklist item 1>
   - [ ] <checklist item 2>
   ```
   As you execute, mark each item `[x]` when verified. If an item cannot be met, note the reason.

4. **Capture test results**: If tests were run, save output to `$WORKDIR/test-results.txt`.

5. **Generate change summary**: Write `$WORKDIR/change-summary.md` containing:
   - List of all modified files with brief description of each change
   - Why each change was made (trace back to plan)
   - Tests that were run and their results
   - Remaining risks or known issues

6. **Generate diff summary**:
   ```bash
   bash "${SCRIPTS_DIR}/summarize-diff.sh" "$PROJECT_ROOT" "$WORKDIR"
   ```

---

## PHASE 4: Code Review Loop

### Step 4.1: Run Codex Code Review

For `round = 1` to `MAX_CODE_REVIEW_ROUNDS`:

1. **Run Codex code review**:
   ```bash
   bash "${SCRIPTS_DIR}/run-codex-code-review.sh" "$WORKDIR" $round "$PROJECT_ROOT"
   ```

2. **Read the review** from `$WORKDIR/review.code.v${round}.json`.

3. **Check termination conditions:**
   - If `status == "approved"` OR (`blocking` is empty AND `major` is empty): **Code approved. Exit loop.**
   - If `round == MAX_CODE_REVIEW_ROUNDS` and there are still `blocking` or `major` issues:
     - **STOP. Tell the user** about unresolved blocking/major issues.
     - Ask the user whether to accept as-is or continue fixing manually.
     - Do NOT silently proceed.

4. **If fixes needed**: Apply fixes for `blocking` and `major` issues. Then:
   - Run tests again.
   - Update `$WORKDIR/change-summary.md`.
   - Update `$WORKDIR/test-results.txt` if tests were re-run.
   - Run `summarize-diff.sh` again.
   - Continue to next round.

### Important rules for this phase:
- Only fix `blocking` and `major` issues in the loop. `minor` items are noted but don't block.
- Do NOT let the code review expand scope beyond what was planned.
- If the review script fails, check for `*.raw.txt` and report to user.

---

## PHASE 5: Final Report

Write `$WORKDIR/final-report.md` containing:

```markdown
# Final Report

## Task
<original user request>

## Plan
- Final plan version: vN
- Plan review rounds: N
- Unresolved plan issues: <list or "none">

## Execution
- Files modified: <count>
- Tests run: <summary>
- Build status: <pass/fail/not applicable>

## Code Review
- Code review rounds: N
- Final status: <approved / approved with minor issues / unresolved blocking>
- Unresolved issues: <list or "none">

## Files Changed
<list each file with one-line description>

## Remaining Risks
<list or "none">

## Follow-ups
<list items from code review followups, or "none">
```

Then **print a summary to the user** including:
- Working directory path
- How many plan rounds and code review rounds occurred
- Final status
- Any items needing attention

---

## Error Handling

- If `codex exec` fails or produces invalid JSON after 2 retries, **do not loop forever**. Save raw output to `*.raw.txt`, inform the user, and ask how to proceed.
- If any phase fails unexpectedly, **preserve all artifacts** in the working directory. Never delete the workdir.
- If you are uncertain about anything, **write current state to files first**, then ask the user.

---

## Behavioral Constraints

1. Plan first, execute later. Never code before plan approval.
2. Never share chat history with Codex — only file artifacts.
3. All reviews must be persisted as files. No ephemeral reviews.
4. Every revision must have a corresponding resolution file.
5. Stop the plan loop when high-priority issues are cleared.
6. Code review only examines the actual changes, not the whole repo.
7. When uncertain, write state to files and ask the user.
8. Keep Codex prompts focused — plan review stays on plan quality, code review stays on code quality. No scope drift between phases.
