---
name: finalize-plan
description:
    Closes the planning session for a slice — records the repo spec artifact paths on the GitHub
    slice issue and the planning session's model + token usage. Only runs when explicitly invoked.
disable-model-invocation: true
---

# Finalize Plan

Approves the spec and marks the **Plan** phase of the spec-driven flow as done for one slice, so the
**Execution** phase can begin from a stable baseline. Planning and execution are two separate
sessions (`.cursor/rules/spec-driven-flow.mdc`); this skill is the gate between them. It does two
things and nothing else:

1. **Enriches** the GitHub slice issue with repo-relative paths to the feature's in-repo planning
   artifacts (`.specs/features/[feature]/spec.md`, `design.md`, `tasks.md`) inside this skill's own
   managed block, delimited by `<!-- plan:begin -->` and `<!-- plan:end -->`.
2. **Records** an execution trace of the planning session — the model used and its token usage —
   inside that same block under `### Agent Trace`.

Specs stay in the repo — this skill does **not** publish to Confluence or any external wiki. It does
**not** write or push code, create the slice branch, or run any Execution-phase work. Scope is the
slice issue only.

## Requirements

- `docs/work-tracking.md` — export `OWNER` and `REPO` for issue URLs (never hard-code them)
- The user provides the slice issue number (e.g. `42` or `#42`) and the feature spec path
- Planning artifacts exist under `.specs/features/[feature]/` and are committed and pushed to the
  repo default branch

## Instructions

### Step 1: Preflight gate — fail fast, before any side effects

- Verify the requirements above are present and readable. Stop if any are missing.
- You know, unequivocally, which spec (`.specs/features/[feature]/spec.md`) and slice (GitHub issue
  `#$SLICE_NUM`) is being finalized.
- Confirm `spec.md`, `design.md`, and `tasks.md` exist on disk under `.specs/features/[feature]/`.
  If `design.md` was intentionally skipped for a trivial slice, stop and report — finalizing expects
  the full planning set unless the user explicitly confirms otherwise.
- Resolve the default branch:
  `DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq -r .defaultBranchRef.name)`
- Confirm each artifact is tracked and present on the remote default branch (e.g.
  `git ls-files --error-unmatch .specs/features/[feature]/spec.md` and
  `git cat-file -e "origin/$DEFAULT_BRANCH:.specs/features/[feature]/spec.md"`). If any file is
  missing locally, untracked, or not pushed, STOP and tell the user to commit and push the planning
  artifacts before re-running.

If any of the conditions are not met, stop and report the problem. Do not attempt to finalize
partial or incomplete planning artifacts.

### Step 2: Capture repo artifact paths

Record the canonical repo-relative paths for the issue block:

```text
Feature folder: .specs/features/[feature]/
Spec:           .specs/features/[feature]/spec.md
Design:         .specs/features/[feature]/design.md
Tasks:          .specs/features/[feature]/tasks.md
```

### Step 3: Enrich the slice issue — paths + planning trace

Update the slice issue description inside this skill's OWN block. It is the first generated block on
the issue, delimited by `<!-- plan:begin -->` and `<!-- plan:end -->` HTML comments (separating it
from the human-written description above). The block spans `## Planning` and `### Agent Trace`.
Fetch the current body with `gh issue view "$SLICE_NUM" --repo "$REPO" --json body --jq .body`,
preserve everything else, and replace only that region — from `<!-- plan:begin -->` through
`<!-- plan:end -->` (append a new block, wrapped in those markers, if absent).

```markdown
## <!-- plan:begin -->

---

## Planning

- **Feature folder**: `.specs/features/[feature]/`
    - Spec: `.specs/features/[feature]/spec.md`
    - Design: `.specs/features/[feature]/design.md`
    - Tasks: `.specs/features/[feature]/tasks.md`

### Agent Trace

**Model**: [model] ([effort]) **Token usage**: 45% (90k/200k) **Planning finalized**: 2026-07-08

**Skills & docs consumed**:

- `.agents/skills/tlc-spec-driven/references/specify.md`
- `.agents/skills/tlc-spec-driven/references/design.md`
- `.agents/skills/tlc-spec-driven/references/tasks.md`
- `.specs/features/[feature]/spec.md`
- `docs/work-tracking.md`

---

<!-- plan:end -->
```

The **Agent Trace** describes the session that produced the spec — i.e. the current
`/tlc-spec-driven` planning session, not a future execution. Report:

- **Model**: the friendly name and effort of the model running this planning session.
- **Token usage**: approximate context used vs. the window size (`k` suffix, rounded percentage,
  e.g. `45% (90k/200k)). This is self-reported and approximate.
- **Skills & docs consumed**: the planning references and spec files actually read this session.

Write the updated body to a temp file and apply with
`gh issue edit "$SLICE_NUM" --repo "$REPO" --body-file /tmp/slice-body.md`.

### Step 4: Mark planning finalized on the board

Post a closing comment on the slice issue:

```bash
gh issue comment "$SLICE_NUM" --repo "$REPO" --body "Planning finalized — spec/design/tasks at \`.specs/features/[feature]/\`. Ready for execution."
```

### Step 5: Report to the user

Output a concise summary:

- The feature folder path and each artifact path (Spec, Design, Tasks).
- The slice issue URL (`https://github.com/$OWNER/$REPO/issues/$SLICE_NUM`) and confirmation the
  `finalize-plan` block was written.
- The Agent Trace values (model + effort, token usage).
- Reminder that execution must start in a **new session** (`.cursor/rules/spec-driven-flow.mdc`).
