# Claude config public hardening

**Ticket:** IAN-76 (tranche 1 of four; the remaining tranches open their own tickets as each starts)
**Plans:** `docs/superpowers/plans/2026-09-17-config-hardening-tranche-1-safety.md`

## Goal

Prepare the Claude Code governance harness for public reuse by incorporating the highest-value ideas found in peer harnesses while preserving this repo's incident-driven rulebook, manifest-backed enforcement, and fixture-test discipline. The work should make the harness safer to run, easier to install, easier to verify, and clearer about what the Claude, Codex, and Cursor ports can actually enforce.

## Inputs

- `claude/settings.json`, including permissions, hooks, plugin settings, and current runtime preferences.
- `claude/CLAUDE.md`, `claude/rules/session-types.md`, and stack convention files under `claude/CLAUDE-*.md`.
- `claude/enforce/README.md`, `claude/enforce/manifest.json`, `claude/enforce/tests/`, and `claude/hooks/tests/`.
- `claude/hooks/`, especially session lifecycle hooks, integrity hooks, verification hooks, and secret/destructive-action guards.
- `sync.sh`, `claude/SETUP.md`, `claude/README.md`, and any installer or bootstrap material added by this work.
- Existing port surfaces under `codex/` and `cursor/`, including `PORT-STATUS.md`, `.claude-port.json`, adapters, and generated or hand-authored files.
- Peer-harness research sources from the 2026-09-17 Codex audit:
  - Trail of Bits `claude-code-config`: sandboxing, settings schema, explicit hardening defaults, status line, path-scoped rules.
  - `aditya-samalla/claude-code-harness`: install backup and merge behavior, doctor verification, resume drift snapshots, broader interpreter and network guard examples.
  - `mentu-ai/mentu-hooks`: normalized event and decision vocabulary, capability matrix, explicit degradation ladder.
  - `JayOfemi/claude-harness-forge`: safe installer workflow, standards bank, project trackers, token reporting.
  - `genereda/cc-starter`: beginner-friendly explanations of CLAUDE.md, skills, hooks, context management, and subagents.
  - `ucsandman/claude-harness`: incident-born guard framing, guard probes, override markers, guard integrity story.

## Outputs

- Updated `claude/settings.json` with supported sandbox, schema, status line, privacy, MCP, and subagent-bound defaults where they match this operator's threat model.
- A checked-in status-line script and tests or doctor checks proving it handles missing optional data without breaking sessions.
- A local doctor command or script that verifies installation health: settings parse, schema availability, hook registration, hook executability, fixture suites, sandbox availability, and port status.
- Resume drift tracking: a session snapshot artifact and a SessionStart or resume-time check that tells Claude when files changed since the prior transcript or handoff.
- Public-release installer behavior: merge rather than overwrite existing `~/.claude/settings.json`, back up replaced files, print every change, and stop before destructive actions.
- A cross-agent capability matrix for Claude Code, Codex, and Cursor that states which events can observe, inject context, ask, deny, warn, or only record telemetry.
- Updated README, SETUP, and handoff guidance that present the harness in tiers: core safety, engineering discipline, advanced governance, and personal preferences.

## Acceptance criteria

- B-1: `claude/settings.json` declares a supported settings schema and a fixture or doctor check fails when the file is invalid JSON or when a configured key is known-unsupported by the installed Claude Code version.
- B-2: `claude/settings.json` declares sandbox configuration or an explicit sandbox bootstrap path so Bash subprocesses inherit filesystem and network boundaries; the docs explain which boundary is enforced by Claude permissions and which boundary is enforced by the operating system sandbox.
- B-3: Secret file protection covers both Claude's `Read` tool and Bash subprocess paths where feasible: direct reads, shell redirections, simple interpreter payloads, and obvious file-body uploads are either denied, asked, or documented as requiring the sandbox.
- B-4: The GitHub PAT rotation and transcript purge item remains first in the public-hardening task list until the user removes it from `claude/ISSUES.md`; no lower-priority release work can mark the release checklist complete while that item is open.
- B-5: A `statusLine` entry points to a checked-in script that renders model, branch, dirty state, context usage, session cost when available, elapsed time, and cache hit rate when available; missing data degrades to a readable placeholder instead of failing.
- B-6: A doctor command verifies the installed harness from a clean checkout and from an already-customized `~/.claude`; it reports pass, warn, or fail for settings parse, hook registration, script executability, fixture suites, sandbox availability, status-line execution, and port freshness.
- B-7: The installer or bootstrap flow backs up any user-owned file before replacing it, merges settings lists and hook entries instead of clobbering them, prints the proposed change list before applying it, and has a dry-run mode.
- B-8: Resume drift tracking records the last session's edited file paths, content hashes, and git HEAD, then surfaces a warning on resume when any recorded file disappeared, changed outside the session, or moved behind a different HEAD.
- B-9: The public README explains CLAUDE.md, skills, hooks, subagents, session handoffs, and rule enforcement for readers who have never built a Claude Code harness; each concept includes where it lives in this repo and why it matters to the operator.
- B-10: Always-loaded root instructions are reduced or justified: every rule left in `claude/CLAUDE.md` is either non-negotiable before any file read, needed after compaction, or explicitly not safe to path-scope; repeatable procedures move to skills or docs.
- B-11: A capability matrix lists every supported agent surface, every normalized event, and every decision type; each cell says native, degraded, unavailable, or not implemented, and generated port docs consume that matrix rather than hand-typing parity claims.
- B-12: Intentional guard overrides use a consistent marker or approval record, and the session-end memory route can distinguish a true rule fire from an accepted override and a false block.
- B-13: Every new guard, doctor check, installer behavior, status-line behavior, and drift detector ships with a fixture test that first fails against the missing behavior and then passes after implementation.
- B-14: Public-release docs state that this project is an opinionated reference harness, not a universal best-practices bundle, and identify personal preferences that a user should strip or recalibrate.

