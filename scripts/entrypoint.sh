#!/usr/bin/env bash
# Autonomad v1 — container entrypoint.
#
# 1. Authenticates gh with GH_TOKEN (from .env via --env-file).
# 2. Wires marketplace + brain skills paths for opencode.
# 3. Runs the pure-shell tick loop (pwsh) with repo.config defaults,
#    forwarding any extra CLI args (e.g. --once).

set -euo pipefail

AUTONOMAD_HOME="${AUTONOMAD_HOME:-/opt/autonomad}"
AUTONOMAD_DATA="${AUTONOMAD_DATA:-/data}"
REPO_CONFIG="${REPO_CONFIG:-$AUTONOMAD_HOME/repo.config}"

log() { printf '[entrypoint] %s\n' "$*"; }

# --- gh auth ---
if [ -z "${GH_TOKEN:-}" ]; then
  log "ERROR: GH_TOKEN is not set. Autonomad cannot operate without GitHub auth."
  exit 1
fi
log "Authenticating gh with GH_TOKEN (${GH_TOKEN:0:4}...)"
printf '%s' "$GH_TOKEN" | gh auth login --with-token
gh auth status >/dev/null 2>&1 || {
  log "ERROR: gh authentication failed."
  exit 1
}
log "gh authenticated as $(gh api user --jq .login 2>/dev/null || echo unknown)"

# --- marketplace wiring (opencode) ---
# Point opencode at the repo-native marketplace AND the AIOS brain skills
# (read-only mount under /brain, corrected path .github/skills -> /brain/skills).
if [ -d "$AUTONOMAD_HOME/marketplace" ]; then
  export OPENCODE_SKILLS_PATH="${OPENCODE_SKILLS_PATH:-$AUTONOMAD_HOME/marketplace}"
fi
# When the dev sandbox mounts the brain, also expose its skills+agents dirs.
if [ -d /brain/skills ]; then
  export AIOS_BRAIN_SKILLS=/brain/skills
fi
if [ -d /brain/agents ]; then
  export AIOS_BRAIN_AGENTS=/brain/agents
fi
log "Marketplace: $AUTONOMAD_HOME/marketplace"
log "Brain skills (if mounted): ${AIOS_BRAIN_SKILLS:-<none>}"

# --- run the tick loop ---
cd "$AUTONOMAD_HOME"
mkdir -p "$AUTONOMAD_DATA/reports" "$AUTONOMAD_DATA/logs"

# Ensure last_tick.ts exists for heartbeat/Status script.
touch "$AUTONOMAD_DATA/last_tick.ts" 2>/dev/null || true

log "Starting tick loop (pwsh src/tick.ps1 $*)"
exec pwsh -NoProfile -NonInteractive -Command "
  \$ErrorActionPreference = 'Stop'
  & '$AUTONOMAD_HOME/src/tick.ps1' -ConfigPath '$REPO_CONFIG' -DataDir '$AUTONOMAD_DATA' @args
" -- "$@"
