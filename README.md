# agent-governance

A small global configuration for Claude Code, with ports for Codex and Cursor:
one short rules file, a dozen safety hooks, a few skills, and per-stack
conventions.

## What it installs

| Path | What it is |
|---|---|
| `claude/CLAUDE.md` | The global rules: what never happens, risk tiers, the test-first build loop, verification, bounded review and security review, anti-recursion rules, git and PR habits, model choice, writing style. |
| `claude/PROTOCOL.md` | Why the harness has this shape; read before adding a rule or hook. |
| `claude/CLAUDE-<STACK>.md` | Stack conventions (backend, database, frontend and its frameworks, Go, Python, Ruby, observability, styling), loaded only when matching files are touched. |
| `claude/hooks/` | Safety hooks: secret scanning and output redaction, destructive shell, Docker and git commands, destructive database actions, MCP writes, pushes to `main` and merges (each merge asks, squash only), Codex billing, conflict markers, the subagent watchdog, new-dependency asks, the em-dash check, and the high-risk TDD lock (`enforce/tdd.sh` with `protected-path-guard`). |
| `claude/skills/` | `build-by-slice-require-review` (one PR per slice; the owner approves each before the next), `bug-hunt`, `documentation-create`, `spec-grounding`, `structure-conventions`. |
| `claude/agents/pr-reviewer.md` | An optional read-only reviewer, used when asked. |
| `claude/status-line.sh` | The status line, which also records Claude's weekly usage for quota pacing. |
| `codex/`, `cursor/` | Generated ports of the above (`translate/`). |

## Install

Requirements: git, bash, jq, python3 (the command parser the guards use), node (the translator).

```bash
git clone https://github.com/nullvoidundefined/agent-governance.git
cd agent-governance
./sync.sh
```

`sync.sh` copies `claude/` to `~/.claude`, `codex/` to `~/.codex`, and `cursor/` to `~/.cursor`. It never deletes a live file it did not install. A SessionStart hook re-syncs when the checkout changes.

## Changing it

- Edit the sources under `claude/`. After a change that the ports carry, run `node translate/codex.mjs --write` and `node translate/cursor.mjs --write`. CI fails if `--check` finds the ports stale.
- Every hook has a fixture under `claude/enforce/tests/` or `claude/hooks/tests/`. Run them all with `bash claude/enforce/tests/run-tests.sh`.
- Keep it small. A new rule or hook needs a reason the owner agreed to; prefer a sentence in `CLAUDE.md` over a gate.

The design behind this layout is `docs/specs/governance-recovery/spec.md`.