## Invariants

- The harness never claims an enforcement guarantee that depends only on model recall or on a hook event that the target agent cannot block.
- Secret material, client-identifying paths, and local machine identifiers never enter tracked files, generated docs, doctor output, or public examples.
- A failed guard or doctor check names the exact file, hook, setting, or missing capability that caused it.
- Public release work does not weaken existing secret, destructive-action, git, test, or hook-integrity protections to reduce friction.
- Generated or ported docs remain deterministic: no timestamps, hostnames, absolute home paths, or user-specific state.

## Failure modes

- Unsupported Claude Code key: the doctor reports the key and the installed version, then classifies the result as fail for required safety keys and warn for optional quality-of-life keys.
- Sandbox unavailable on the host operating system: the doctor reports the missing primitive and the docs explain the fallback risk; release docs must not describe permissions alone as equivalent containment.
- Installer merge conflict: the installer writes no file, prints the conflicting JSON path or hook entry, and tells the user which file was backed up or left untouched.
- Status-line script error: the script prints a minimal fallback line and exits 0 so the terminal remains usable.
- Resume snapshot missing: SessionStart continues, but it states that no drift check ran and records a warning for the next handoff.
- Capability matrix cannot classify a ported hook: the port check fails and names the hook; a hook cannot silently disappear from Codex or Cursor parity docs.
- Doctor fixture dependency missing: the doctor reports skipped rather than passed; skipped checks cannot count toward release readiness.

## State transitions

- Release readiness state:
  - `private`: current state; known user-specific tasks and release blockers may remain open.
  - `candidate`: public docs, installer, doctor, sandbox, schema, status line, and capability matrix are implemented and green locally.
  - `publishable`: candidate state plus R-106 public-diff review, PAT/transcript cleanup complete, no secret or local-path scan hits, and README clearly labels personal preferences.
- Resume drift state:
  - `none`: no prior snapshot exists.
  - `clean`: prior snapshot exists and every recorded file still matches.
  - `drifted`: at least one recorded file changed, disappeared, or belongs to a different HEAD.
  - `stale`: snapshot format is too old to trust; warn and replace after the next stop boundary.

## Non-goals

- No release publication, GitHub push, package publication, or marketplace submission in this spec.
- No broad rewrite of the rulebook or renumbering of rules.
- No adoption of peer harness defaults wholesale; every borrowed idea must close a local gap, reduce release friction, or make enforcement claims more honest.
- No default `--dangerously-skip-permissions` recommendation unless the sandbox is enabled and the docs name the tradeoff.
- No auto-format-on-every-edit hook; this repo keeps the existing pre-commit and pre-push formatting posture unless a separate incident justifies changing it.
- No full multi-agent policy engine before the Claude Code harness is release-ready; Codex and Cursor parity work is limited to the capability matrix and existing port pipeline.

## Dependencies

- Claude Code's current settings, hooks, sandbox, status line, and doctor behavior as documented by official docs at implementation time. Re-verify before editing because these surfaces change quickly.
- Existing shell, Node, jq, and git dependencies already required by the harness; any new dependency requires R-331 justification and a test proving the existing tree cannot meet the need.
- Existing fixture runners: `bash claude/enforce/tests/run-tests.sh` and `bash claude/hooks/tests/run-tests.sh`.
- Existing sync and port surfaces: `sync.sh`, `codex/`, `cursor/`, and the codex translator spec if it lands first.

## Observability

- Doctor output is the primary operator-facing signal: one line per check, with pass, warn, fail, or skipped.
- SessionStart drift output is concise and names only changed file paths and HEAD movement; it must not print file contents.
- SessionEnd learning routes include accepted override and false-block markers so the framework can measure both protection and friction.
- Installer dry-run output lists planned file writes, backups, merges, and skipped steps.

## Security

- Treat installer and doctor output as publishable: no secret values, no local home paths unless redacted, no client-identifying repository names.
- Never read real credential files to prove they are protected. Use fixtures under `/tmp` or synthetic paths.
- Network access for package-name, schema, or documentation verification must be optional and explicitly reported.
- Public docs must warn that hooks and permissions are anti-accident layers, while sandboxing is the containment boundary for Bash subprocesses.

## Domain vocabulary

- public hardening - the set of changes that make this personal harness safer and clearer for other users to inspect or adopt - chosen over: "release polish" because the work includes safety and verification, not only docs.
- sandbox - the operating-system containment layer that restricts filesystem and network access for Bash subprocesses - chosen over: "permission" because Claude permission rules decide whether a tool may run, while the sandbox limits what a running process can reach.
- doctor - the local verification command that checks whether an installed harness is alive and correctly wired - chosen over: "test suite" because it diagnoses a user's machine, not only the repo fixtures.
- status line - the terminal HUD configured by Claude Code to show model, git, context, cost, and elapsed-time signals - chosen over: "dashboard" because it is always visible inside the coding session.
- resume drift - a mismatch between the prior session's recorded file hashes or git HEAD and the current working tree - chosen over: "handoff drift" because it can occur even when no handoff document exists.
- capability matrix - the checked-in table of what Claude Code, Codex, Cursor, and any future agent can observe or enforce for each normalized event - chosen over: "parity table" because some cells intentionally state non-parity.
- degradation - a deliberate downgrade from a stronger decision to a weaker one when an agent surface cannot enforce the stronger action - chosen over: "fallback" because the downgrade must be visible and auditable.
- override marker - an explicit, logged operator exception to a guard - chosen over: "bypass" because bypass implies disabling the harness, while the intended action preserves accountability.
