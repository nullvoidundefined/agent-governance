# agent-governance

Rules, hooks, skills, and agent definitions for three AI coding tools (Claude Code, Cursor, Codex CLI), each a peer folder here (`claude/`, `cursor/`, `codex/`), synced into its tool's live config directory by `sync.sh`. The `harness-sync` SessionStart hook (R-003) runs that sync on its own whenever the live directory is absent or differs from the checkout, so a fresh cloud container and a stale laptop both start a session under the committed harness. See `claude/docs/superpowers/specs/2026-09-12-agent-governance-monorepo-design.md` for the design.

## Working in this repository

The dotted `.claude/` and `.cursor/` directories at the root are this repository's own
project config, not payload: they are how a session opened HERE reaches the harness
this repository defines. `.claude/settings.json` registers a `SessionStart` hook that
runs `claude/hooks/harness-sync.sh`, which syncs automatically. Cursor has no
equivalent automatic entry point, so `.cursor/rules/000-harness-bootstrap.mdc` states
the same contract as an always-on rule and asks for one `./sync.sh` run. Codex reads
`~/.codex/AGENTS.md` only and carries no project-local hook surface, so a Codex session
in this checkout depends on a prior sync from any tool.

The payload directories (`claude/`, `cursor/`, `codex/`, no dot) are what `sync.sh`
installs. `cursor/` and `codex/` are generated from `claude/` by `translate/cursor.mjs`
and `translate/codex.mjs`; `--check` gates their freshness in CI, at push, and in
`claude/enforce/doctor.sh`.

