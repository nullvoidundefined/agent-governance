# Session Types

Classify the session from the user's first message. Ambiguous or mixed: load the superset.

| Session type | Trigger signals | Load |
|---|---|---|
| `feature` | Building UI, adding endpoint, writing component, adding flow | core only |
| `bugfix` | Fixing bug, failing test, regression | core only |
| `refactor` | Restructuring code without changing behavior | core only |
| `exploration` | Reading code, answering questions, research, no writes | core only |
| `planning` | Designing feature, writing spec or plan | core + cost |
| `multi-agent` | Dispatching subagents, parallel worktrees, multi-repo | core + agents + cost |
| `audit` | Running engineering, security, criticism, or other audit | core + audits |
| `deploy` | Railway/Vercel deploys, env config, infrastructure | core only |

## Stack detection

Session type is orthogonal to stack. Stack convention files auto-load through path-scoped symlinks in `~/.claude/rules/` when work touches matching files. When planning stack work before any file is open, detect the stack from root marker files and read the matching convention file(s) directly:

| Marker in project root | Stack | Read |
|---|---|---|
| `package.json` | TypeScript/Node | `CLAUDE-BACKEND.md`, `CLAUDE-FRONTEND.md` (plus `CLAUDE-FRONTEND-NEXT.md` or `CLAUDE-FRONTEND-VITE.md` per the framework), `CLAUDE-DATABASE.md`, `CLAUDE-STYLING.md` (whichever the work touches) |
| `pyproject.toml`, `requirements.txt`, or `setup.py` | Python | `CLAUDE-PYTHON.md` |

A repo carrying both marker sets is polyglot: read both tracks for the surface being touched. The `[ts]`-tagged rules in `CLAUDE.md` apply only to the TypeScript stack; their Python analogs live in `CLAUDE-PYTHON.md`.

## Tier 2 paths

| File | Path |
|---|---|
| agents | `~/.claude/rulebook/agents.md` |
| audits | `~/.claude/rulebook/audits.md` |
| cost | `~/.claude/rulebook/cost.md` |
