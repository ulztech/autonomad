#!/usr/bin/env bash
# Autonomad v1 — opencode adapter (T4).
#
# Harness contract (Q5) — two verbs:
#   run-agent "<prompt>"     -> execute the repo-native dev agent headlessly
#                              via `opencode run --agent dev`. The prompt may be
#                              inline text OR a path to a file (if the argument
#                              resolves to an existing file, its contents are read).
#   load-marketplace         -> point opencode at marketplace/ + AIOS brain skills.
#
# Exit codes: 0 = agent finished (inspect pipeline-state.json for outcome),
#             1 = harness/agent error, 2 = not implemented (stubs only).

set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKETPLACE="${MARKETPLACE:-$ADAPTER_DIR/../marketplace}"

run_agent() {
    local prompt_arg="${1:-}"
    local prompt
    if [ -f "$prompt_arg" ]; then
        prompt="$(cat "$prompt_arg")"
    else
        prompt="$prompt_arg"
    fi
    if [ -z "$prompt" ]; then
        echo "[opencode] ERROR: run-agent requires a prompt or prompt file" >&2
        exit 1
    fi

    # Load marketplace before running so skills/agents are visible.
    load_marketplace

    if ! command -v opencode >/dev/null 2>&1; then
        echo "[opencode] ERROR: opencode CLI not found in PATH" >&2
        exit 1
    fi

    # Headless dev agent run. `--agent dev` selects the marketplace dev agent.
    # Model override comes from repo.config via OPENCODE_MODEL env.
    local model_args=()
    if [ -n "${OPENCODE_MODEL:-}" ]; then
        model_args=(--model "$OPENCODE_MODEL")
    fi

    echo "[opencode] running dev agent (model=${OPENCODE_MODEL:-default})"
    # `opencode run` is the headless, non-interactive mode (no --silent flag needed).
    opencode run "${model_args[@]}" --agent dev "$prompt"
    local code=$?
    echo "[opencode] agent exited with code $code"
    return $code
}

load_marketplace() {
    # Skills wiring: opencode reads skills.paths from its config / env.
    # Marketplace ships dev.agent.md + verifier.agent.md; AIOS brain skills are
    # exposed read-only at /brain/skills when the sandbox mounts them.
    local paths=("$MARKETPLACE")
    if [ -d /brain/skills ]; then
        paths+=("/brain/skills")
    fi
    # OPENCODE_SKILLS_PATH is an env hint consumed by our config overlay; opencode
    # itself picks up skills through its agent config. Keep both set for tooling.
    export OPENCODE_SKILLS_PATH="$(IFS=:; echo "${paths[*]}")"
    if [ -n "${AIOS_BRAIN:-}" ]; then
        export AIOS_BRAIN
    fi
    echo "[opencode] marketplace loaded: ${paths[*]}"
    return 0
}

case "${1:-}" in
    run-agent)
        run_agent "${2:-}"
        ;;
    load-marketplace)
        load_marketplace
        ;;
    *)
        echo "[opencode] usage: $0 run-agent \"<prompt>\" | load-marketplace" >&2
        exit 1
        ;;
esac
