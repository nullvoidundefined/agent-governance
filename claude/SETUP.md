# Setup

How to install this `~/.claude` configuration on a new machine or hand it to someone else. The framework (rules, hooks, audit roles, skills, convention tracks) is generic; personal data and secrets do not ship and are recreated locally.

## Prerequisites

- **git** and **bash** (macOS or Linux; on Windows use WSL, the hooks are bash).
- **jq** is required. Every PreToolUse and SessionStart hook parses its input with `jq`; without it the hooks fail. Install with `brew install jq` or your package manager.
- **node** is required by the clean-code scanner (`hooks/clean-code-scan.mjs`) and the ESLint push gate (`enforce/lint.mjs`).
- **python3** is needed by `ntfy-notify.sh`, the manifest closure test, and the latency test's clock.
- Optional per stack, all fail open when absent at runtime: **ruff** (or uv), **rubocop**, **golangci-lint** for the Python/Ruby/Go push gates.
- **ruff is not optional to run the fixture suite**, however. `push-ruff-gate.test.sh` drives the real binary, while the RuboCop and golangci fixtures stub their linters through `CLAUDE_RUBOCOP_CMD` / `CLAUDE_GOLANGCI_CMD`. Without ruff on PATH that one test fails on a missing tool rather than on a defect, which is what the first CI runs did. Install it (`pipx install ruff`) or expect that single failure.
- **Claude Code** itself.

## Install

1. Clone this repo to `~/.claude` (the hooks and `settings.json` reference `~/.claude/...` paths, so the location matters).
2. Reinstall plugins: they are managed by Claude Code and reinstalled from `settings.json` (`enabledPlugins`); the `plugins/` directory is gitignored.
3. Install the git-side files that `.git/` cannot carry itself:
   - `bash ~/.claude/hooks/install-git-hooks.sh` writes `.git/hooks/pre-push` from the tracked `hooks/pre-push.sample`, so a red suite aborts any push. It refuses to clobber a pre-push it did not write. This step used to be "write a bash script that does X", and the script it described was simply absent from the checkout; the sample is tracked now so the description cannot drift from it.
   - `.git/info/exclude`: local-only exclusions for anything client-identifying that must never be tracked (versioned `.gitignore` covers the standard runtime dirs).
4. Regenerate the hook-integrity manifest so it matches your checkout: `hooks/hook-integrity-check.sh --update`, then commit `enforce/hook-hashes.txt` if it changed.
5. Start a Claude Code session. The SessionStart hooks load the global memory index, verify hook integrity, report enforcement closure (including whether the llm-judge tier can run; see the egress disclosure in README.md), and warn on a `core.hooksPath` that points outside the repo (R-107).

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

Four convention tracks load on demand by detected stack (see `rules/session-types.md`):

- **TypeScript/Node** (`package.json`): `CLAUDE-BACKEND.md`, `CLAUDE-FRONTEND.md` (plus `CLAUDE-FRONTEND-NEXT.md` or `CLAUDE-FRONTEND-VITE.md` per the framework), `CLAUDE-DATABASE.md`, `CLAUDE-STYLING.md`. The `[ts]`-tagged rules in `CLAUDE.md` apply here.
- **Python** (`pyproject.toml` / `requirements.txt` / `setup.py`): `CLAUDE-PYTHON.md`.
- **Ruby on Rails** (`Gemfile`): `CLAUDE-RUBY.md`.
- **Go** (`go.mod`): `CLAUDE-GO.md`.

Universal rules in `CLAUDE.md` (untagged) apply to every stack; each track documents its analogs of the `[ts]`-tagged rules and its blessed exceptions.

## Verify the install

Run BOTH fixture suites; all tests should pass:

```
bash ~/.claude/enforce/tests/run-tests.sh
bash ~/.claude/hooks/tests/run-tests.sh
```

The same two suites run in CI (`.github/workflows/enforce.yml`, job `fixtures`). Name that job as a required status check under Settings > Branches so the gate runs where it cannot be skipped: the local pre-push hook is `--no-verify`-able and is therefore advisory however it is written.

The ESLint-backed tests in the first suite need `enforce/node_modules`, which is
gitignored and therefore absent from a fresh clone. Run `npm install` in
`~/.claude/enforce` first, or six tests fail on a missing ESLint.

## The turn-level verification gate (R-509)

`hooks/verification-gate.sh` runs on `Stop` and blocks the turn from ending on a
red suite. It discovers this project's own checks rather than hardcoding any,
first match wins: `.claude/verify.sh`, then the `~/.claude` repo's two fixture
suites, then `package.json` `test` plus `typecheck`/`type-check`, then
`pytest`/`mypy`, then `go test`/`go vet`, then `bundle exec rspec`.

- It runs only when the working tree is dirty or the branch carries unpushed
  commits, so read-only turns cost nothing.
- A repo with no discoverable check command is never blocked.
- To give a project its own command, write `.claude/verify.sh` in its root. That
  wins over all discovery, so per-project commands never belong in the hook.
- `CLAUDE_SKIP_VERIFY=1` bypasses for one turn. `CLAUDE_VERIFY_TIMEOUT` (default
  600s) caps each command.
