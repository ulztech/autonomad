#!/usr/bin/env bash
# Autonomad v1 — Claude Code adapter (T4) — STUB.
#
# Same harness contract as opencode.sh:
#   run-agent "<prompt>" | load-marketplace
#
# Model override: repo.config `model` is injected by provision.ps1 as
# CLAUDE_MODEL. When run-agent is implemented, pass it through, e.g.
#   claude -p --model "$CLAUDE_MODEL" ...
#
# Not implemented in v1: harness is switchable by adding this adapter + setting
# repo.config `harness = claude`. Fails cleanly with a structured error (exit 2).

set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKETPLACE="${MARKETPLACE:-$ADAPTER_DIR/../marketplace}"

not_implemented() {
    cat >&2 <<'EOF'
{"adapter":"claude","status":"not_implemented","message":"claude adapter is a v1 stub. Set repo.config harness=claude after implementing run-agent (claude -p --allowedTools ...). No harness was invoked."}
EOF
    exit 2
}

case "${1:-}" in
    run-agent)
        not_implemented
        ;;
    load-marketplace)
        # Loading the marketplace is harmless and always available.
        echo "[claude] marketplace: $MARKETPLACE (load only; run-agent not implemented)"
        exit 2
        ;;
    *)
        echo "[claude] usage: $0 run-agent \"<prompt>\" | load-marketplace" >&2
        exit 1
        ;;
esac
