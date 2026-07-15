---
name: apply-pr-comments
description:
    Applies human-endorsed (thumbs-up 👍) unresolved PR review threads on an existing open PR, then
    records a remediation trace on the linked slice issue. Only runs when explicitly invoked.
disable-model-invocation: true
---

# Apply PR Comments

Apply human-endorsed, unresolved PR review comments on an existing open PR. The workflow treats
GitHub review threads as the unit of work: it fixes only 👍-endorsed comments on the PR branch,
sizes each fix to decide whether the orchestrator applies it inline or dispatches a `developer`
subagent, defers genuinely out-of-scope requests instead of inventing tracking tickets, and records
a machine-readable remediation trace on the slice issue (with a PR-comment fallback).

**‼️ CRITICAL:** do not use generic agents, use the specific `developer` agents in
`.cursor/agents/developer.md` and the Verifier in `.cursor/agents/verifier.md`.

## Non-Negotiables

1. Require an explicit PR number or URL, or resolve the current PR unambiguously with `gh pr view`.
   If neither works, ask for the PR number.
2. Use the `gh` CLI + GraphQL for PR, thread, reaction, reply, resolution, and slice-issue
   operations. Export shell variables from `docs/work-tracking.md` before any issue write.
3. Act only on unresolved review threads that have a `THUMBS_UP` reaction. Never modify or reply to
   threads without thumbs-up endorsement, except to report they were skipped.
4. Never approve, request-changes, close, merge, or force-push the PR. Push only normal commits to
   the PR head branch after gates pass.
5. Never include secrets, tokens, credentials, or connection strings in code, commits, comments,
   thread replies, logs, or issue bodies. This is a client-side bundle — anything shipped is public.
6. Do not weaken, skip, delete, or rewrite tests to satisfy review feedback. If a gate cannot pass,
   stop and report the failing command and its output.
7. **No tracking tickets.** Do not create follow-up GitHub issues for deferred work. Sizing decides
   only _who applies the fix_ (orchestrator inline vs. a `developer` subagent) — both apply the fix
   in this PR. Work that is genuinely out of scope is **deferred** (replied to and left unresolved),
   never turned into a sub-issue.

## Workflow

### Step 1: Preflight

Resolve the PR context and branch before changing anything.

1. Identify the repository: `gh repo view --json nameWithOwner --jq .nameWithOwner`. Capture
   `GITHUB_OWNER/GITHUB_REPO` for commit links later.
2. Resolve `PR_NUMBER` from the user's request. If absent, try
   `gh pr view --json number --jq .number`; if that fails or is ambiguous, ask the user.
3. Fetch PR metadata:
   `gh pr view "$PR_NUMBER" --json number,title,body,headRefName,baseRefName,author,url,closingIssuesReferences`.
   Capture `HEAD_REF`.
4. Verify `gh auth status` succeeds.
5. Require a clean working tree before checking out the PR head branch. If the tree is dirty
   (outside `.specs/`), stop and ask the user how to proceed.
6. Fetch and check out the PR head branch, then fast-forward only:

```bash
git fetch origin "$HEAD_REF"
git checkout "$HEAD_REF"
git pull --ff-only
```

Never create a new branch. This skill works on the existing open PR branch.

### Step 2: Resolve the slice and load context

Load only what this PR needs.

1. Resolve the slice issue number (`SLICE_NUM`) by preferring, in order: `closingIssuesReferences`
   on the PR; a `gh-issue-N` branch name (capture `N` as `SLICE_NUM`); an explicit `#N` or issue URL
   in the PR title/body; an explicit `.specs/features/...` path in the PR body or a review comment;
   the changed `.specs/features/[feature]/` paths in the diff.
2. If a `SLICE_NUM` is found, read `docs/work-tracking.md` and export `OWNER` and `REPO` — needed to
   write the trace back in Step 8. If no slice issue is found, skip this; the trace goes on the PR
   (Step 8).
3. When the feature folder is resolvable, read `.specs/features/[feature]/spec.md`, `tasks.md`, and
   `validation.md`/`design.md` when present — the acceptance criteria are the source of truth for
   whether a suggestion is correct-as-is or a real gap. If the slice cannot be resolved, continue
   for code fixes only and note the limitation in the final report.

### Step 3: Fetch endorsed unresolved threads

Fetch review threads through GraphQL so resolution state and reactions are available.

```graphql
query ($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
            reviewThreads(first: 100) {
                nodes {
                    id
                    isResolved
                    path
                    line
                    comments(first: 20) {
                        nodes {
                            id
                            body
                            author {
                                login
                            }
                            createdAt
                            reactions(first: 20, content: THUMBS_UP) {
                                totalCount
                                nodes {
                                    user {
                                        login
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
```

Keep a thread only when **all** hold:

1. `isResolved` is `false`.
2. At least one comment in the thread has a `THUMBS_UP` reaction.
3. The thread is still relevant to the current PR diff, or is a PR-level finding that can be tied to
   this PR's scope.

Skip everything else. Report skipped counts, but do not reply to skipped threads.

