# claude-global-rules

A reusable operating system for Claude Code. Rules, hooks, audit roles, convention files, prompt templates, and cross-session memory, organized as an interlocking ten-layer safety framework that any Claude Code session can load at startup.

This repo is the canonical, version-controlled home for everything that governs how Claude behaves across every project the user touches. It is loaded at the start of every session via `~/.claude/`. Individual projects extend and override specific sections through their own `CLAUDE.md` files, but the baseline lives here.

## What this is for

Claude Code is a capable agent. By default, it has no cross-session memory, no consistent behavior across projects, no mechanism to learn from prior mistakes, no enforcement of the user's voice and style preferences, and no safety net against the class of failures that LLM-driven development produces under pressure (confidence theater, deploying to debug, leaking secrets on argv, pasting em dashes into trust-critical output, losing track of which branch a commit will land on).

This repo is the scaffolding that turns Claude Code from "a fresh LLM every session" into "a colleague who remembers the rules, has been burned by specific incidents, and has guardrails that catch the classes of failure the rules alone cannot prevent."

It is built around a single principle: **every layer exists because a specific failure taught us where a layer was missing.** No rule is aspirational. Every hook is wired to a real incident. The framework is not "best practices"; it is "the scar tissue of a team that has been burned and decided to catalog every burn."

## Who it is for

Primarily one person: the maintainer of this repo, who uses it across an 8-app fullstack AI portfolio, research projects, client work, and demo apps. It is shaped by that user's specific preferences (no em dashes, no streaming, afternoon-scale ship pace, anti-slop brand) and incident history (plaintext API key on argv, runbook-vs-code drift, optimism-driven bug fixes, parallel agent fan-out without a canary).

It is readable and adoptable by other Claude Code users with similar requirements. The hooks, role files, and convention pointers are generic enough to port; the user-specific preferences are isolated to a small number of rules that can be stripped or replaced without touching the framework.

## The ten-layer model

The full framework is documented in [`PROTOCOL.md`](./PROTOCOL.md). At a glance:

| Layer | What it catches | Lives at |
|---|---|---|
| 1. Memory | Context decay across sessions, re-learning the same lessons | `global-memory/`, `projects/<cwd>/memory/` |
| 2. Skills | High-risk or high-leverage tasks done ad hoc instead of using the tested pattern | `plugins/superpowers` (brainstorming, TDD, dispatching, debugging) |
| 3. Rules | Behavioral drift, forgotten conventions, ambiguous defaults | `CLAUDE.md` (this repo), per-project `CLAUDE.md`, `CLAUDE-*.md` convention files |
| 4. Tests | Code that works until it does not, green dashboards built on confidence theater | Per-project test suites (unit, integration, E2E, smoke) |
| 5. Hooks | Behavioral rules that decay under pressure; mechanical at-the-tool-call layer | `hooks/`, wired in `settings.json` |
| 6. Process | Each unit of work passes through every layer at least once | Plans, complexity tagging, dispatch protocols |
| 7. Audits | Antagonistic review from role personas (Engineering, Security, Criticism standing) | `audits/` + `audits/on-request/` |
| 8. Verification | Claims without evidence | `superpowers:verification-before-completion` skill |
| 9. Monitoring | Deploys that claim success without checking | Per-project post-deploy polling |
| 10. Lifecycle | Cross-session drift, dirty state, lost context | `SessionStart` + `SessionEnd` hooks, handoff docs |

Each layer assumes the next will catch what it misses. The discipline is not "follow every rule"; the discipline is "add the next layer the next time a failure teaches you where one is missing."

## Repository layout

