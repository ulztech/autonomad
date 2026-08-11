#!/usr/bin/env bash
# Autonomad v1 — Copilot CLI adapter (T4) — STUB.
#
# Same harness contract as opencode.sh:
#   run-agent "<prompt>" | load-marketplace
#
# Model override: repo.config `model` is injected by provision.ps1 as
# COPILOT_MODEL. When run-agent is implemented, pass it through if the CLI
# supports a model flag (e.g. gh copilot --model "$COPILOT_MODEL").
#
# Not implemented in v1: harness is switchable by adding this adapter + setting
# repo.config `harness = copilot`. Fails cleanly with a structured error (exit 2).

set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKETPLACE="${MARKETPLACE:-$ADAPTER_DIR/../marketplace}"

not_implemented() {
    cat >&2 <<'EOF'
{"adapter":"copilot","status":"not_implemented","message":"copilot adapter is a v1 stub. Set repo.config harness=copilot after implementing run-agent (gh copilot or copilot CLI). No harness was invoked."}
EOF
    exit 2
}

case "${1:-}" in
    run-agent)
        not_implemented
        ;;
    load-marketplace)
        echo "[copilot] marketplace: $MARKETPLACE (load only; run-agent not implemented)"
        exit 2
        ;;
    *)
        echo "[copilot] usage: $0 run-agent \"<prompt>\" | load-marketplace" >&2
        exit 1
        ;;
esac
