# Autonomad

Autonomous issue developer — polls its own GitHub issues, claims one `autonomous`-ready
issue at a time, develops it in an isolated Docker sandbox using the AIOS brain
(read-only) + planning/orchestration patterns, and opens a PR (`Fixes #N`) for human
review.

- **Bounded autonomy:** develops + opens PRs; **never** merges, **never** auto-applies
  `approved`, and halts with `needs-human` on plan-level triggers.
- **Harness-agnostic:** one thin adapter per harness (`opencode`, `claude`, `copilot`).
  Swap a harness = add one adapter + change `repo.config`.
- **Self-learning:** every decision + verified knowledge logs to `learning.db` (SQLite).
- **Resumable:** per-issue `pipeline-state.json` committed to the issue branch enables
  crash-safe resume-from-gate.

See [PLAN.md](PLAN.md) for the full v1 specification and [AGENTS.md](AGENTS.md) for the
autonomy boundary + label state machine.

> **New here?** Read **[RUNNING.md](RUNNING.md)** — requirements, setup, how to launch /
> watch / stop Autonomad on any machine, and what happens to issues mid-processing.

## Directory layout (v1)

```
autonomad/
├─ scripts/                 # Init / Start / Stop / Status / DryRun / Validate + mock tooling
├─ adapters/                # opencode.sh (real), claude.sh + copilot.sh (stubs)
├─ marketplace/             # dev.agent.md + verifier.agent.md
├─ src/
│  ├─ tick.ps1              # pure-shell loop: poll → claim → provision → close-out/halt
│  ├─ learn.ps1             # learning.db (decisions / knowledge / issues) + harvest
│  ├─ report.ps1            # reports/{issue-ref}.html + runs.log
│  ├─ Config.ps1            # repo.config + .env parsing (shared)
│  ├─ Pipeline.ps1          # pipeline-state create/read/validate/advance (shared)
│  └─ provision.ps1         # per-issue sandbox container (brain read-only mounts)
├─ learning.db              # SQLite, created on first tick (git-ignored)
├─ reports/                 # per-issue HTML artifact reports (git-ignored at runtime)
├─ repo.config              # repo, harness, model, test/build commands, timeouts, brain paths
├─ pipeline-state.schema.json
├─ Dockerfile               # node + opencode + gh + pwsh + sqlite3 + docker CLI
├─ .env.example             # GH_TOKEN, model keys, AIOS_BRAIN_PATH
└─ AGENTS.md                # autonomy boundary + label state machine + runtime flow
```

## Quick start

1. Clone this repo and check out the target branch.
2. Copy `.env.example` to `.env` and fill in `GH_TOKEN` and `AIOS_BRAIN_PATH`.
   - `AIOS_BRAIN_PATH` points at the AIOS brain repo root. Six subdirectories are
     mounted read-only at **corrected** paths (`skills/`/`agents/` live under
     `.github/` in the brain repo — see `repo.config` `brain_paths`).
3. `pwsh -File scripts/Init-Autonomad.ps1` — verifies env/gh auth, creates labels
   idempotently, builds the `autonomad:v1` image.
4. `pwsh -File scripts/Start-Autonomad.ps1` — `docker run --env-file .env --name autonomad`.
5. `pwsh -File scripts/Status-Autonomad.ps1` / `Stop-Autonomad.ps1` — health / graceful stop.

## Labels (state machine)

```
 autonomous → in-progress → pending-review → reviewing → approved
                  │
                  └→ needs-human (halt triggers only)
```

- Autonomad picks only `autonomous` + unassigned issues and claims them atomically
  (`--add-assignee <bot>`).
- Success close-out = PR + `pending-review`; the human owns `reviewing` / `approved` / merge.
- Halt = `needs-human` + comment (confidence <90%, plan escalation/fatal flaw,
  N=2 failed attempts, or missing pipeline-state).

## Testing

- `pwsh -File scripts/DryRun-Autonomad.ps1` runs the full claim → develop → close-out →
  harvest path **without docker / GitHub / LLM** (mock gh + mock dev agent) and asserts the
  autonomy boundary (no merge, no `approved`, `needs-human` paths work).