```
~/.claude/
├── README.md                        # This file.
├── LICENSE                          # MIT license.
├── PROTOCOL.md                      # The ten-layer failure-mode catalog.
├── CLAUDE.md                        # Global rules loaded at every session start.
├── CLAUDE-BACKEND.md                # Read on demand: Express / TS API conventions.
├── CLAUDE-FRONTEND.md               # Read on demand: Next.js / React conventions.
├── CLAUDE-DATABASE.md               # Read on demand: Postgres / SQL conventions.
├── CLAUDE-STYLING.md                # Read on demand: SCSS module conventions.
├── CLOUD-DEPLOYMENT.md              # Read on demand: Railway / Cloudflare deploy guide.
├── settings.json                    # Claude Code settings including hook wiring.
├── agents/                          # Agent definitions for audit roles.
│   ├── audit-engineering.md         # CTO persona agent.
│   ├── audit-security.md            # CISO persona agent.
│   ├── audit-criticism.md           # Devil's advocate agent.
│   └── audit-*.md                   # On-request audit agents (design, financial, etc.)
├── audits/                          # Standing audit role definitions.
│   ├── engineering.md               # CTO persona. Tech debt, tests, CI, architecture.
│   ├── security.md                  # CISO persona. Auth, prompt injection, secrets.
│   ├── criticism.md                 # Devil's advocate. Strategic and rule-layer critique.
│   └── on-request/                  # On-demand roles (ux, design, marketing, etc.)
├── hooks/                           # Claude Code hooks enforcing rules mechanically.
│   ├── secret-scan.sh               # PreToolUse Bash. Blocks secrets on argv.
│   ├── no-em-dash.sh                # PreToolUse Write|Edit|Bash. Blocks U+2014.
│   ├── fix-commit-requires-test.sh  # PreToolUse Bash. Blocks fix: commits with no test.
│   ├── conflict-markers.sh          # PreToolUse Bash. Blocks commits with conflict markers.
│   ├── redact-output.sh             # PostToolUse Bash. Redacts secrets from output.
│   ├── pre-compact.sh               # PreCompact. Injects critical rules into compaction.
│   ├── session-start.sh             # SessionStart. Auto-loads INDEX + handoff doc.
│   └── session-end.sh               # SessionEnd. Routes fire/miss entries to logs.
├── rules/                           # Tier-2 rule files loaded by session type.
│   ├── session-types.md             # Session classification and tier-2 load map.
│   ├── agents.md                    # Multi-agent dispatch rules.
│   ├── audits.md                    # Audit scheduling and role rules.
│   └── cost.md                      # Cost discipline and model routing.
├── skills/                          # User-authored skills.
│   ├── task-start/                  # Scope classification and workflow dispatch.
│   ├── tdd-gated-dispatch/          # Write failing tests before dispatching sub-agents.
│   ├── all-hands/                   # Weekly priorities scan across all audit roles.
│   ├── gof/                         # Gang of Four review (PE, Security, Critic, Designer).
│   └── ...                          # bug-hunt, feature-create, task-cleanup, etc.
├── prompts/
│   └── subagent-branch-setup.md     # Reusable worktree snippet for agent dispatches.
├── global-memory/                   # Cross-project lessons and running logs.
│   ├── INDEX.md                     # Entry point. Auto-loaded by SessionStart.
│   ├── user_profile.md              # Who the user is and how to collaborate.
│   ├── feedback_*.md                # Calibration memories from prior sessions.
│   ├── lesson_*.md                  # Incident-driven efficiency lessons.
│   ├── rule_fires.md                # Append-only log of when CLAUDE.md rules fired.
│   └── rule_misses.md               # Append-only log of rules that should have fired.
├── docs/
│   └── audits/                      # Dated audit reports and session handoff docs.
└── projects/, sessions/, cache/, ... (runtime state; not tracked by git)
```

## How a session uses this repo

1. **Session start.** Claude Code loads `~/.claude/settings.json`, which wires the `SessionStart` hook. The hook reads `global-memory/INDEX.md`, finds the most recent `docs/audits/*session-handoff*.md` or dated audit under the current project, and emits both as additional context. The session begins with cross-project lessons and the previous session's handoff already in view.
2. **Rules load.** `CLAUDE.md` is loaded into the session. Its non-negotiable rules (R-001 through R-007) are the happy path; the session stays on it unless a specific task calls for a rule from a deeper section.
3. **Work happens.** Every tool call passes through the relevant `PreToolUse` hooks. Bash commands are scanned for secrets and em dashes before execution. Write and Edit calls are scanned for em dashes. `git commit -m "fix: ..."` calls are inspected to confirm a test file is staged.
4. **Convention files read on demand.** When the task touches the backend, frontend, database, styling, or deployment layer, the corresponding `CLAUDE-*.md` file is read. These are not preloaded; they enter context only when needed.
5. **Audits run on schedule or on signal.** The standing three roles (Engineering, Security, Criticism) run pre-launch or when a specific risk signal surfaces. The five on-request roles run only when a specific situation calls for that lens.
6. **Session end.** The `SessionEnd` hook scans per-project feedback memory files for the `fired: R-NNN` and `miss: R-NNN` prefix convention from R-305 and appends dated entries to `global-memory/rule_fires.md` / `rule_misses.md`. The session writes a handoff doc to `docs/audits/YYYY-MM-DD-session-handoff.md` if outstanding work remains.

