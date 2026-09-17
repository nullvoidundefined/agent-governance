# agent-governance

Rules, hooks, skills, and agent definitions for three AI coding tools (Claude Code, Cursor, Codex CLI), each a peer folder here (`claude/`, `cursor/`, `codex/`), synced into its tool's live config directory by `sync.sh`. The `harness-sync` SessionStart hook (R-003) runs that sync on its own whenever the live directory is absent or differs from the checkout, so a fresh cloud container and a stale laptop both start a session under the committed harness. See `claude/docs/superpowers/specs/2026-09-12-agent-governance-monorepo-design.md` for the design.
