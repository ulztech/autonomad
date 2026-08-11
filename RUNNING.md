# Running Autonomad on Any Machine

This guide covers everything needed to run Autonomad on a fresh machine: hardware /
software requirements, setup, how to launch it, how to watch it work, and how to stop it
safely without stranding issues.

Autonomad v1.5 is a **multi-agent pipeline**: a pure-shell dispatcher (`tick.ps1`) polls
GitHub, claims one `autonomous` (or `ready-for-agent`) issue at a time, and runs an LLM
"dev agent" inside an isolated Docker sandbox. The dev agent develops the issue, commits
gates to `pipeline-state.json`, and the dispatcher opens a PR (`Fixes #N`) + `pending-review`.

---

## 1. Requirements

### Hardware
| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 8 GB | 16 GB |
| Disk | 10 GB free | 20 GB (Docker image ~1.5 GB + workspaces + brain) |
| CPU | 2 cores (x86-64, AVX2 recommended) | 4+ cores |

> The sandbox container runs the LLM harness inside Docker, so no GPU is required — all
> inference is done by the remote model API (Gemini free tier by default).

### Software
| Tool | Version | Purpose |
|------|---------|---------|
| [Docker](https://docs.docker.com/get-docker/) | 20.10+ | Sandbox containers (`autonomad:v1` image) |
| [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) | 7.x (`pwsh`) | The dispatcher / tick loop |
| [Git](https://git-scm.com/) | 2.30+ | Cloning, branching, pushing |
| [GitHub CLI](https://cli.github.com/) | 2.40+ | Issue/PR/label automation (`gh`) |
| [SQLite3](https://www.sqlite.org/download.html) CLI **or** Python 3 | — | `learning.db` (used by the dry-run test) |

All of the above are baked into the `autonomad:v1` Docker image, but the **dispatcher
runs on the host** (it needs to spawn Docker containers), so `pwsh`, `git`, `gh`, and
`docker` must be installed on the machine.

### Accounts / keys (`.env`)
```
GH_TOKEN=<GitHub personal access token (repo scope)>
GH_BOT_LOGIN=<your GitHub username>
AIOS_BRAIN_PATH=<absolute path to the AIOS brain repo root>   # optional
GEMINI_API_KEY=<Google AI Studio key>                         # free-tier model
GOOGLE_GENERATIVE_AI_API_KEY=<same key>                       # alternate var name
OPENROUTER_API_KEY=<optional fallback>
GROQ_API_KEY=<optional fallback>
AUTONOMAD_LOG_LEVEL=INFO
```

`GH_TOKEN` is mandatory. Model keys: `google/gemini-2.5-flash` is the working free-tier
model; `deepseek/deepseek-v4-flash` is the always-on fallback inside the adapter.

---

## 2. One-time setup

```powershell
# 1. Clone the repo
git clone https://github.com/ulztech/autonomad.git
cd autonomad

# 2. Configure
Copy-Item .env.example .env     # then fill in the keys from the table above
#    Edit repo.config: repo owner/name, model, timeouts, brain_paths

# 3. Build the sandbox image (first time only, ~5 min)
pwsh -File scripts/Init-Autonomad.ps1          # validates env + gh auth, builds autonomad:v1

# 4. Verify everything works (no docker / GitHub / LLM needed)
pwsh -File scripts/Validate-Autonomad.ps1      # config + syntax checks
pwsh -File scripts/DryRun-Autonomad.ps1        # full E2E with mock gh + mock dev agent
```

> **Windows note:** on Windows the dispatcher runs directly in `pwsh` (not via the
> `Start-Autonomad.ps1` container — that path assumes a Linux Docker socket). Run the
> commands in section 3. On Linux/macOS you can use the container wrapper
> (`Start-Autonomad.ps1`) or run `pwsh` directly.

---

## 3. Launching the dispatcher

### Foreground (recommended for first runs / testing)

```powershell
pwsh -NoProfile -File src/tick.ps1 -DataDir "C:\path\to\autonomad-data" -BrainRoot "C:\path\to\AI Docs"
```

This is a **long-running loop** — it stays in the foreground of your terminal and polls
continuously. It is **not** a one-shot command (that's `-Once`). It runs until you stop it.

### One-shot (claim + process a single issue, then exit)

```powershell
pwsh -NoProfile -File src/tick.ps1 -Once -DataDir "..." -BrainRoot "..."
```

### Background (keeps running after you close the terminal)

**Windows (PowerShell):**
```powershell
Start-Process pwsh -ArgumentList @(
  "-NoProfile","-File","src/tick.ps1","-DataDir","C:\path\to\autonomad-data","-BrainRoot","C:\path\to\AI Docs"
) -WindowStyle Hidden
```

**Linux / macOS (`nohup`):**
```bash
nohup pwsh -NoProfile -File src/tick.ps1 -DataDir /path/to/autonomad-data -BrainRoot /path/to/ai-docs > tick.out 2>&1 &
```

**As a service (systemd / scheduled task):** point the unit at `pwsh -File src/tick.ps1 ...`
with the same arguments. Autonomad is designed to be killed and restarted safely — see
section 5.

> **Dedicated session or terminal?** Yes — run it in a **dedicated terminal / session**.
> It is a continuous daemon-like loop; mixing it into an interactive shell that you later
> Ctrl+C will stop Autonomad. Use one terminal for Autonomad and another for everything
> else. To detach entirely, use the background forms above.

---

## 4. Watching it work (live progress)

The dispatcher prints real-time status. While an issue is being developed, you get:

```
SANDBOX: running (elapsed=45s, gate=implementation, model=google/gemini-2.5-flash, last_progress=30s ago, log_lines=7)
  [agent] [opencode] running dev agent (model=google/gemini-2.5-flash)
  [agent] > dev · gemini-2.5-flash
SANDBOX: WARN — no progress for 61s (re-evaluate threshold 60s); will KILL at 300s of no progress.
```

- Each `SANDBOX:` line is the watchdog heartbeat (every `watch_poll`, default 15 s).
- `[agent]` lines are the sandbox's actual output, tailed live via `docker logs`.
- The dev sandbox container is named `autonomad-sandbox-issue-<N>`; while it runs you can
  also tail it from another terminal:
  ```bash
  docker logs -f autonomad-sandbox-issue-12
  ```
- Full history: `logs/tick.log` under the data dir. Per-issue artifacts: `reports/`.
- Live GitHub status: the issue body gets a `### Pipeline` checklist that ticks off each
  completed gate, plus structured `## Gate:` comments.

---

## 5. Stopping it safely (no stranded issues)

The dispatcher registers a Ctrl+C / SIGTERM handler. When it stops, it:

1. **Releases any orphaned claims** — issues still labeled `in-progress` with no live
   workspace are returned to the `autonomous` pool (unassigned + relabeled), so nothing
   strands forever.
2. **Removes orphaned sandbox containers** (`docker rm -f autonomad-sandbox-*`).

### Stop commands
| Situation | Command |
|-----------|---------|
| Foreground session | `Ctrl+C` (releases claims, exits cleanly) |
| Background (Windows) | `Stop-Process -Name pwsh` or the scheduled-task stop |
| Background (Linux) | `kill <pid>` / `pkill -f tick.ps1` |
| Container wrapper | `pwsh -File scripts/Stop-Autonomad.ps1` |

### What about an issue stuck mid-processing?

Three layers protect it:

| Layer | When | Behavior |
|-------|------|----------|
| **Graceful shutdown** | You stop the dispatcher | Claims released back to `autonomous` |
| **Startup reconciliation** | Dispatcher restarts | `Release-OrphanedClaims` + `Cleanup-OrphanedSandboxes` run before the loop |
| **TTL + resume** | Dispatcher was killed hard | `Find-ResumableIssue` resumes from the last committed gate, or halts `needs-human` if stale past `ttl` (default 1 h) |

A hard-killed run is **not lost**: `pipeline-state.json` is committed to the issue branch
after every gate, so the next dispatcher start resumes exactly where it stopped.

---

## 6. Configuration reference (`repo.config`)

| Key | Default | Meaning |
|-----|---------|---------|
| `repo` | — | `owner/repo` to poll |
| `harness` | `opencode` | Adapter: `opencode` (working) / `claude` / `copilot` (stubs) |
| `model` | `google/gemini-2.5-flash` | LLM for the dev agent |
| `poll_interval` | `60` s | Idle sleep between polls |
| `idle_timeout` | `1800` s | Exit if idle this long with no work |
| `ttl` | `3600` s | Max time an issue may sit `in-progress` before it is halved |
| `max_retries` | `2` | Failed dev attempts before `needs-human` |
| `bot_login` | `autonomad-bot` | GitHub user used for claims |
| `sandbox_timeout` | `300` s | **Hard cap** on one sandbox run (watchdog kills) |
| `progress_threshold` | `60` s | After this with no progress, the watchdog warns (re-evaluate) |
| `stall_kill` | `300` s | After this with no progress at all, watchdog kills + retries |
| `watch_poll` | `15` s | Watchdog heartbeat interval |
| `brain_paths` | … | AIOS brain dirs mounted read-only at `/brain/*` |

> For production you may want to raise `sandbox_timeout`/`stall_kill` back to 1800/900 —
> they are 300 s here to keep tests fast (free-tier Gemini is slow but legitimate work is
> not a stall).

---

## 7. Marking an issue ready

Autonomad claims the **lowest-numbered unblocked** issue that is:
- open,
- unassigned,
- labeled `autonomous` **or** `ready-for-agent`,
- not blocked (no open `Depends on #N` / `Blocked by #N` dependency).

```bash
gh issue edit 12 --repo <owner>/<repo> --add-label autonomous
# or the dual-label alias:
gh issue edit 12 --repo <owner>/<repo> --add-label ready-for-agent
```

When it finishes: PR opened, label `in-progress` → `pending-review`, checklist ticked,
summary comment posted. A human reviews/merges.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `docker: invalid reference format` | A mount path has spaces and isn't quoted. Make sure the workspace/brain paths exist; the dispatcher quotes args automatically. |
| `Author identity unknown` in sandbox | Git identity is injected via `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env — confirm `bot_login` is set in `repo.config`. |
| `--agent dev` not found | Old image. Rebuild: `pwsh -File scripts/Init-Autonomad.ps1`. The adapter registers marketplace agents at runtime (A1). |
| Constant `WARN — no progress` | Normal for slow free-tier models; the kill only fires at `stall_kill`. |
| `429` / rate limits | Free-tier model throttled. Switch `model` in `repo.config` or add fallback keys. |
| Issue stuck `in-progress` | Stop dispatcher, restart it — startup reconciliation releases orphans. |
| Sandbox container left behind | `docker rm -f $(docker ps -aq --filter name=autonomad-sandbox-)` |
