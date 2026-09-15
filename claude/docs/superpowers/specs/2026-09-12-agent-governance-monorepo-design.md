# Agent Governance Monorepo

## Goal

Consolidate three separately-remoted repos, `claude-global-rules` (`~/.claude`), `cursor-global-rules` (`~/.cursor`), and `openai-global-rules` (`~/.codex`), which today hold hooks, rules, skills, and agent definitions for three different AI coding tools (Claude Code, Cursor, Codex CLI), into one neutral repo, `agent-governance`, with three peer folders (`claude/`, `cursor/`, `codex/`). This removes the current structural asymmetry (the other two tools' content living as build output pushed to their own remotes, `~/.claude` implicitly the "host") and the overhead of three separate GitHub repos for what is conceptually one rule set targeting three tools. Canonical editing moves into the monorepo; each tool's live config directory becomes a synced copy, refreshed by a sync step rather than edited in place.

## Inputs

- Hand-edited source content inside `agent-governance/{claude,cursor,codex}/`, rules, hooks, skills, agent definitions, settings/config files.
- The existing per-target build scripts (`cursor/build.mjs`, and an equivalent generator for `codex/`, confirmed to exist via `~/.codex/.claude-port.json`, exact script path not yet located, verify during implementation) that translate Claude Code's native hook/skill/rule shapes into each target tool's native format.

## Outputs

- The live config trees at `~/.claude`, `~/.cursor`, `~/.codex`, each fully replaced by the sync step's output on every run.
- One GitHub remote, `agent-governance`, replacing `claude-global-rules`, `cursor-global-rules`, and `openai-global-rules`.

## Acceptance criteria

- B-1: Running the sync script from a clean `agent-governance` checkout populates `~/.claude`, `~/.cursor`, and `~/.codex` with content matching what's tracked in `claude/`, `cursor/`, and `codex/` respectively, excluding each tool's per-machine runtime state, which stays gitignored and untouched by sync.
- B-2: A rule edited in `agent-governance/claude/CLAUDE.md`, after running sync, is visible to a new Claude Code session reading `~/.claude/CLAUDE.md`.
- B-3: A file edited in `agent-governance/cursor/` or `agent-governance/codex/`, after running sync, lands byte-identical at the matching path under `~/.cursor` or `~/.codex`; sync copies verbatim, it does not translate or regenerate.
- B-4: Sync never touches each tool's own runtime-only state (`auth.json`, session logs, sqlite databases, `~/.claude/sessions/`, etc.); those stay live-directory-only and gitignored inside the monorepo's per-tool folders.
- B-5: `enforce/tests/run-tests.sh` (the only fixture suite that exists; `cursor/` and `codex/` carry no equivalent today) passes against the monorepo's `claude/` content before sync, and CI (`.github/workflows/enforce.yml`, migrated into the new repo, paths adjusted for the `claude/` prefix) blocks a push that fails it.
- B-6: The three retired repos' GitHub remotes are archived or deleted only after the new remote is confirmed working end to end (clone, sync, session boot, a hook actually firing) on the maintainer's machine.

## Invariants

- The live directories (`~/.claude`, `~/.cursor`, `~/.codex`) are never hand-edited going forward; an edit made there is overwritten by the next sync and does not round-trip back into the monorepo.
- Each tool's runtime-only files never enter the monorepo's git history, gitignored at the same granularity `~/.claude` already gitignores its own `sessions/`, `cache/`, `history.jsonl`.
- The sync step is idempotent: running it twice in a row with no source changes produces no diff in any live directory.

## Failure modes

- **Sync run before a source edit is saved:** copies stale content. No data loss, a no-op; caller re-runs sync.
- **Sync run over a hand-edited file with a syntax error** (invalid JSON in a settings file, for example): the affected tool's config load fails at its next session start. Mitigation: the sync script validates JSON files it copies (`jq empty`) before writing them into a live directory, and refuses that one file, leaving the prior live copy in place, rather than partially overwriting.
- **Live directory diverges from the monorepo** (someone edits `~/.cursor` directly out of habit): silently lost on the next sync. Mitigation: a visible warning comment atop each live directory's key files during the migration window, plus extending the existing `.claude-port.json`-style hash manifest to flag drift between the monorepo and the live directories, not only build staleness.
- **Cursor's confirmed symlink-discovery bugs:** not applicable; copy-sync was chosen specifically to avoid this failure mode.
- **Codex's `CODEX_HOME` mechanism:** not used in the uniform-copy-sync design. Noted here only because it was verified viable and rejected in favor of uniformity, so a future session revisiting this decision does not have to re-derive it.

## State transitions

None. This is a repository restructuring, not a stateful running system beyond "in sync" or "out of sync," covered under Invariants.

## Non-goals

- Not building a fourth, tool-agnostic canonical rule format that CLAUDE.md, `.mdc`, and AGENTS.md all get generated from.
- Not building a real, reusable translator that regenerates `cursor/` or `codex/` content from `claude/`'s. None currently exists (see Dependencies); building one is deferred to a future spec. This plan's `sync` is a plain copy of whatever is currently tracked under `cursor/` and `codex/`, stale mirrors included, into the live directories, never a build step.
- Not restructuring content within `claude/` beyond the move itself (not the vehicle for further CLAUDE.md reorganization).
- Not deciding the sync trigger (manual `sync.sh` versus a git hook that runs it automatically on commit or checkout); left open for the implementation plan.
- Not deciding the local clone path or the exact repo visibility (public/private); left open for the implementation plan.

## Dependencies

- The `.claude-port.json` hash-manifest pattern, reused and extended to also cover drift detection between the monorepo and the live directories, not only build staleness.
- No new third-party packages anticipated.
- `cursor/build.mjs` and a codex equivalent do not exist on disk anywhere (verified 2026-09-12): `.claude-port.json`'s `"builder"` field is a label recorded alongside the Sep 5 bootstrap output, not a persisted script. Both mirrors are frozen at that bootstrap commit and are stale relative to `claude-global-rules`' current content. Building a real, reusable translator is out of scope for this spec; see Non-goals.

## Observability

- The sync script logs what it copied, skipped (validation failure), and left untouched (runtime state) to stdout on each run.
- No request-ID or analytics applicability; this is local tooling, not a served application.

## Security

- No new secrets introduced. Each tool's existing runtime credentials (`auth.json`, keychain entries) stay exactly where they are today, untouched by the monorepo or sync.
- The new `agent-governance` remote is public, confirmed explicitly by the user on 2026-09-15 after `cursor-global-rules` and `openai-global-rules` were found to be private (`claude-global-rules` was already public). Going public means the Cursor and Codex mirror content, private until now, becomes public along with it. Deliberate, not a default.

## Domain vocabulary

- **live directory** - `~/.claude`, `~/.cursor`, or `~/.codex` as read by that tool at runtime - chosen over: "install directory" because none of this is installed software, it is config.
- **canonical source** - the hand-edited content under `agent-governance/{claude,cursor,codex}/` - chosen over: "monorepo root" because the three peer folders, not the repo root itself, hold the actual content.
- **sync** - the one-directional copy from canonical source (post-build, for cursor/codex) into a live directory - chosen over: "deploy" because that would imply a network or server deployment.
- **mirror** - `cursor/`'s and `codex/`'s generated content, translated from Claude Code's native shapes - chosen over: inventing a new term, since "mirror" is already in use in this repo's own README for the existing two-repo relationship.