### Step 4: Triage the endorsed threads

Classify each endorsed thread **before** editing. Parse severity from the `pr-review` marker in the
comment body when present — the markers written by the `pr-review` skill are
`<!-- pr-review:security -->`, `:requirements`, `:tests`, `:architecture`, `:regression`,
`:performance`. Human comments without a marker default to `⚠️ Warning` unless the body clearly
describes a breaking defect or security issue.

Assign each thread to exactly one bucket:

- **Apply inline** — a contained fix (roughly one file / localized change, no new subsystem) the
  orchestrator can make and gate itself.
- **Delegate** — a larger fix (multi-file, non-trivial new logic + tests, or one that would consume
  significant orchestrator context). Dispatch a `developer` subagent (Step 5b). Still lands in this
  PR.
- **Defer** — valid feedback that is genuinely out of scope for this PR: a new user-visible
  feature/behavior, or anything requiring backend changes (those belong in `nuxeo-global-dam`).
  Reply, leave unresolved, and surface it in the report as needing a separate slice. Do **not**
  create a tracking ticket.
- **Decline** — a `Warning`/`Suggestion` where the current implementation is correct by spec,
  conflicts with a logged decision (`.specs/STATE.md` `AD-###`) or design, or is otherwise not
  warranted. **Never** decline a Security or Critical finding without asking the user first.

State the plan before changing files:

```text
Apply inline:
- Thread [id] path:line — [severity] [summary] — gate [command]

Delegate:
- Thread [id] path:line — [severity] [summary] — reason it's too big — gate [command]

Defer:
- Thread [id] — [why out of scope] — suggested follow-up

Decline:
- Thread [id] — [rationale]
```

### Step 5: Apply fixes

Make the smallest change that satisfies the review comment and the slice spec. One atomic commit per
thread (or per group only when threads share the same file and the same behavioral cause). Use
Conventional Commits; when a `SLICE_NUM` is known, reference it in the body (e.g. `Refs: #42`).

For every fix, run the appropriate **gate** and record the result:

- Always: `npm run build` and `npm run lint`.
- Logic / hook / service / reducer change: add or run the co-located Vitest test
  (`npx vitest run <path>`).
- User-flow change with a Playwright spec: `npx playwright test` for the affected spec.
- Docs/i18n-string-only change: no gate, with the reason reported.

If a gate fails, fix the regression if it is clearly caused by the change; otherwise stop and report
the failing command and output — do not reply to or resolve the thread.

#### Step 5a: Inline fixes

Implement directly on the PR head branch, run the gate, re-read touched files for secret/PII leaks
when the fix touches auth/logging/data paths, then commit atomically. Record the full commit hash.

#### Step 5b: Delegated fixes

For each **Delegate** thread, dispatch a fresh `developer` subagent (via the Agent tool,
`subagent_type: "developer"` — its model/effort are pinned in `.cursor/agents/developer.md`, and it
inherits the `tlc-spec-driven` implementer contract). Give it, in the prompt: the PR number and
`HEAD_REF`, the exact thread (path, line, full comment body, severity), the relevant
`spec.md`/`tasks.md` excerpts, the gate command it must pass, and these constraints:

- Make only the change the thread requires; do not refactor unrelated code.
- Frontend-only — no backend/server logic, no `getServerSideProps`/API routes (static export).
- Run the gate; do not weaken tests to pass.
- Commit atomically on `HEAD_REF` with a Conventional Commit (and `Refs: #$SLICE_NUM` when
  provided). Do **not** push.
- Return a compact summary: files changed, the commit hash, the gate result, and a final self-report
  trace line:

    ```text
    Trace — Model: [model] | Effort: [effort] | Token usage: 41% (82k/200k)
    ```

Note the dispatch time and the return time — the elapsed span is that agent's duration for the trace
(Step 8). Delegated subagents run sequentially on the shared branch (they commit to `HEAD_REF`),
never in parallel. Do not spawn nested subagents.

### Step 6: Re-verify when behavior changes

If any fix (inline or delegated) changes acceptance-criteria behavior, validation logic, tests, data
movement, or user-visible flows, dispatch a fresh Verifier (Agent tool, `subagent_type: "verifier"`
— author ≠ verifier, evidence-or-zero). Provide it `spec.md`/`tasks.md`/`validation.md` when
present, the diff from the pre-remediation commit to `HEAD`, the gates that ran, and the list of
threads addressed.

Commit an updated `.specs/features/[feature]/validation.md` if the Verifier writes one. On FAIL, run
at most **3** fix→gate→verify cycles, then stop and report the ranked gaps. Capture the Verifier's
model/effort/token self-report and duration for the trace.

### Step 7: Push, reply, and resolve threads

After every applied fix is committed and gated green:

1. Push the PR branch normally: `git push origin "$HEAD_REF"`. If rejected (non-fast-forward),
   `git pull --rebase`, resolve, and retry; never force-push.