## The self-reinforcement loop

The framework is designed to learn from itself. The loop:

```
work happens
  → mistakes write `miss: R-NNN ...` to feedback memory
  → successes write `fired: R-NNN ...` to feedback memory
  → SessionEnd hook appends dated entries to rule_fires.md / rule_misses.md
  → handoff doc surfaces promotion candidates and stale rules
  → next SessionStart auto-prints retirement candidates from the prior session
  → next session triages, promotes, demotes
  → CLAUDE.md updates with bumped Last validated dates and new/retired rules
  → loop continues
```

Promotion ladder for lessons:
```
ephemeral observation → feedback memory → global memory → CLAUDE.md rule → enforced hook
```

Each rung has a promotion criterion. Lessons climb as they earn their place. Rules that stop earning their place climb back down the retirement ladder. The goal is a CLAUDE.md file whose every rule is currently load-bearing, currently validated within the last 180 days, and either machine-enforced or on an honest 30-day grace period to ship enforcement.

The full "Keeping this file alive" section lives in [`CLAUDE.md`](./CLAUDE.md).

## Design principles

These are the principles the framework defends, not a checklist. Each earned its place through an incident that would have been prevented if the principle had been load-bearing sooner.

- **Every layer exists because a specific failure taught us where one was missing.** No aspirational rules. No copy-paste from "best practices" blogs. If a rule cannot cite a failure it would have prevented or a rule it replaces, it does not belong in `CLAUDE.md`.
- **Rules with no enforcement are a draft state, not a destination.** Honor-system rules decay under pressure. Every rule ships with a path to mechanical enforcement; until that path lands, the rule carries an "honor-system" marker so future sessions know the real state.
- **Golden path first, prohibitions second.** Rules describe the desired behavior, not the forbidden one. Prohibitions remain where they ARE the rule content (the em dash, the secret echo, the bypassed safety check), but the dominant voice is "do X," not "never Y."
- **Cost discipline is gated, not aspirational.** Audits run on schedule or on signal, never reactively. Retrospectives fire after incidents, not after every long session. Handoff docs stay under 8KB. Parallel agent fan-out waits for a canary. The goal is to ship; the framework is scaffolding to make shipping safer, not an end in itself.
- **Memory is project-scoped by default.** Cross-project lessons move to `global-memory/` only after proving themselves across 2+ project types and firing at least 3 times in the trailing 90 days. Client-specific information never crosses that boundary.
- **Audits report, they do not act.** The three standing audit roles (Engineering, Security, Criticism) have reporting authority within their scope. They can declare findings, refuse to soften, and recommend specific edits. They cannot commit code, modify settings, rotate credentials, or take irreversible steps. The user sees every finding and decides what to land.
- **Each layer assumes the next will catch what it misses.** No layer is individually sufficient. The chain is the safety mechanism, not any single component.

## Read this first (if you are new to the repo)

In order:

1. **[`CLAUDE.md`](./CLAUDE.md)**: the canonical rules file. Start here. Read the Non-negotiable rules block, then skim the TOC to locate the section matching your current task.
2. **[`PROTOCOL.md`](./PROTOCOL.md)**: the ten-layer framework. Read this when you want to understand why a layer exists or propose a new one.
3. **[`global-memory/INDEX.md`](./global-memory/INDEX.md)**: cross-project lessons. The `SessionStart` hook reads this automatically; you can also read it directly.
4. **[`audits/engineering.md`](./audits/engineering.md), [`audits/security.md`](./audits/security.md), [`audits/criticism.md`](./audits/criticism.md)**: the three standing audit role definitions. Read the relevant file when asked to run that audit.
5. **[`hooks/`](./hooks/)**: the actual enforcement layer. Each file is self-documenting in its header comment.
6. **[`docs/audits/`](./docs/audits/)**: dated audit reports and session handoff docs. The most recent handoff is the cheapest way to understand current state.

