# agent-governance

Rules, hooks, skills, and agent definitions for three AI coding tools (Claude Code, Cursor, Codex CLI), each a peer folder here (`claude/`, `cursor/`, `codex/`), synced into its tool's live config directory by `sync.sh`. The sync never deletes a live file it did not install: it records what it installed in `.sync-manifest` in each live directory, and it removes a file only when that manifest lists it, the repository no longer tracks it, and its live content is unchanged; a file edited live is kept and reported. The `harness-sync` SessionStart hook (R-003) runs that sync on its own whenever the live directory is absent or differs from the checkout, so a fresh cloud container and a stale laptop both start a session under the committed harness. See `claude/docs/superpowers/specs/2026-09-12-agent-governance-monorepo-design.md` for the design.

## Working in this repository

The dotted `.claude/` and `.cursor/` directories at the root are this repository's own
project config, not payload: they are how a session opened HERE reaches the harness
this repository defines. `.claude/settings.json` registers a `SessionStart` hook that
runs `claude/hooks/harness-sync.sh`, which syncs automatically. Cursor has no
equivalent automatic entry point, so `.cursor/rules/000-harness-bootstrap.mdc` states
the same contract as an always-on rule and asks for one `./sync.sh` run. Codex merges a
project-level `AGENTS.md` at this root with its own `~/.codex/AGENTS.md`, so the root
`AGENTS.md` carries the same contract there. Neither tool offers a project-local hook
surface, so in both the sync is a step the session takes rather than one the harness
takes for it.

The payload directories (`claude/`, `cursor/`, `codex/`, no dot) are what `sync.sh`
installs. `cursor/` and `codex/` are generated from `claude/` by `translate/cursor.mjs`
and `translate/codex.mjs`; `--check` gates their freshness in CI, at push, and in
`claude/enforce/doctor.sh`.