2. Reply to each **applied** thread (inline or delegated) with the commit and gate:

    ```markdown
    <!-- apply-pr-comments:reply -->

    Fixed in [commit]. Gate: `[command]` PASS.
    ```

    Write the commit SHA as **plain text, not wrapped in backticks** — GitHub auto-links a bare SHA
    to the commit page, but silently skips a SHA inside a code span.

3. Reply to each **deferred** thread and leave it unresolved:

    ```markdown
    <!-- apply-pr-comments:reply -->

    Valid, but out of scope for this PR ([reason — e.g. new feature / backend change belongs in
    nuxeo-global-dam]). Leaving unresolved so it can be planned as a separate slice.
    ```

4. Reply to each **declined** thread and leave it unresolved:

    ```markdown
    <!-- apply-pr-comments:reply -->

    Not applying this: [spec/design/AD-### reason]. Leaving the thread unresolved for human
    confirmation.
    ```

5. Resolve **only** applied threads via GraphQL:

    ```graphql
    mutation ($threadId: ID!) {
        resolveReviewThread(input: { threadId: $threadId }) {
            thread {
                id
                isResolved
            }
        }
    }
    ```

If resolution fails after the push, do not retry indefinitely — report the failed thread IDs and the
fix commits.

### Step 8: Record the remediation trace

Assemble the trace: each fix's thread → action → commit, plus a per-agent table (orchestrator + any
`developer` workers + Verifier) with self-reported model/effort/token usage and
orchestrator-measured duration.

```markdown
<!-- pr-comment-remediation:begin -->

## PR Comment Remediation

**Pull request**: [#45 favorites-collections](https://github.com/acme/repo/pull/45) **Remediated**:
2026-07-08 **Threads**: 3 applied · 1 deferred · 1 declined (of 5 endorsed)

### Threads

| Thread                            | Severity      | Action              | Commit / Note                                             |
| --------------------------------- | ------------- | ------------------- | --------------------------------------------------------- |
| `src/shared/assets.js:42`         | 🔒 Security   | Applied (inline)    | [abc1234](https://github.com/acme/repo/commit/abc1234...) |
| `src/components/Grid/Grid.jsx:18` | ⚠️ Warning    | Applied (developer) | [def5678](https://github.com/acme/repo/commit/def5678...) |
| PR-level requirements             | 💡 Suggestion | Deferred            | New slice — bulk export                                   |
| `src/utils/format.js:7`           | 💡 Suggestion | Declined            | Correct per AD-004                                        |

### Agent Trace

| Agent             | Model   | Effort   | Token usage    | Duration |
| ----------------- | ------- | -------- | -------------- | -------- |
| Orchestrator      | [model] | [effort] | 24% (48k/200k) | 8m 12s   |
| Worker (Grid fix) | [model] | [effort] | 41% (82k/200k) | 5m 03s   |
| Verifier          | [model] | [effort] | 22% (44k/200k) | 4m 27s   |

---

<!-- pr-comment-remediation:end -->
```

- The block is delimited by `<!-- pr-comment-remediation:begin -->` and
  `<!-- pr-comment-remediation:end -->`. On re-fetch, replace only that region.
- Commit links use the full hash in the URL and the 7-char short hash as link text
  (`[abc1234](url)`). Applies to every link in the block.

**Issue case** (`SLICE_NUM` found in Step 2):

1. Fetch the current body with `gh issue view "$SLICE_NUM" --repo "$REPO" --json body --jq .body`.
   Preserve everything else and replace **only** this skill's own block — from
   `<!-- pr-comment-remediation:begin -->` through `<!-- pr-comment-remediation:end -->` (append a
   new block, wrapped in those markers, if absent). **Never** write inside another skill's block
   (`sdd-tasks-gh`, `<!-- plan:begin/end -->`, `<!-- execution:begin/end -->`,
   `<!-- pr-review:begin/end -->`). Apply with
   `gh issue edit "$SLICE_NUM" --repo "$REPO" --body-file /tmp/slice-body.md`.
2. Post a brief closing comment:

    ```bash
    gh issue comment "$SLICE_NUM" --repo "$REPO" --body "PR comment remediation complete on #45 — 3 applied, 1 deferred, 1 declined. Trace recorded on the issue."
    ```

**No-issue case**: post the trace block (without its `<!-- pr-comment-remediation:begin/end -->`
markers) as a PR comment inside a collapsible `<details>`, noting that no linked slice issue was
found so the trace lives on the PR.

```markdown
<details><summary>🔧 PR Comment Remediation Trace</summary>

{the trace block from above, without the begin/end markers}

</details>
```

### Step 9: Report to the user

Output a concise summary:

- PR number + URL and the head branch.
- Applied threads with commit hashes and gates; whether each was inline or delegated.
- Deferred threads with the out-of-scope reason and suggested follow-up.
- Declined threads with rationale.
- Resolved-thread count and any unresolved/failure IDs.
- The **Agent Trace** table — the same one written to the issue/PR.
- Where the trace was recorded (slice issue `https://github.com/$OWNER/$REPO/issues/$SLICE_NUM`, or
  the PR comment), and — in the issue case — confirmation that only the
  `<!-- pr-comment-remediation:begin/end -->` block was written.