## Running this repo on your own machine

This repo is installed at `~/.claude/` and tracked by git. To bootstrap:

1. Clone the repo to `~/.claude/` (or a separate path and symlink).
2. Ensure Claude Code is installed.
3. Verify `jq` is available (`brew install jq` on macOS); the hooks depend on it.
4. Verify `settings.json` hook paths resolve on your system. The hooks use `~/.claude/hooks/...` which assumes the repo is at `~/.claude/`.
5. Run a dry test: start a Claude Code session in any directory and confirm the `SessionStart` hook emits the global memory INDEX as additional context. Try a Write call containing U+2014 and confirm it blocks. Try `git commit -m "fix: test"` with no staged test file and confirm it blocks.
6. Customize `CLAUDE.md` R-600 (estimation calibration) and `global-memory/user_profile.md` to reflect your own pace and preferences.

The runtime directories (`sessions/`, `cache/`, `history.jsonl`, `paste-cache/`, `shell-snapshots/`) are gitignored and populated by Claude Code as you work.

## Contributing to this framework

This repo is shaped by incidents, not by feature requests. To propose a new rule, new hook, new audit role, or new layer:

1. **Cite the incident.** A proposal without a concrete incident it would have prevented is declined by default. "I think this would be good" is not a citation.
2. **Run the relevant audit first.** Most proposals are better addressed by adding a check to an existing audit role than by adding a new rule to `CLAUDE.md`. The three standing roles cover most ground.
3. **Design the enforcement before the rule.** Rules that ship without a path to mechanical enforcement are draft state. If the proposed rule cannot be enforced by a hook, lint, CI check, or audit scan, it is likely the wrong layer.
4. **Cut something when you add something.** The `CLAUDE.md` token budget is 6,000. Adding content above the budget requires deleting equal or greater content first.
5. **Write the change log entry.** Every change to `CLAUDE.md`, the role files, or the hooks lands with a dated entry in the relevant change log section.

## Version history and audit trail

See the change log at the bottom of [`CLAUDE.md`](./CLAUDE.md). Dated audit reports and session handoff docs live in [`docs/audits/`](./docs/audits/). The git history of this repo is the authoritative record of how the framework has evolved.

Notable milestones:

- **2026-04-07:** initial formal codification of session-lifecycle drift-prevention rules.
- **2026-04-08 (incident):** plaintext Anthropic API key leaked via a Railway CLI command line; the `secret-scan.sh` hook and the engineering audit's Credential Exposure Scan section landed the same day in response.
- **2026-04-08 (PROTOCOL.md):** ten-layer failure-mode catalog codified.
- **2026-04-08 (full CLAUDE.md rewrite):** Security + Criticism + Engineering audits triggered a full rewrite from 866 lines / 11K tokens to 459 lines / 6K tokens, ADDING the security guardrail layer the prior version lacked. Non-negotiable rules block, golden-path reframing, self-reinforcement loop, promotion / retirement ladders, fire and miss logs, Last validated timestamps.
- **2026-04-08 (Phase 2+3 batch):** shipped enforcement hooks (`no-em-dash`, `fix-commit-requires-test`, `session-start`, `session-end`) and the `subagent-branch-setup` reusable snippet. Moved 5 audit roles to on-request. Tightened the three standing role files from "advisory autonomy" to "reporting authority." This README and a session handoff doc.

## License and scope

This repo is the operating system of one developer's Claude Code installation, published for other Claude Code users to read, fork, and adapt. The patterns (hooks, audit roles, memory, lifecycle) are generic; the specific calibrations (em dash prohibition, anti-slop voice, afternoon-scale pace) reflect the maintainer's preferences and can be stripped or replaced without touching the framework.

It is not a library, not an npm package, and not a managed framework. There is no versioning contract. Fork it and make it yours.

MIT License. See [LICENSE](./LICENSE).

---

*Last updated: 2026-05-27. Maintained by the `SessionStart` / `SessionEnd` hooks and by dated commits to `main`.*
