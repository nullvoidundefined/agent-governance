# Setup

How to install this `~/.claude` configuration on a new machine or hand it to someone else. The framework (rules, hooks, audit roles, skills, convention tracks) is generic; personal data and secrets do not ship and are recreated locally.

## Prerequisites

- **git** and **bash** (macOS or Linux; on Windows use WSL, the hooks are bash).
- **jq** is required. Every PreToolUse and SessionStart hook parses its input with `jq`; without it the hooks fail. Install with `brew install jq` or your package manager.
- **python3** is needed only by `ntfy-notify.sh` (notifications). Everything else runs without it.
- **Claude Code** itself.

## Install

1. Clone this repo to `~/.claude` (the hooks and `settings.json` reference `~/.claude/...` paths, so the location matters).
2. Reinstall plugins: they are managed by Claude Code and reinstalled from `settings.json` (`enabledPlugins`); the `plugins/` directory is gitignored.
3. Start a Claude Code session. The SessionStart hooks load the global memory index and warn on a `core.hooksPath` that points outside the repo (R-107).

## What does not ship (gitignored) and must be recreated

| Path | What it is | On a fresh install |
|---|---|---|
| `.env`, `.env.*` | Secrets (API keys, notify config) | Recreate by hand; never commit (R-102) |
| `settings.local.json` | Machine-specific permissions/overrides | Recreate as needed |
| `KNOWN-ISSUES.md` | Production incident log | Copy from `KNOWN-ISSUES.template.md`, then populate |
| `projects/` | Per-project session memory | Auto-created per project; starts empty |
| `plugins/`, caches, `sessions/`, `history.jsonl` | Ephemeral Claude Code state | Auto-managed |

## Reset for a clean handoff

The framework files (`CLAUDE.md`, `PROTOCOL.md`, rules, hooks, agents, skills, convention tracks) are already free of personal and single-project identifiers. The one tracked personal store is `global-memory/`:

- `global-memory/feedback_*.md` and `global-memory/lesson_*.md` are reusable collaboration and efficiency defaults. Keep, edit, or delete them to taste.
- `global-memory/rule_fires.md` and `global-memory/rule_misses.md` are incident logs from the previous owner's sessions. Truncate each to its header so you accumulate your own.
- `global-memory/INDEX.md` indexes the above; update it after editing.

## Stacks

Two convention tracks load on demand by detected stack (see `rules/session-types.md`):

- **TypeScript/Node** (`package.json`): `CLAUDE-BACKEND.md`, `CLAUDE-FRONTEND.md`, `CLAUDE-DATABASE.md`, `CLAUDE-STYLING.md`. The `[ts]`-tagged rules in `CLAUDE.md` apply here.
- **Python** (`pyproject.toml` / `requirements.txt` / `setup.py`): `CLAUDE-PYTHON.md`.

Universal rules in `CLAUDE.md` (untagged) apply to every stack.

## Verify the install

Run the hook test suites; all should pass:

```
for t in ~/.claude/hooks/tests/*.test.sh; do bash "$t"; done
```
