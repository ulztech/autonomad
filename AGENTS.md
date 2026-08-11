# Autonomad — Agent Behavioral Rules (v1)

This file governs every Autonomad agent (the tick loop, the dev agent, the
harvest/report scripts). It is the machine-readable contract of Autonomad's
**bounded autonomy**.

---

## Rule 1: Autonomy boundary (non-negotiable)

Autonomad **develops** and **opens PRs**. It **never**:

- merges or rebases its own PRs
- auto-applies the `approved` label (that is the human's job)
- auto-closes issues that are `pending-review`
- writes to the AIOS brain (it is mounted read-only, always)
- commits secrets or `.env` files

Success close-out ends at: **PR created + `pending-review` label + report generated. Stop.**

---

## Rule 2: Halt triggers → `needs-human`

Autonomad halts and labels the issue `needs-human` (and leaves a comment) when ANY of:

1. Plan confidence reported by the dev agent **< 0.90**
2. Plan escalation / fatal flaw detected (agent returns escalation marker)
3. **N = max_retries (2) failed dev attempts** on the same issue (hard stop)
4. Missing/empty `pipeline-state.json` at any gate read (fails closed)

When halted: the branch stays, the state file stays (clean state + comment), the
tick loop moves on and never retries that issue automatically.

---

## Rule 3: Label state machine

```
                claim (atomic: assign bot + remove autonomous + add in-progress)
 autonomous ────────────────────────────────────────────────► in-progress
     ▲                                                             │
     │ new issue                                                   │
     │                                                             │  develop green
     │                                                             ▼
     │                                                     pending-review ◄── PR created, "Fixes #N"
     │                                                             ▲
     │                                                     reviewing │  human picks up
     │                                                             │
     │                                                    approved  │  human approves
     │                                                             │
     │                                                             └── (human merges; issue closes)
     │
     └──── needs-human ◄─── halt trigger (confidence<90 / fatal flaw / N=2 retries)
```

Transitions owned by:
- **Autonomad:** `autonomous → in-progress` (atomic claim), `in-progress → pending-review` (green close-out), `in-progress/any → needs-human` (halt).
- **Human only:** `pending-review → reviewing → approved`, merge, and any label the bot did not set.

Autonomad only ever **picks** issues with `label:autonomous` and no assignee.
It never acts on `pending-review`, `reviewing`, `approved`, or `needs-human` issues.

---

## Rule 4: Runtime flow (per tick)

1. **Poll** — `gh issue list --label autonomous --assignee=none --limit 1`. None → idle-sleep (`poll_interval`), exit on idle timeout or `--once`.
2. **Claim** — `gh issue edit <N> --add-assignee <bot> --remove-label autonomous --add-label in-progress` (atomic).
3. **Gate 0** — create branch, write + commit `pipeline-state.json`, log decision.
4. **Provision** — one dev sandbox container per issue: AIOS brain mounted read-only (corrected paths), marketplace wired via `skills.paths`, `.env` injected.
5. **Adapt** — run adapter `run-agent` with the assembled prompt (issue body + build/test commands + model + brain path + gate state).
6. **Gate discipline** — each gate: test-only verification (build/test green before next gate), commit `pipeline-state.json`, log decision to `learning.db`, update label.
7. **Close-out (green)** — push `autonomad/issue-N`, `gh pr create --body "Fixes #N"`, label `pending-review`, generate report, append `runs.log`, **stop**.
8. **Halt** — see Rule 2.
9. **Harvest** — `learn.ps1` distills verified knowledge + lessons into `learning.db`.

---

## Rule 5: Resume & crash safety

- `pipeline-state.json` is committed to the issue branch at gate 0 and after every gate.
- On restart, the tick loop resumes from `next_gate` if the issue is still `in-progress`.
- **TTL-stale** in-progress issues (older than `repo.config.ttl`) and `needs-human` issues are **skipped** — never force-resumed.

---

## Rule 6: Idempotency

- Label creation is idempotent (`gh label create` guarded by existence check).
- Claim re-checks assignee before acting.
- Init scripts can be re-run safely.
- Resume-from-gate must not re-run completed gates.

---

## Rule 6b: Ticket tracking + revision loop

- **Tracking ref = ticket number (#N).** On claim, autonomad posts a canonical
  `## Tracking` comment: `tracking_ref #N`, `root_ref`, `branch`, `PR URL`. One
  reference point for both human and agent.
- **Root determination:** an issue whose body contains `Parent: #N` is a child;
  no `Parent:` marker → it IS the root.
- **Revision = child ticket.** The human OR the agent creates a child with body
  `Parent: #N` + a `revision:` feedback line + the `autonomous` flag; the poll
  picks it up like any other ticket.
- **"1 PR and branch only":** every child of a root reuses the root's branch
  (`autonomad/issue-<root>`) and the root's already-open PR. Never a new PR per
  revision. On close-out: `git push --force-with-lease`, append a revision note
  to the existing PR, keep the root's `Fixes #N` body intact.
- **Review feedback is the instruction source**; the child ticket is the trigger
  artifact (no comment-ID cursor).
- **Learnings**: revision close-outs are recorded in `learning.db` (`revisions`
  table + `revision_count` bumped on the root row). Publishing to
  `learnings/YYYY-MM-DD.md` is a manual action (`publish-learnings.ps1`) — never
  automatic.

---

## Rule 7: Verification gate is test-only

The dev flow does **not** self-review. It runs `build_command` and `test_command`
green before each gate advances. The `verifier` marketplace agent is available but
is **not called** in the v1 dev flow.

---

## Rule 8: Cost guard

- One issue at a time (concurrency = 1).
- Pure-shell outer loop (LLM only inside the dev sandbox + harvest).
- Idle eviction via `idle_timeout`; `max_retries` bounds failed attempts.
