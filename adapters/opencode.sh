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

    # Model tiers: primary from repo.config (OPENCODE_MODEL), then an always-on
    # fallback so a 429/quota hit on the free tier does not strand the issue.
    # `--agent dev` selects the marketplace dev agent (registered by load_marketplace).
    local primary_model="${OPENCODE_MODEL:-}"
    local fallback_model="deepseek/deepseek-v4-flash"
    local models=()
    if [ -n "$primary_model" ] && [ "$primary_model" != "$fallback_model" ]; then
        models+=("$primary_model" "$fallback_model")
    else
        models+=("${primary_model:-$fallback_model}")
    fi

    local code=1
    local m
    for m in "${models[@]}"; do
        echo "[opencode] running dev agent (model=$m)"
        # `opencode run` is the headless, non-interactive mode.
        opencode run --model "$m" --agent dev "$prompt"
        code=$?
        if [ "$code" -eq 0 ]; then
            echo "[opencode] agent exited with code $code (model=$m)"
            return 0
        fi
        echo "[opencode] agent run failed (model=$m, exit $code) — trying next tier" >&2
    done
    echo "[opencode] agent exited with code $code after all model tiers" >&2
    return "$code"
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

    # Register marketplace agents so `opencode run --agent <name>` resolves them.
    # opencode discovers custom agents from ~/.config/opencode/agents/*.md (global)
    # or .opencode/agents/*.md (project). The marketplace ships Claude-format
    # *.agent.md files whose frontmatter (title/user-invocable/groups) opencode
    # ignores, so the agent would never be discoverable. Convert each one to
    # opencode's markdown agent format (description/mode/permission) and write it
    # to the global agents dir (outside the workspace so it never gets committed).
    if [ -d "$MARKETPLACE" ]; then
        AGENTS_DIR="${HOME:-/root}/.config/opencode/agents"
        mkdir -p "$AGENTS_DIR"
        for f in "$MARKETPLACE"/*.agent.md; do
            [ -e "$f" ] || continue
            name="$(basename "$f" .agent.md)"
            dest="$AGENTS_DIR/$name.md"
            # Extract the description from the Claude-format frontmatter (first
            # `---` block); fall back to a generic line if absent.
            desc="$(awk '/^---/{c++} c==2{exit} /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$f")"
            if [ -z "$desc" ]; then
                desc="Autonomad $name agent (registered from marketplace)"
            fi
            # Body = everything after the second `---` frontmatter fence.
            body="$(awk 'BEGIN{f=0} /^---[[:space:]]*$/{f++; next} f>=2{print}' "$f")"
            {
                printf -- '---\n'
                printf 'description: %s\n' "$desc"
                printf 'mode: all\n'
                printf 'permission:\n'
                printf '  edit: allow\n'
                printf '  bash: allow\n'
                printf -- '---\n'
                printf '\n'
                printf '%s\n' "$body"
            } > "$dest"
            echo "[opencode] registered agent '$name' -> $dest (mode=all)"
        done
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
