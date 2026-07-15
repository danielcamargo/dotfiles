---
name: execute-plan
description: Runs the Execution phase for one GitHub slice issue. Only runs when explicitly invoked.
disable-model-invocation: true
---

# Execute Plan

Runs the **Execution** phase of the spec-driven flow for one slice. Planning is already done and
finalized (`.cursor/rules/spec-driven-flow.mdc`); this skill is the execution session that turns an
approved `tasks.md` into committed, verified code on the slice branch — and leaves a
machine-readable trail on the slice issue for later analysis. It does five things and nothing else:

1. **Transitions** the slice issue to **In Progress** on the project board before any code is
   written.
2. **Executes** the feature's `tasks.md` through `tlc-spec-driven`'s Execute phase — sub-agent
   workers for the tasks, then a fresh, always-on **Verifier** (author ≠ verifier).
3. **Pushes** the slice branch and **opens a GitHub PR** — only after the Verifier passes.
4. **Transitions** the slice issue to **In Review** and links the PR.
5. **Records** an execution trace on the slice issue inside its own managed block — delimited by
   `<!-- execution:begin -->` and `<!-- execution:end -->`: a per-agent table (model, effort, token
   usage) and a per-task commit table.

Use the `gh` CLI + `git` for all issue, project-board, branch, and PR operations. Export the shell
variables from `docs/work-tracking.md` before any `gh` command — never hard-code IDs from memory.

## Requirements

This skill reads (never guesses) the following.

### Files

- `docs/work-tracking.md` — `OWNER`, `REPO`, `PROJECT_NUM`, `PROJECT_ID`, `STATUS_FIELD`, status
  option IDs
