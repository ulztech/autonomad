#!/usr/bin/env bash
# Autonomad v1.5 — Copilot CLI adapter (issue #35: implement the T4 stub).
#
# Harness contract (Q5) — two verbs, same as opencode.sh:
#   run-agent "<prompt>"     -> execute the dev prompt headlessly via the Copilot
#                              CLI print mode. The prompt may be inline text OR a
#                              path to a file (if the argument resolves to an
#                              existing file, its contents are read).
#   load-marketplace         -> NO-OP for copilot: the Copilot CLI has no agent
#                              registration mechanism (unlike opencode's --agent
#                              dev), so the dev-agent gate contract
#                              (marketplace/dev.agent.md) is folded into the
#                              prompt by Build-DevPrompt instead.
#
# Invocation (Sandcastle copilot provider parity):
#   copilot -p <prompt> --output-format json [--model <model>] [--effort high] --allow-all-tools
#
# Model override: repo.config `model` is injected by provision.ps1 as
# COPILOT_MODEL. When set, passed via --model. When unset, the Copilot CLI
# default (Claude Sonnet 4.5) applies.
#
# Effort: repo.config model_effort is injected as COPILOT_EFFORT (low|medium|high).
#
# Permissions: --allow-all-tools is ALWAYS passed — the autonomy boundary is
# owned by the dev-agent gate contract, not by interactive CLI approval prompts.
#
# Prompts: passed via -p argv when small enough; piped on stdin above the guard
# to avoid the Linux per-arg limit (~128 KiB, E2BIG). Mirrors Sandcastle's
# COPILOT_PRINT_PROMPT_MAX_BYTES.
#
# Sessions: copilot is NON-RESUMABLE (ADR 0016). resumeSession is ignored; every
# run is a fresh session. Resume-from-gate still works because the tick loop
# re-issues the full prompt with current pipeline-state.json.
#
# Exit codes: 0 = agent finished (inspect pipeline-state.json for outcome),
#             1 = harness/agent error, 2 = not implemented (stubs only).

set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKETPLACE="${MARKETPLACE:-$ADAPTER_DIR/../marketplace}"

# Copilot print mode passes the prompt as an argv argument. Stay slightly under
# the Linux ~128 KiB ARG_MAX so spawn never hits E2BIG (Sandcastle guard).
COPILOT_PRINT_PROMPT_MAX_BYTES=$((120 * 1024))

run_agent() {
    local prompt_arg="${1:-}"
    local prompt
    if [ -f "$prompt_arg" ]; then
        prompt="$(cat "$prompt_arg")"
    else
        prompt="$prompt_arg"
    fi
    if [ -z "$prompt" ]; then
        echo "[copilot] ERROR: run-agent requires a prompt or prompt file" >&2
        exit 1
    fi

    if ! command -v copilot >/dev/null 2>&1; then
        echo "[copilot] ERROR: copilot CLI not found in PATH" >&2
        exit 1
    fi

    local bytes
    bytes="$(printf '%s' "$prompt" | wc -c | tr -d ' ')"
    echo "[copilot] running dev agent (model=${COPILOT_MODEL:-<cli default>}, effort=${COPILOT_EFFORT:-high}, prompt=${bytes} bytes)"

    local common=(--output-format json --allow-all-tools)
    if [ -n "${COPILOT_MODEL:-}" ]; then
        common+=(--model "$COPILOT_MODEL")
    fi
    if [ -n "${COPILOT_EFFORT:-}" ]; then
        common+=(--effort "$COPILOT_EFFORT")
    fi

    local code=0
    if [ "$bytes" -le "$COPILOT_PRINT_PROMPT_MAX_BYTES" ]; then
        # Print mode: prompt via -p argv (Sandcastle-tested path).
        copilot -p "$prompt" "${common[@]}" || code=$?
    else
        # Large prompt: pipe on stdin instead of argv (avoids E2BIG).
        echo "[copilot] prompt ${bytes}B exceeds ${COPILOT_PRINT_PROMPT_MAX_BYTES}B — piping via stdin" >&2
        printf '%s' "$prompt" | copilot "${common[@]}" || code=${PIPESTATUS[1]}
    fi

    echo "[copilot] agent exited with code $code (inspect pipeline-state.json for outcome)"
    return "$code"
}

load_marketplace() {
    # NO-OP for copilot: the Copilot CLI has no agent/skills registration
    # mechanism (unlike opencode's --agent dev). The dev-agent gate contract
    # (marketplace/dev.agent.md) is folded into the prompt by Build-DevPrompt.
    if [ -n "${AIOS_BRAIN:-}" ]; then
        export AIOS_BRAIN
    fi
    echo "[copilot] marketplace: $MARKETPLACE (no registration — contract folded into prompt)"
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
        echo "[copilot] usage: $0 run-agent \"<prompt>\" | load-marketplace" >&2
        exit 1
        ;;
esac
