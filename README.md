# Autonomad

Autonomous issue developer — polls its own GitHub issues, develops them one at a time in an
isolated Docker sandbox using the AIOS brain (read-only) + planning/orchestration patterns,
and opens a reviewed PR (`Fixes #N`) for human review.

- **Bounded autonomy:** develops + opens PRs; never auto-merges or auto-approves.
- **Harness-agnostic:** thin adapters for opencode, Claude Code, Copilot.
- **Self-learning:** every decision + verified knowledge logs to `learning.db`.

See [PLAN.md](PLAN.md) for the full v1 specification.