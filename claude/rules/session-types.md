Classify session from user's first message. Ambiguous or mixed: load superset.

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

## Tier 2 paths

| File | Path |
|---|---|
| agents | `~/.claude/rules/agents.md` |
| audits | `~/.claude/rules/audits.md` |
| cost | `~/.claude/rules/cost.md` |
