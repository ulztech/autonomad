# Autonomad — Autonomous Issue Developer (v1 Plan)

Autonomad is a standalone, harness-agnostic background agent that polls its own GitHub
issues, claims one `autonomous`-ready issue at a time, develops it in an isolated Docker
sandbox using the AIOS brain (read-only) + planning/orchestration patterns, opens a PR
(`Fixes #N`), records every decision + new knowledge, then stops for human review.

Bounded autonomy: the agent develops and opens PRs, but never merges, never auto-applies
`approved`, and halts with `needs-human` on plan-level failure triggers only.

> This is the initial plan document derived from a `/grill-me` stress-test session.
> It captures every settled design decision (Q1–Q21), the v1 directory layout, runtime
> flow, the harness-agnostic contract, gates/constraints, build order, and open items.

---

## Design decisions (grill outcome)

| # | Decision | Choice |
|---|---|---|
| Q1 | Autonomy boundary | Develop → **stop at PR** OR stop + `needs-human` on plan-level triggers. AIOS's "human picks each task" rule does **not** apply (separate repo). |
| Q2 | Target repo | **Autonomad is its own target** — polls its own `autonomous` issues, opens PRs against itself. |
| Q3 | Dev-brain model | **(d) Marketplace model** — thin repo-native dev agent + AIOS skills/agents wired via `skills.paths` + read-only brain mount. |
| Q4 | Learning store | **(a) SQLite `learning.db`** (decisions + knowledge + issues); harness-agnostic contract. |
| Q5 | Harness abstraction | **(a) One thin adapter per harness** — `run-agent` + `load-marketplace` verbs (opencode/claude/copilot). |
| Q6 | Scheduler | **(a) Container-internal poll loop**, `--once` one-shots, idle eviction/TTL. |
| Q7 | Concurrency | **(a) One issue at a time**; atomic claim via `--add-assignee <bot>`. |
| Q8 | Label matrix | **(b) `autonomous → in-progress → pending-review → reviewing → approved`** + `needs-human`. |
| Q9 | Halt triggers (trimmed) | Plan confidence **<90%** · plan escalation/fatal flaw · **N=2** failed-attempt hard stop. Agent powers through ambiguity alone. |
| Q10 | Learning ingest | **(a) Structured events** — decision-after-gate, verified knowledge (deduped by hash), lesson-at-closeout + post-run **knowledge harvest**. |
| Q11 | Brain mount | **(a) Live read-only bind-mounts** of AIOS brain (`graphify-out/`, `context/`, `references/`, `skills/`, `agents/`, `decisions/`). Brain is strictly read-only. |
| Q12 | Verification gate | **(b) Test-only** — run build/tests green before PR; no self-review/verifier in the dev flow (verifier available in marketplace, not called). |
| Q13 | Test command | **(a) `repo.config`** declares `test_command`/`build_command`, injected into dev prompt. |
| Q14 | Model control | **(a) `repo.config` `model`** field, shell-owned override; omitted → harness default. |
| Q15 | Loop model split | **(c) Pure-shell outer loop** — LLM only in dev sandbox + harvest. |
| Q16 | Crash recovery | **(a) Committed per-issue `pipeline-state.json`** on the issue branch; resume-from-gate; TTL-stale / `needs-human` skipped. |
| Q17 | Lifecycle & auth | **(a)+(a)** Manual container + idle eviction + Start/Stop/Status scripts; `.env` → `--env-file`, `gh auth login --with-token` from `GH_TOKEN`. |
| Q18 | Repo layout | **(a) Fresh `autonomad/` repo**; setup = clone → `.env` → `Init` → `Start`. |
| Q19 | Marketplace agents | **(b)** S- ships `dev.agent.md` + `verifier.agent.md` (verifier available from day one). |
| Q20 | Success close-out | **Yes** — green PR sets `pending-review` + `Fixes #N`, then stops. Human approves/merges. |
| Q21 | Reporting | **Add HTML** — per-issue artifact report (`reports/{issue-ref}.html`) in v1, plus `runs.log` + `learning.db` harvest. |

---

## Directory layout