- `.cursor/rules/spec-driven-flow.mdc` — the planning/execution session boundary
- `.specs/features/[feature]/spec.md` — acceptance criteria (the Verifier's source of truth)
- `.specs/features/[feature]/tasks.md` — the tasks to execute (`design.md` is optional)

### Skills

- `tlc-spec-driven` — its `references/implement.md`, `references/sub-agents.md`, and
  `references/validate.md` define the execution contract, batching, and verification this skill
  orchestrates

### CLIs

- `git` + `gh` (authenticated, `project` scope) — commit, push, issue/board updates, and open the PR

## Instructions

### Step 1: Preflight gate — fail fast, before any side effects

Stop at the first failure; report all failures in one consolidated list. A failed preflight with
zero side effects is fully recoverable — a half-executed slice is not.

1. **Session boundary (NON-NEGOTIABLE).** Confirm this is a _fresh execution session_ per
   `.cursor/rules/spec-driven-flow.mdc`: planning and execution never share a session. If the
   current session authored or finalized the spec, STOP and tell the user to start execution in a
   new session.
2. **Inputs.** The user provides the slice issue number (e.g. `42` or `#42`) and a file reference to
   the feature (`@.specs/features/[feature]/tasks.md` or the folder). Derive `[feature]` from it.
   Capture `SLICE_NUM` (digits only). If either is missing, ask — never scan for or guess the slice
   or feature.
3. **Files.** `.specs/features/[feature]/` contains `tasks.md` and `spec.md`. `tasks.md` is
   well-formed (a Task Breakdown where every task has at least an ID and title). If malformed, do
   not guess — it is regenerated via `tlc-spec-driven`.
4. **Config.** `docs/work-tracking.md` is readable; export `OWNER`, `REPO`, `PROJECT_NUM`,
   `PROJECT_ID`, `STATUS_FIELD`, and status option IDs into the shell session.
5. **GitHub auth.** `gh auth status` succeeds and the token has the `project` scope.
   `gh issue view "$SLICE_NUM" --repo "$REPO"` succeeds — capture the issue URL and current board
   status if visible.
6. **Git/PR readiness.** The working tree has no uncommitted changes outside `.specs/` (if it does,
   STOP and ask). `gh auth status` succeeds — the PR at the end depends on it.

### Step 2: Establish the slice branch

Every artifact of the slice lives on one branch. Derive the branch name from the issue number:

```bash
SLICE_BRANCH="gh-issue-$(printf '%04d' "$SLICE_NUM")"
```

- If the branch exists locally or on the remote, check it out — execution may be resuming.
- Otherwise create it from the repo's default branch, resolved live (never hard-coded):

```bash
git fetch origin && git checkout -b "$SLICE_BRANCH" "origin/$(git remote show origin | awk '/HEAD branch/ {print $NF}')"
```

Capture `GITHUB_OWNER/GITHUB_REPO` from `git remote get-url origin` — you need them for commit and
PR links later.

### Step 3: Move the slice issue to In Progress

This is the first side effect and the signal that execution has begun.

1. Assign the slice issue to yourself
   (`gh issue edit "$SLICE_NUM" --repo "$REPO" --add-assignee @me` — skip if already assigned, never
   remove other assignees).
2. Resolve the issue's project-board item and set Status to **In Progress**:

```bash
ITEM_ID=$(gh project item-list "$PROJECT_NUM" --owner "$OWNER" --limit 500 --format json \
  --jq ".items[] | select(.content.type==\"Issue\" and .content.number==$SLICE_NUM) | .id" | head -1)
if [ -z "$ITEM_ID" ]; then
  ISSUE_URL=$(gh issue view "$SLICE_NUM" --repo "$REPO" --json url --jq .url)
  ITEM_ID=$(gh project item-add "$PROJECT_NUM" --owner "$OWNER" --url "$ISSUE_URL" --format json --jq .id)
fi
gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
  --field-id "$STATUS_FIELD" --single-select-option-id "$STATUS_IN_PROGRESS"
```

If the issue is already In Progress on the board, skip the status edit. If the board field IDs are
stale, STOP and report — do not guess.

Post a brief starting comment:

```bash
gh issue comment "$SLICE_NUM" --repo "$REPO" --body "Execution started on branch \`$SLICE_BRANCH\`. Running tasks from .specs/features/[feature]/tasks.md."
```

### Step 4: Execute tasks.md via the tlc-spec-driven Execute phase

Read `tlc-spec-driven`'s `references/implement.md` completely before executing, and follow its
execution contract exactly: tests derive from the spec's acceptance criteria; the gate must pass
before a task is done; **one atomic commit per task**; never weaken or skip tests to pass.

**Delegation (per `references/sub-agents.md`):** count the tasks. If they pack into more than one
~7-task batch (> ~8 tasks), present the offer-then-confirm sub-agent proposal and wait for the user
to accept; each worker owns whole consecutive phases (~7 tasks), runs its tasks in order (implement
→ gate → atomic commit), and batches run strictly sequentially. If ≤ ~8 tasks (or the user
declines), execute inline in the orchestrator window.

**Always-on Verifier:** after the last task is committed, dispatch a fresh Verifier automatically
(never prompted, author ≠ verifier). It runs the spec-anchored coverage check + discrimination
sensor, writes `.specs/features/[feature]/validation.md`, and returns a compact verdict. If it
returns FAIL, route the ranked gaps to a fix pass and re-dispatch the Verifier — bounded to **3
iterations**; if gaps remain, STOP before the PR and escalate to the user.

**Capture the trace as you go — this is what the skill exists to record.** Extend each worker's and
the Verifier's compact summary with a final self-report line so nothing has to be reconstructed
afterward:

```text
Trace — Model: [model] | Effort: [effort] | Token usage: 52% (104k/200k)
```

For every `developer` agent (the orchestrator itself, each batch worker, and the Verifier) record: a
label (with the phases/tasks it covered), the friendly **model name**, the **model effort** (high |
medium | low), approximate **token usage** (`k` suffix, rounded percentage, e.g. `52% (104k/200k)`),
and **duration**. Model, effort, and token usage are self-reported by the agent and approximate —
the same convention `finalize-plan` uses. **Duration is wall-clock measured by the orchestrator**,
not the agent: note the time when you dispatch a worker/Verifier and again when its summary returns,
and record the elapsed span (e.g. `14m 03s`); for inline execution, time each segment (task work vs.
Verifier) yourself. For every task, record its **full commit hash** (from the worker summaries /
`git log`) so the commit table can link to it. Do not open the PR until the Verifier verdict is
PASS.

**‼️ CRITICAL:** do not use generic agents, use the specific `developer` agents in
`.cursor/agents/developer.md` and the Verifier in `.cursor/agents/verifier.md`. The orchestrator is
always the same agent, but each worker and the Verifier are separate agents with their own pins and
self-reports.

### Step 5: Push the branch and open the PR

Only on a PASS verdict:

1. `git push -u origin "$SLICE_BRANCH"`. If the push is rejected (non-fast-forward), pull with
   rebase, resolve, and retry; if that fails, report the divergence rather than forcing.
2. Open the PR against the default branch with `gh pr create`:

```bash
gh pr create --base "$(git remote show origin | awk '/HEAD branch/ {print $NF}')" \
  --head "$SLICE_BRANCH" \
  --title "[feature] <slice statement>" \
  --body "<body>"
```

PR body: the slice issue link (`https://github.com/$OWNER/$REPO/issues/$SLICE_NUM`), a one-line
feature summary, the Verifier verdict, and links to `spec.md` and `validation.md` on the branch.
Capture the PR number and URL.

### Step 6: Transition the slice issue to In Review

Using the same `ITEM_ID` lookup from Step 3, set Status to **In Review** with `$STATUS_IN_REVIEW`.
If the board update fails, leave the slice In Progress and report this in the final summary — do not
substitute an arbitrary status.

### Step 7: Record the execution trace on the slice issue

Fetch the current body with `gh issue view "$SLICE_NUM" --repo "$REPO" --json body --jq .body`.
Preserve everything else and replace **only** this skill's own block — from
`<!-- execution:begin -->` through `<!-- execution:end -->` (append a new block, wrapped in those
markers, if absent).

```markdown
<!-- execution:begin -->

## Execution

**Branch**: `gh-issue-0042` **Pull request**:
[#123 asset-bulk-export](https://github.com/acme/repo/pull/123) **Executed**: 2026-07-08 **Verifier
verdict**: PASS ✅ (12/12 ACs matched, 3 mutations killed)

### Agent Trace

| Agent                          | Model   | Effort   | Token usage     | Duration |
| ------------------------------ | ------- | -------- | --------------- | -------- |
| Orchestrator                   | [model] | [effort] | 38% (76k/200k)  | 6m 12s   |
| Worker 1 (Phases 1–2 · T1–T7)  | [model] | [effort] | 52% (104k/200k) | 14m 03s  |
| Worker 2 (Phases 3–4 · T8–T12) | [model] | [effort] | 41% (82k/200k)  | 11m 48s  |
| Verifier                       | [model] | [effort] | 22% (44k/200k)  | 4m 27s   |

### Tasks & Commits

| Task                    | Commit                                                    |
| ----------------------- | --------------------------------------------------------- |
| T1: Create X interface  | [abc1234](https://github.com/acme/repo/commit/abc1234...) |
| T2: Implement Y service | [def5678](https://github.com/acme/repo/commit/def5678...) |

<!-- execution:end -->
```

- **Agent Trace** has one row per agent — orchestrator, every batch worker, and the Verifier — each
  with model, effort, self-reported token usage, and orchestrator-measured duration from Step 4.
  When executing inline (no workers), the orchestrator row alone carries the task work; the Verifier
  still gets its own row.
- **Tasks & Commits** has one row per task in `tasks.md`, in order. Each commit links to
  `https://github.com/$GITHUB_OWNER/$GITHUB_REPO/commit/<full-hash>` — use the full hash in the URL
  and the 7-char short hash as the link text (`[abc1234](url)`).

Write the updated body to a temp file and apply with
`gh issue edit "$SLICE_NUM" --repo "$REPO" --body-file /tmp/slice-body.md`.

Then post a closing comment:

```bash
gh issue comment "$SLICE_NUM" --repo "$REPO" --body "Execution complete — [N] tasks committed on \`$SLICE_BRANCH\`, Verifier PASS. PR: <pr-url>. Slice moved to In Review."
```

### Step 8: Report to the user

Output a concise summary:

- Slice issue `#$SLICE_NUM` + URL, and its status transitions (Todo → In Progress → In Review).
- Tasks completed with commit hashes, and the Verifier verdict.
- The PR URL.
- The **Agent Trace** table (agent, model, effort, token usage, duration) — the same one written to
  the issue.
- Confirmation that the `<!-- execution:begin/end -->` block was written and no other skill's block
  was touched.