```
autonomad/
├─ scripts/
│  ├─ Init-Autonomad.ps1       # env verify, gh auth check, build image, scaffold
│  ├─ Start-Autonomad.ps1      # docker run --env-file .env --name autonomad ...
│  ├─ Stop-Autonomad.ps1       # graceful docker stop + state-handoff
│  └─ Status-Autonomad.ps1     # docker ps + heartbeat (last_tick.ts) + run log tail
├─ adapters/
│  ├─ opencode.sh              # run-agent → `opencode run --agent dev`
│  ├─ claude.sh                # run-agent → `claude -p` (with marketplace load)
│  └─ copilot.sh               # run-agent → copilot CLI (same contract)
├─ marketplace/                # skills.paths → AIOS .github/skills + agents (wired read-only)
│  ├─ dev.agent.md
│  └─ verifier.agent.md
├─ src/
│  ├─ tick.ps1                 # pure-shell loop: claim → triage → adapt → report → harvest
│  ├─ learn.ps1                # learning.db writes (decision/knowledge/lesson + harvest)
│  └─ report.ps1               # reports/{issue-ref}.html generator + runs.log append
├─ learning.db                 # SQLite, created on first tick (decision/knowledge/issues)
├─ reports/                    # per-issue HTML artifact reports
├─ repo.config                 # repo, harness, model, test_command, poll_interval, idle_timeout, ttl, max_retries, brain paths
├─ pipeline-state.schema.json
├─ Dockerfile                  # opencode/node/gh + marketplace + adapters baked or mounted
├─ .env.example                # GH_TOKEN, model keys, AIOS_BRAIN_PATH
└─ AGENTS.md                   # documents autonomy boundary + state machine
```

---

## Runtime flow (per tick)

1. **Pure-shell tick** (`src/tick.ps1`): `gh issue list --label autonomous --assignee=none --limit 1`.
   None → idle-sleep (or exit on idle timeout / `--once`).
2. **Claim** — `gh issue edit <N> --add-assignee autonomad-bot --remove-label autonomous --add-label in-progress` (atomic).
3. **Provision** — single Docker container: bind-mount AIOS brain read-only (`AIOS_BRAIN_PATH`),
   marketplace wired via `skills.paths`, `.env` injected.
4. **Adapt** — pick adapter from `repo.config.harness`; invoke `run-agent` with prompt:
   *develop issue #N, load marketplace skills, consult brain at `<path>`, follow pipeline-state
   gates, run build/test, write decision+knowledge at each gate*.
5. **Gate discipline** — on each gate: test-only verification, commit `pipeline-state.json`,
   log decision to `learning.db`, update issue label.
6. **Halt triggers** — plan confidence <90% | plan escalation/fatal flaw | 2 failed attempts
   → label `needs-human`, stop, leave clean state + comment.
7. **Success** — green build/test → push branch `autonomad/issue-N` → `gh pr create --body "Fixes #N"`,
   label `pending-review`, generate `reports/{issue-ref}.html`, append `runs.log`. Stop.
8. **Harvest** — `src/learn.ps1` distills verified knowledge/lessons into `learning.db`.

---

## Harness-agnostic contract

Each adapter exposes exactly two verbs:

- `run-agent "<prompt>"` → executes the repo-native dev agent headlessly in the sandbox
- `load-marketplace` → points the harness at the `marketplace/` skills+agents folder

Swap a harness = add one adapter file + change `repo.config.harness`. Nothing else changes.

---

## Gates & constraints (non-negotiable)

- **Read-only brain** — no writes ever flow back into AIOS.
- **Resume/crash safety** — `pipeline-state.json` committed per issue branch; restart resumes
  from gate; TTL-stale / `needs-human` skipped.
- **No auto-merge / no auto-`approved`** — human review owns both.
- **Cost guard** — one issue at a time, pure-shell loop, idle eviction, `max_retries` bounded.

---

## Build order

1. Repo scaffold + `repo.config` + `.env.example` + `Dockerfile`
2. Pure-shell tick loop + claim/triage (`src/tick.ps1`)
3. Adapters (opencode first, claude/copilot stubs) + marketplace wiring
4. `dev.agent.md` + `verifier.agent.md` (marketplace)
5. `learning.db` schema + `learn.ps1` + harvest
6. `report.ps1` HTML artifact + `runs.log`
7. `Init/Start/Stop/Status` scripts + Docker build
8. Dry-run test against a synthetic `ready` issue in a throwaway repo

---

## Open items (not v1)

- Bounded-parallel worktrees (Q7b)
- Full verifier-in-flow (Q12a)
- GH App rotating tokens (Q17c)
- Versioned brain repo (Q11c)