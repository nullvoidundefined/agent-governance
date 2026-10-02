# Harness audit: which parts enforce and which parts coach

Ticket: IAN-518. Date: 2026-09-30. Scope: every rule in `claude/CLAUDE.md`, every convention, rulebook, and rule file, every hook in `claude/hooks/` and its registration in `claude/settings.json`, every skill, agent role, audit definition, and prompt template. Nothing here was deleted; this document is the input to that decision.

## Why this audit exists

As models improve, the parts of this harness that compensate for model weakness become dead weight: they cost context on every session and a maintenance tax on every change, and roughly a third of this repository's commits already go to self-maintenance. The parts that enforce permissions and verification at a tool-call boundary stay valuable no matter how good the model is, because they hold even when the model is wrong. The audit separates the two so the second group can be kept and the first can be measured and pruned.

## Classes

- **ENFORCE**: mechanically blocks or verifies something at a tool-call, git, or CI boundary (it can deny, ask, block a Stop, or fail a check). Kept by default.
- **STRUCTURAL**: a separation with a real correctness purpose, such as the TDD authorship split across contexts. Kept; the purpose is stated in one line.
- **COACHING**: tells the model how to behave or what procedure to follow, with no mechanical check. A removal candidate.
- **ORCHESTRATION**: exists mainly to keep the model focused or to sequence its work. A removal candidate.
- **SUPPORT** (hooks only): a sourced helper library with no registration of its own; it inherits the class of the hooks that use it.

## Method

Three read-only classifiers ran in parallel, one each over rules, hooks, and skills with agents, prompts, and audit definitions. Every enforcer tag was verified rather than trusted: a hook tag counts as ENFORCE only when the hook file exists, is registered in `claude/settings.json`, and can emit `permissionDecision` `deny` or `ask`, exit 2 on a blocking event, or return a Stop or ConfigChange block. A hook that only emits `additionalContext`, a `systemMessage`, or stderr is COACHING even when a rule names it as its enforcer. Token figures are characters divided by four of the text that loads, not measurements.

## Counts

| Surface | ENFORCE | STRUCTURAL | COACHING | ORCHESTRATION | SUPPORT |
|---|---|---|---|---|---|
| `CLAUDE.md` rules (92) | 47 | 4 | 35 | 6 | |
| Convention files, rulebook, rule files (20 rows) | 0 | 0 | 18 | 2 | |
| Files in `claude/hooks/` (75) | 33 | 1 (also ENFORCE) | 19 | 6 | 17 |
| Skills (19) | 0 | 0 | 9 | 10 | |
| Agent roles (15) | 0 | 6 | 9 | 0 | |
| Audit definitions (9: 3 in `audits/`, 6 in `audits/on-request/`) | 0 | 0 | 9 | 0 | |
| Prompt templates (10) | 1 | 2 | 2 | 5 | |
| **Total (240)** | **81** | **13** | **101** | **29** | **17** |

The hook row counts protected-path-guard under ENFORCE and again under STRUCTURAL, so the row sums to 76 for 75 files; its 33 ENFORCE entries are the 31 other registered guards, protected-path-guard, and `pre-push.sample`, the git hook that `install-git-hooks.sh` installs and that aborts a push (R-215). The first version of this table, before the PR #174 review, undercounted ENFORCE hooks as 28 and misfiled `pre-push.sample` as a helper. Four of the ten ORCHESTRATION skills (task-start, build-fast, tdd-gated-dispatch, repo-setup) carry scripts that a gate reads or that a fixture pins; the prose is removable, the scripts are not (see "Unsure").

## Rules in `claude/CLAUDE.md`

Only COACHING and ORCHESTRATION rows list dependents. "Base" means the generated ports that carry every rule verbatim: `cursor/rules/000-global-rules.mdc`, `codex/AGENTS.md`, and the `cursor/rules/rulebook-reference-r*xx-*.mdc` bands. Tokens are the rule line's always-loaded cost.

IAN-568 deleted R-206, R-213, R-215, R-322, R-408, R-409, R-502, R-503, R-506, R-510, R-511, R-906, and R-907; their rows stay for the record with the class DELETED, and the rows below name only the enforcers that still exist.

| id | class | rationale | dependents | tokens |
|---|---|---|---|---|
| R-001 | ORCHESTRATION | session-start procedure; session-start.sh injects the index and handoff but checks nothing | base, cursor session-start and session-handoff commands, codex session skills, rulebook audits/cost/agents .mdc; fixtures r001-project-file-rule-text, r001-non-interactive-scope-rule-text, session-start, protocol-section, skills-lint | 278 |
| R-002 | ORCHESTRATION | restates R-001 | base, 002-global-memory-index.mdc; fixture r001-non-interactive-scope-rule-text | 30 |
| R-003 | STRUCTURAL | without the sync every guard is absent from `~/.claude` | | 85 |
| R-101 | ENFORCE | destructive-db-guard and destructive-command-guard deny or ask | | 79 |
| R-102 | ENFORCE | secret-scan denies; redact-output only warns after the fact | | 60 |
| R-103 | ENFORCE | secret-scan denies credential-file writes | | 42 |
| R-104 | COACHING | artifact sanitizing has no check | base, observability/python/backend .mdc, ticket-lifecycle skill ports, codex slice-critic | 33 |
| R-105 | ENFORCE | mcp-action-guard asks | | 63 |
| R-106 | ENFORCE | global-repo-push-guard denies or asks | | 62 |
| R-107 | ENFORCE | destructive-command-guard denies hooksPath writes; the tagged hookspath-drift-check only warns | | 44 |
| R-108 | ENFORCE | secret-scan denies credential-shaped literals | | 114 |
| R-109 | ENFORCE | push-semgrep-gate denies; CI security.yml repeats | | 110 |
| R-201 | COACHING | prompt-injection posture, no check | base, rulebook-audits.mdc, session-start command, spec-grounding ports | 35 |
| R-202 | COACHING | read-scope discipline; the secret half is R-102 | base | 40 |
| R-203 | ENFORCE | destructive-command-guard and settings-change-guard block; hook-integrity-check only warns | | 51 |
| R-204 | COACHING | root-cause discipline; the weakening subset is R-405 | base, build-fast ports; fixtures hook-path-walk-budget, hook-latency, ratchet | 65 |
| R-205 | COACHING | investigate-first behaviour | base | 49 |
| R-206 | DELETED (IAN-568) | prompt wording | base; fixture r001-non-interactive-scope-rule-text | 22 |
| R-207 | ENFORCE | no-em-dash denies | | 13 |
| R-208 | COACHING | tone | base | 25 |
| R-209 | COACHING | output style | base, 002-global-memory-index.mdc | 46 |
| R-210 | COACHING | prose style | base, documentation-create ports | 84 |
| R-211 | ORCHESTRATION | sequences owner questions | base, 002-global-memory-index.mdc, build-by-slice and task-start ports; fixtures merge-authority-rule-text, build-fast-rule-text | 151 |
| R-212 | COACHING | scope-widening-gate was removed in IAN-568; the declared scope is recall | | 80 |
| R-213 | DELETED (IAN-568) | task-provenance-gate denies | | 117 |
| R-214 | ENFORCE | commit-message-guard denies out-of-scope staging without a Refs trailer; the file-a-ticket habit is coaching | | 146 |
| R-215 | DELETED (IAN-568) | pre-push hook from install-git-hooks.sh; the `ci:` tag is wrong, no workflow runs it | | 109 |
| R-301 [ts] | COACHING | monorepo layout | base; fixture structure-gate | 53 |
| R-302 | ENFORCE | content-gate denies escaping imports | | 38 |
| R-303 | ENFORCE | ESLint no-cycle always; no-restricted-paths only with importZones | | 62 |
| R-306 | ENFORCE | structure-gate denies catch-all dirs | | 64 |
| R-307 | COACHING | services/clients/api layout; only advisory reminders | base, observability/python .mdc, codex slice-critic; fixtures one-export-app-router, eslint | 54 |
| R-308 | COACHING | reuse-first search habit | base, tdd-gated-dispatch and spec-grounding ports, codex implementer and slice-critic; translate render files | 45 |
| R-315 | ENFORCE | CI LLM judge (probabilistic, fails open without an API key) | | 35 |
| R-316 | ENFORCE | opt-in lexicon ESLint plus judge | | 42 |
| R-317 | ENFORCE | opt-in lexicon ESLint plus judge | | 50 |
| R-318 | COACHING | size is a smell | base, python .mdc, codex implementer | 20 |
| R-320 | ENFORCE | opt-in ESLint file-header; the reminder hook is advisory | | 50 |
| R-322 | DELETED (IAN-568) | clean-code-reminder never blocks | manifest advisory entry; base, python .mdc, codex implementer; fixtures clean-code-reminder, build-lane-quiet, judge-diff, build-fast-composition | 47 |
| R-325 | ENFORCE | ESLint destructure-object-reads plus judge | | 36 |
| R-330 | COACHING | spec-glossary-check is advisory; lexicon-gate was removed in IAN-568 | | 75 |
| R-331 | ENFORCE | dependency-add-guard asks | | 56 |
| R-332 | COACHING | comments stay true | base | 60 |
| R-334 | ENFORCE | CI judge only | | 139 |
| R-341 | COACHING | observability-reminder only nudges | manifest advisory; base, seven stack .mdc, codex slice-critic; fixtures observability-reminder(-target), convention-track-invariants | 68 |
| R-342 | ENFORCE | ESLint no-console and structured-log-call; ruff T201 | | 69 |
| R-343 | ENFORCE | ESLint analytics-event-name | | 66 |
| R-344 | ENFORCE | ESLint no-swallowed-catch and analogs | | 67 |
| R-345 | COACHING | health endpoints; advisory reminder only | manifest advisory; base, five stack .mdc; fixtures observability-reminder, build-lane-quiet | 54 |
| R-346 | COACHING | outbound instrumentation; advisory reminder only | manifest advisory; base, five stack .mdc, codex slice-critic; fixtures observability-reminder(-target), convention-track-invariants | 43 |
| R-351 | COACHING | dockerfile-reminder is advisory | manifest advisory; base, eight stack .mdc; fixtures convention-paths-scope, convention-track-invariants, build-lane-quiet, dockerfile-reminder | 87 |
| R-361 | ENFORCE | ESLint no-query-in-loop and analog push gates | | 100 |
| R-362 | ENFORCE | ESLint transaction-client-required, analog gates, judge | | 84 |
| R-363 | ENFORCE | CI judge only | | 54 |
| R-364 | ENFORCE | CI judge only | | 46 |
| R-365 | ENFORCE | CI judge only | | 39 |
| R-401 | ENFORCE | content-gate and ESLint deny test suppression | | 75 |
| R-403 | ENFORCE | fix-commit-requires-test denies | | 51 |
| R-404 | COACHING | reproduce before deploy | base | 15 |
| R-405 | ENFORCE | content-gate denies weakened protections | | 35 |
| R-406 | COACHING | negative-input tests; no check | base, ruby/python/go .mdc, codex test-author; fixtures r109-rule-text(-2) | 63 |
| R-408 | DELETED (IAN-568) | lint scope habit | base, ruby/python/go .mdc | 23 |
| R-409 | DELETED (IAN-568) | diagnose repeated cleanups | base | 27 |
| R-410 | STRUCTURAL | gate inputs and locked tests writable only by their author role | | 94 |
| R-411 | STRUCTURAL | independent test authorship: the test-author writes tests in its own context and the implementer cannot change them (it still reads them and writes code to pass them) | | 54 |
| R-412 | STRUCTURAL | the tdd.sh lock makes RED-before-GREEN provable | | 91 |
| R-501 | COACHING | parallel-session-check only warns | manifest advisory; base, build-fast ports; fixtures parallel-session-check, translate-codex, translate-cursor | 38 |
| R-502 | DELETED (IAN-568) | task-list hygiene | base, cursor README; fixtures translate-codex, translate-cursor | 24 |
| R-503 | DELETED (IAN-568) | progress shares and timestamps; session-start only records the start | manifest advisory; base, cursor hook adapter, task-cleanup/task-start/ticket-lifecycle ports; fixtures task-tier, cursor-adapter-contract, translate-cursor, session-start-timestamp | 69 |
| R-504 | COACHING | task-commit-reminder is advisory | manifest advisory; base, both PORT-STATUS files; fixtures task-commit-reminder, translate-cursor, post-compact-rules | 32 |
| R-505 | ENFORCE | commit-message-guard denies | | 36 |
| R-506 | DELETED (IAN-568) | commit-message-guard asks (the manifest's advisory tier is stale) | | 37 |
| R-507 | ENFORCE | conflict-markers denies | | 18 |
| R-508 | COACHING | git-workflow-guard's README clause is stderr only | manifest advisory; base, task-cleanup ports; fixture git-workflow-guard | 34 |
| R-509 | ENFORCE | verification-gate blocks Stop on a red affected suite | | 95 |
| R-510 | DELETED (IAN-568) | do not re-run hook steps | base, ruby/python/go .mdc | 29 |
| R-511 | DELETED (IAN-568) | git-workflow-guard's refactor clause is stderr only | manifest advisory; base; fixture git-workflow-guard | 30 |
| R-512 | ENFORCE | git-workflow-guard denies non-squash merges | | 129 |
| R-513 | ENFORCE | constant-change-guard asks (the manifest's advisory tier is stale) | | 41 |
| R-514 | ENFORCE | git-workflow-guard asks on merge and push to main | | 243 |
| R-515 | COACHING | resolve reviewer threads | base, task-cleanup ports | 35 |
| R-516 | COACHING | enforcement-guard-check only warns; settings-change-guard blocks only deregistration | manifest entries; base, 002-global-memory-index.mdc, add-stack-track ports; fixtures manifest-fixture-closure, settings-change-guard, r109-rule-text | 52 |
| R-517 | ENFORCE | git-workflow-guard denies a merge without a current review section | | 349 |
| R-518 | ORCHESTRATION | draft-pr-on-first-push automates, pr-monitor-reminder reminds | manifest advisory entries; base; fixtures pr-monitor-reminder, draft-pr-on-first-push | 116 |
| R-601 | COACHING | handoff offer; task-state-tracker only records | manifest advisory; base, cursor README and session commands, codex session skills, codex PORT-STATUS | 48 |
| R-602 | COACHING | handoff-check never blocks | manifest advisory; base, session and task skill ports; fixtures handoff-check, handoff-session-file-check, session-metrics, session-start | 69 |
| R-603 | COACHING | memory routing | base, 002-global-memory-index.mdc, session-handoff ports | 33 |
| R-604 | COACHING | memory scope | base | 39 |
| R-605 | ENFORCE | pr-ticket-ref-gate and linear-todo-label-gate deny (ticket-at-start-gate was removed in IAN-568); the bookkeeping clauses are coaching | | 285 |
| R-606 | COACHING | ticket-close bookkeeping | base, rulebook-cost.mdc, build-fast/task-cleanup/task-start/ticket-lifecycle ports | 93 |
| R-607 | COACHING | push-feature-docs-gate was removed in IAN-568; task-cleanup checks it | | 174 |
| R-608 | COACHING | push-feature-docs-gate was removed in IAN-568; task-cleanup checks it | | 206 |

## Convention files, rulebook, and rule files

Convention files load only when a matching path is touched (through `claude/rules/*.md` symlinks); their token figure is the cost on that trigger. Every one is ported to `cursor/rules/<track>.mdc`, `codex/AGENTS.md`, `001-session-types.mdc`, and `rulebook-reference-convention-files.mdc`.

| id | class | rationale | dependents beyond the standard ports | tokens |
|---|---|---|---|---|
| CLAUDE-BACKEND.md | COACHING | handler and repository patterns; only rule subsets are linted | backend and related stack .mdc, audit-engineering; fixtures convention-examples-review, convention-security-*, convention-cookie-examples, translate-cursor | 7,234 on trigger |
| CLAUDE-DATABASE.md | COACHING | SQL and migrations; migration-defaults-guard covers a slice | database/python .mdc; manifest mention | 5,336 |
| CLAUDE-FRONTEND.md | COACHING | layering guidance | five frontend .mdc, audit agents; fixtures convention-paths-scope, convention-track-invariants | 2,612 |
| CLAUDE-FRONTEND-NEXT.md | COACHING | Next.js specifics | fixture convention-paths-scope | 1,202 |
| CLAUDE-FRONTEND-NUXT.md | COACHING | Nuxt specifics | fixture convention-paths-scope | 3,052 |
| CLAUDE-FRONTEND-REACT.md | COACHING | React specifics | fixture convention-paths-scope | 1,400 |
| CLAUDE-FRONTEND-VITE.md | COACHING | Vite specifics | fixture convention-paths-scope | 1,115 |
| CLAUDE-FRONTEND-VUE.md | COACHING | Vue specifics | fixture convention-paths-scope | 3,017 |
| CLAUDE-GO.md | COACHING | Go track; golangci covers a subset | fixtures convention-examples-review(-2), structure-gate, convention-* | 4,050 |
| CLAUDE-OBSERVABILITY.md | COACHING | logging and health patterns; advisory reminder only | fixtures convention-examples-review, observability-reminder-target | 3,758 (broad paths, every `*.py`) |
| CLAUDE-PYTHON.md | COACHING | Python track; ruff covers a subset | fixtures convention-examples-review(-2), structure-gate, convention-*, migration-defaults-guard | 15,322 on any `*.py` |
| CLAUDE-RUBY.md | COACHING | Rails track; rubocop covers a subset | fixtures as Go | 3,522 |
| CLAUDE-STYLING.md | COACHING | SCSS conventions, no enforcement | styling and frontend .mdc, audit-design/ux | 2,663 |
| `rules/*.md` (13 symlinks) | COACHING | path-scoped aliases of the files above | fixtures convention-paths-scope, convention-track-invariants | 0 extra |
| `rules/session-types.md` | ORCHESTRATION | routes session type to Tier 2 reads; no `paths:`, so it loads every session | 001-session-types.mdc, codex rules renderer, session-start ports; fixtures claude-md-lint, translate-* | 552 always |
| `rulebook/reference.md` | COACHING (partly load-bearing) | full Specs; judge-diff.sh extracts the nine judge-tier blocks from it, so those blocks are enforcement inputs | r0xx..r6xx .mdc bands; fixtures claude-md-lint, manifest, judge-diff, lexicon-spec-sync, skills-lint, many *-rule-text | 40,176 on demand |
| `rulebook/agents.md` | ORCHESTRATION | multi-agent dispatch sequencing | rulebook-agents.mdc, cursor port map; fixtures manifest, translate-cursor, skills-lint | 1,737 on demand |
| `rulebook/audits.md` | COACHING | audit procedure | rulebook-audits.mdc, gof/bug-hunt | 699 on demand |
| `rulebook/cost.md` | COACHING | model and cost selection | rulebook-cost.mdc, task-start | 2,248 on demand |
| `PROTOCOL.md` | COACHING | rationale and history, read through /protocol | 000-global-rules.mdc, protocol skill; fixtures protocol-section, fixture-implementation-root(-sabotage) | 11,719 on demand |

## Hooks

Registration counts per event: 23 on every Bash call, 11 on every Write or Edit, 3 on `mcp__.*`, 7 at SessionStart, plus Stop, SessionEnd, ConfigChange, PreModelSwitch, and TaskCreate/TaskUpdate hooks. No PostToolUse hook can block.

IAN-568 removed task-provenance-gate, codex-test-author-guard, push-golangci-gate, push-rubocop-gate, clean-code-reminder, ticket-at-start-gate, push-feature-docs-gate, scope-widening-gate, and lexicon-gate; their rows are gone from this table and the registration counts above predate that removal.

| hook | event | class | evidence | dependents (COACHING/ORCH only) | context cost |
|---|---|---|---|---|---|
| audit-signal-check | PreToolUse Bash | COACHING | additionalContext only | R-801, R-904; 2 manifest rows; both hooks.json and PORT-STATUS; fixture audit-signal-check | about 130 tokens on some pushes |
| build-cheatsheets | PreToolUse Bash | ORCHESTRATION | regenerates cheatsheets, no output | both hooks.json and PORT-STATUS; 2 fixtures | 0 |
| codex-billing-guard | PreToolUse Bash | ENFORCE | asks before metered Codex calls | | |
| commit-message-guard | PreToolUse Bash | ENFORCE | denies on R-505 (the R-506 ask and R-214 refusal were removed in IAN-568) | | |
| conflict-markers | PreToolUse Bash | ENFORCE | denies | | |
| constant-change-guard | PreToolUse Bash | ENFORCE | asks | | |
| content-gate | PreToolUse Write/Edit | ENFORCE | denies | | |
| dependency-add-guard | PreToolUse Write/Edit | ENFORCE | asks | | |
| destructive-command-guard | PreToolUse Bash | ENFORCE | denies | | |
| destructive-db-guard | PreToolUse Bash, mcp | ENFORCE | deny/ask | | |
| dockerfile-reminder | PostToolUse Write/Edit | COACHING | additionalContext only | R-351; manifest; ports; 2 fixtures | about 150 when triggered |
| draft-pr-on-first-push | PostToolUse Bash | ORCHESTRATION | runs `gh pr create --draft`, then reminds | R-517, R-518, R-605; manifest; ports; fixture | about 225 per new branch |
| enforcement-guard-check | SessionStart | COACHING | warns, never blocks | R-516; manifest; ports; 5 fixtures | 0 when healthy |
| fix-commit-requires-test | PreToolUse Bash | ENFORCE | denies | | |
| flat-directory-reminder | PostToolUse Write | COACHING | additionalContext only | R-309, R-310; manifest; ports; 2 fixtures | about 110 when triggered |
| git-workflow-guard | PreToolUse Bash | ENFORCE | deny/ask for R-512, R-514, R-517, R-109 | | |
| global-repo-push-guard | PreToolUse Bash | ENFORCE | denies | | |
| handoff-check | PostToolUse Write | COACHING | additionalContext only | R-602; manifest; ports; 2 fixtures | about 125 on a flawed handoff |
| harness-sync | SessionStart | ORCHESTRATION | runs sync.sh; the delivery path of every other hook (R-003) | R-003; manifest; ports; 4 fixtures | 0 when in sync |
| hook-integrity-check | SessionStart | COACHING | hash mismatch warns, never blocks | R-106, R-203; manifest; ports; 5 fixtures | 0 when clean |
| hookspath-drift-check | SessionStart | COACHING | warns | R-107; manifest; ports; fixture | 0 when clean |
| linear-todo-label-gate | PreToolUse mcp | ENFORCE | denies | | |
| mcp-action-guard | PreToolUse mcp | ENFORCE | asks | | |
| migration-defaults-guard | PreToolUse Write/Edit | ENFORCE | denies | | |
| model-switch-guard | PreModelSwitch | COACHING | systemMessage only | R-903; manifest; PORT-STATUS only (not ported) | about 80 on an upward switch |
| new-file-header-reminder | PostToolUse Write | COACHING | additionalContext only | R-320; ports; 3 fixtures | about 130 per new file |
| no-em-dash | PreToolUse Bash, Write/Edit | ENFORCE | denies | | |
| observability-reminder | PostToolUse Write/Edit | COACHING | additionalContext only | R-341, R-345, R-346; 3 manifest rows; ports; 3 fixtures | 130 to 250 when triggered |
| parallel-session-check | SessionStart | COACHING | warns | R-501; manifest; ports; fixture | about 100 with a sibling session |
| post-compact-rules | SessionStart compact | COACHING | re-injects a hand-copied rule subset | 15 rule ids; codex hooks.json, cursor PORT-STATUS; 2 fixtures | about 800 per compaction |
| pr-monitor-reminder | PostToolUse Bash | COACHING | additionalContext only | R-518; manifest; ports; fixture | about 200 per PR opened by hand |
| pr-ticket-ref-gate | PreToolUse Bash | ENFORCE | denies | | |
| protected-path-guard | PreToolUse Bash, Write/Edit | STRUCTURAL and ENFORCE | denies; role and gate-input boundaries | | |
| push-eslint-gate | PreToolUse Bash | ENFORCE | denies | | |
| push-ruff-gate | PreToolUse Bash | ENFORCE | denies | | |
| push-semgrep-gate | PreToolUse Bash | ENFORCE | denies | | |
| redact-output | PostToolUse Bash | COACHING | detects a leak after the fact; cannot rewrite output | R-102; manifest; ports; 2 fixtures | about 200 on a leak |
| redaction-guard-check | SessionStart | COACHING | warns when two named hooks are unregistered | R-102; manifest; ports; fixture | 0 when healthy |
| secret-scan | PreToolUse Bash, Write/Edit | ENFORCE | denies | | |
| session-end | SessionEnd | ORCHESTRATION | routes memory lines, writes a resume snapshot | R-602, R-603; ports; 6 fixtures | 0 |
| session-start | SessionStart | ORCHESTRATION | injects the memory index, handoff, start time, resume offer | R-001, R-002, R-201, R-503, R-602; manifest; ports; 11 fixtures | 2,000 to 4,500 every session start, the largest fixed cost |
| settings-change-guard | ConfigChange | ENFORCE | blocks a settings change that drops a required hook | | |
| single-file-folder-reminder | PreToolUse Bash | COACHING | writes to stderr and exits 0, so the model likely never sees it | R-305, R-309; manifest; ports; 2 fixtures | about 40 on some pushes |
| spec-glossary-check | PostToolUse Write | COACHING | additionalContext only | R-330, R-412, R-514, R-517; manifest; ports; fixture | about 150 on an incomplete spec |
| structure-gate | PreToolUse Write/Edit | ENFORCE | denies | | |
| task-commit-reminder | PostToolUse TaskUpdate | COACHING | additionalContext only | R-504; manifest; PORT-STATUS only; 2 fixtures | about 100 per completed task with a dirty tree |
| task-state-tracker | PostToolUse TaskCreate/TaskUpdate | ORCHESTRATION | appends task events; no output | R-213, R-601; manifest; 4 fixtures | 0 |
| verification-gate | Stop, SubagentStop | ENFORCE | blocks Stop on a red suite | | |

ENFORCE outside `settings.json`: `pre-push.sample`, installed as the git pre-push hook by `install-git-hooks.sh`, aborts a push when port verification fails (its R-215 SHA-reachability step was removed in IAN-568); it enforces only where that installer has run.

SUPPORT (sourced, not registered): build-lane-quiet, dependency-add-scan.py, git-invocation, log-rule-fire, pr-monitor-instruction, pr-range-checks, repo-identity, scope-match, security-review-ledger-path, security-surface, session-metrics, shell-command-scan, shell-command-segments.py, shell-command-tokens, tool-response-output, install-git-hooks (a manual installer). No dead hook was found.

## Skills, agent roles, audit definitions, and prompts

Every skill is ported to `cursor/skills/<name>/` and `codex/skills/<name>/`, and `skills-lint` checks all of them, so those are not repeated per row. "Always" is the description line loaded into every session's skill list; "body" loads on invocation.

| item | type | class | rationale | enforce-backed part | other dependents | always / body tokens |
|---|---|---|---|---|---|---|
| task-start | skill | ORCHESTRATION | start checklist | task-tier.sh, finding.sh: the ledger the gates read (task-provenance.sh was removed in IAN-568) | rules R-109, R-212, R-517; 3 manifest rows; many fixtures; invoked by build-fast, task-cleanup, ticket-lifecycle | 34 / 7,100 |
| task-cleanup | skill | ORCHESTRATION | end checklist | scan.sh has a fixture only | R-607, R-608; fixtures task-cleanup-scan, merge-authority-rule-text | 31 / 5,400 |
| ticket-lifecycle | skill | ORCHESTRATION | ticket narration; the gates check the key, not the skill | none | R-106, R-503, R-605, R-606; 2 manifest rows | 70 / 3,400 |
| tdd-gated-dispatch | skill | ORCHESTRATION | slice sequencing; enforcement is tdd.sh plus protected-path-guard, outside the skill | none | R-403, R-412 name it; uses test-author, implementer, slice-critic | 162 / 5,000 |
| build-by-slice-require-review | skill | ORCHESTRATION | slice-plan sequencing | none | R-517; fixture spec-glossary-check | 130 / 2,800 |
| build-fast | skill | ORCHESTRATION | speed workflow | build-lane.sh read by build-lane-quiet (relaxes reminders only) | R-109, R-211, R-514, R-517; 10 manifest rows; 5 fixtures | 99 / 1,300 |
| repo-setup | skill | ORCHESTRATION | scaffolding checklist | setup.sh fixture only | R-607, R-608; 1 manifest row; 4 prompt templates | 88 / 2,100 |
| feature-create | skill | ORCHESTRATION | feature checklist | scaffold.sh fixture only | R-607, R-608 | 55 / 2,300 |
| cleanup-specs-plans | skill | ORCHESTRATION | housekeeping | inventory.sh fixture only | invoked by task-cleanup | 64 / 1,700 |
| all-hands | skill | ORCHESTRATION | runs every audit agent | none | names nine audit agents | 57 / 1,200 |
| spec-grounding | skill | COACHING | procedure | check.sh fixture only | R-412 | 125 / 1,800 |
| bug-hunt | skill | COACHING | procedure | dangling-refs.sh fixture only | | 47 / 1,000 |
| gof | skill | COACHING | four-perspective review | none | R-517 | 60 / 1,200 |
| documentation-create | skill | COACHING | prose guidance | prose-flags.sh fixture only | | 78 / 1,800 |
| resolve-user-feedback | skill | COACHING | procedure | feedback.mjs fixture only | | 39 / 1,600 |
| add-stack-track | skill | COACHING | procedure | none | invokes structure-conventions | 90 / 1,200 |
| known-issues | skill | COACHING | pointer | none | | 30 / 170 |
| protocol | skill | COACHING | pointer | section.sh fixture only | | 30 / 170 |
| structure-conventions | skill | COACHING | pre-read of rules the hooks already enforce | none (enforcement is in structure-gate and siblings) | eleven R-3xx ids; skills-lint property 7; cursor .mdc via render-cursor-skills | 127 / 1,400 |
| test-author | agent | STRUCTURAL | TDD authorship split: writes only tests | role-policy.json via protected-path-guard (codex-test-author-guard was removed in IAN-568) | | 112 / 800 |
| implementer | agent | STRUCTURAL | makes RED green, never writes tests | role-policy.json | | 93 / 700 |
| slice-critic | agent | STRUCTURAL | read-only fresh-context slice review | role-policy.json deny any | | 135 / 800 |
| spec-conformance-review | agent | STRUCTURAL | read-only diff-against-spec review | role-policy.json | | 176 / 1,300 |
| pr-reviewer | agent | STRUCTURAL | the R-517 review, read-only | role-policy.json; the guard checks the section, not the agent | | 171 / 400 |
| security-reviewer | agent | STRUCTURAL | R-109 review on the strongest model | role-policy.json; the guard checks the section and ledger | | 154 / 500 |
| audit-criticism, -engineering, -security, -customer, -financial, -legal, -marketing, -design, -ux | agents | COACHING | audit personas; nothing gates on them (audit-signal-check reads audit outputs, not agents) | none | all ported to cursor agents and commands, codex agents and skills; invoked by all-hands | about 1,000 / 33,000 total |
| `audits/*.md` (9) | audit stubs | COACHING | pointer files forwarding to the agent files | none | rulebook/audits.md, README, cursor audit commands | 0 / about 190 each |
| security-review-prompt | prompt | STRUCTURAL | the contract the R-109 artefact must satisfy | shape pinned by fixtures and read by the guard | | 0 / 1,200 |
| codex-pr-review-prompt | prompt | STRUCTURAL | the R-517 template the guard names | fixture r109-rule-text | | 0 / 1,800 |
| spec-template | prompt | ENFORCE-adjacent | spec-glossary-check reads the structure it defines | 1 manifest row | | 0 / 860 |
| codex-spec-review-prompt | prompt | COACHING | spec review template | none | task-start only | 0 / 1,600 |
| subagent-branch-setup | prompt | COACHING | pasted into subagent prompts | none | tdd-gated-dispatch | 0 / 700 |
| feature-list, observability, stack, user-stories-readme, user-story-area templates | prompts | ORCHESTRATION | seed file content for scaffolding scripts | fixtures feature-create-scaffold, repo-setup | | 0 / 75 to 570 each |

## Stale or wrong enforcer tags

- **R-506 and R-513**: the manifest says advisory, but the hooks emit `ask`.
- **R-107 and R-203** name warn-only SessionStart checks (hookspath-drift-check, hook-integrity-check); the real denials are destructive-command-guard and settings-change-guard.
- **R-102** names redact-output, which cannot block. **R-330** names spec-glossary-check, which is advisory (lexicon-gate, which did the deny, was removed in IAN-568). **R-516** names the advisory enforcement-guard-check and omits settings-change-guard. **R-605** omits linear-todo-label-gate.
- **R-316, R-317, R-320** rely on ESLint rules that are opt-in per repository (`.enforce.json`); with the option off, only the judge or an advisory reminder remains. **R-303**'s no-restricted-paths needs `importZones`.
- **Hook-tagged rules that are really COACHING**: R-322, R-341, R-345, R-346, R-351, R-501, R-503, R-504, R-508, R-511, R-518, R-601, R-602.
- **Judge-only rules** (R-315, R-334, R-363, R-364, R-365) are probabilistic and pass when the judge has no API key.

## ENFORCE items that look redundant

1. **Secret rules R-102, R-103, R-108** all resolve to secret-scan; R-103 is a subset of R-102.
2. **R-107 and R-203 share destructive-command-guard** for attempted hooksPath changes, but hookspath-drift-check is not a duplicate: it detects a hooksPath configured before the session began, which no command in the session would trigger. The two are complementary prevention and detection, not redundant.
3. **Ticket presence was checked by three hooks** until IAN-568 removed ticket-at-start-gate, which checked the local ledger before the first edit and every commit; pr-ticket-ref-gate checks that the published commits or PR body carry a `Refs:` line, and commit-message-guard's R-214 trailer check, also removed in IAN-568, covered out-of-scope staging. A valid local ledger does not publish the reference, so the PR-time check is not subsumed; the overlap is in timing, not in what is proved.
4. **Scope was checked twice** from one ledger, by scope-widening-gate at write time and commit-message-guard at commit; IAN-568 removed both.
5. **Test-file edits** (resolved in IAN-568, which removed codex-test-author-guard): codex-test-author-guard asked, then protected-path-guard denied the same write once a slice is RED, so the user is asked about an edit that will be refused.
6. **Hook-registration checks**: settings-change-guard (blocks) and enforcement-guard-check (warns) compute the same required-minus-registered set from command basenames. redaction-guard-check is narrower but not redundant: it also checks that the two secret hooks are registered on the right events and exist on disk, which the basename comparison does not.
7. **Push-time cost**: about ten hooks spawn per push, four of them per-language linter gates with identical structure, each resolving the outgoing base again.
8. **R-316, R-317, R-325** carry both a deterministic ESLint rule and the probabilistic judge; where the rule is on, the judge adds little. **R-362 is not in this group**: transaction-client-required checks statements inside an existing transaction callback, while the judge also catches related writes that never open a transaction, so both halves stay.
9. **SessionStart on compaction**: session-start (empty matcher, so it also runs on compact) and post-compact-rules both inject, about 2,600 to 5,200 tokens together, and post-compact-rules is a hand-copied subset of CLAUDE.md that can drift.

## Recommendations

### The switch that runs the ablation

The `lean` profile in `claude/enforce/harness-profiles.json` is the switch the ablation below needs. It lists, by id, every COACHING and ORCHESTRATION rule line, hook registration, SKILL.md, audit agent, and reference file this audit found, and it deletes none of them. `translate/apply-profile.mjs` is the one filter every consumer uses, and it fails when a listed id no longer exists, so the list cannot drift from the tree. It keeps every ENFORCE hook, `harness-sync`, `rulebook/reference.md`, and the scripts the gates run under task-start and build-fast. `./sync.sh --profile lean` installs the lean harness into all three tool homes and records the profile so that `harness-sync` keeps it. `./sync.sh --profile full` restores everything through the `.sync-manifest` allowlist. Lean settings take effect from the next session, because settings-change-guard blocks a mid-session settings change that drops a hook the manifest requires. `node translate/cursor.mjs --profile lean --write --root <dir>`, and the same command for `codex.mjs`, render the lean Cursor and Codex ports.

`apply-profile.mjs` also holds a protected set that is kept separate from the profile file. No profile may remove any item in it, in any category: every ENFORCE and STRUCTURAL hook in the Hooks table (both as a registration and as its `hooks/<name>.sh` file), `harness-sync`, the six STRUCTURAL agents, the ENFORCE and STRUCTURAL rule ids, anything under `enforce/`, every skill script and data file, and `rulebook/reference.md`. It also covers the two STRUCTURAL prompt contracts, `prompts/spec-template.md`, and every file under `hooks/` except the scripts of the COACHING and ORCHESTRATION hooks. A profile that names a protected item is refused. The `harness-profile-closure` fixture parses the Hooks and rules tables of this document. It fails when an ENFORCE or STRUCTURAL row is missing from the protected sets, and when a hook registered in `settings.json` is neither protected nor classified here.

The five scaffolding templates classed ORCHESTRATION above (`prompts/feature-list-template.md`, `observability-template.md`, `stack-template.md`, `user-stories-readme-template.md`, and `user-story-area-template.md`) are deliberately left out of lean. The repo-setup `setup.sh` and feature-create `scaffold.sh` scripts, which lean keeps, read them. Hiding the templates would break those scripts while their fixtures still expect them to work.

### Known limits of the lean profile

- The hand-authored Codex session-start and handoff skills and the Cursor session commands are not generated from `claude/`, so they survive a lean port and still point at the session procedure lean hides.
- Under lean, the harness-sync SessionStart hook sees the live tree differ from the checkout at every session start. It therefore re-runs `./sync.sh`, which re-applies the recorded profile, on every session instead of only when the checkout changes.

### Delete outright (no mechanism, no dependent that needs them)

1. **R-002**: restates R-001. Remove the line and the one fixture assertion that pins it.
2. **The nine `claude/audits/*.md` pointer stubs**: pure indirection to the agent files; repoint `rulebook/audits.md` and the README at the agents.
3. **single-file-folder-reminder**: it writes to stderr on push and exits 0, so the model most likely never sees it. Either make it an additionalContext reminder or delete it; as written it costs a process per Bash call for no effect.
4. **known-issues and protocol skills**: 170-token pointers to files the rules table already names; the reads work without a skill.

### Decide by the ablation run

- All 35 COACHING rule lines and the 6 ORCHESTRATION ones (about 2,260 always-loaded tokens), except the security-posture lines R-104, R-201, and R-202, which I would keep regardless of the result because a missed prompt injection or leaked artifact is not something an ablation of eight tasks can measure.
- The thirteen convention files (1,100 to 15,300 tokens each on trigger; CLAUDE-PYTHON.md loads on every `*.py`).
- The COACHING reminder hooks (clean-code, observability, dockerfile, new-file-header, flat-directory, handoff-check, task-commit-reminder, spec-glossary-check, pr-monitor-reminder, audit-signal-check, parallel-session-check, model-switch-guard).
- session-start's injection (2,000 to 4,500 tokens every session) and post-compact-rules (about 800 per compaction).
- The ORCHESTRATION skill bodies (task-start, task-cleanup, ticket-lifecycle, tdd-gated-dispatch, build-by-slice-require-review, feature-create, repo-setup, cleanup-specs-plans, all-hands) and the COACHING skills.
- The nine audit agents and their descriptions (about 1,000 always-loaded tokens).

### Unsure how to classify

- **task-start**: the prose is orchestration, but its scripts write the ledger that ten gates read. Pruning must keep the scripts and the ledger contract; the skill could shrink to the scripts plus a short usage note.
- **tdd-gated-dispatch**: sequencing only, but R-403 and R-412 name it as the owner of the flow the lock enforces.
- **build-fast**: its lane classifier really changes hook behaviour, but only to quiet reminders.
- **The four warn-only SessionStart verifiers** (hook-integrity-check, enforcement-guard-check, hookspath-drift-check, redaction-guard-check): tamper and coverage checks that cannot fail closed. If a hash mismatch should stop a session, hook-integrity-check belongs in ENFORCE and needs a blocking channel; as written it is COACHING.
- **redact-output**: security-relevant but structurally unable to block.
- **`rulebook/reference.md`**: coaching as a whole, but the nine judge-tier blocks are inputs to judge-diff.sh.
- **harness-sync**: classed ORCHESTRATION, but it is the delivery path for every guard (R-003), so the ablation switch must never disable it.

## Estimated context savings from disabling the candidate set

| Item | Tokens | When |
|---|---|---|
| COACHING and ORCHESTRATION rule lines in CLAUDE.md | about 2,260 | every session |
| `rules/session-types.md` | about 550 | every session |
| COACHING and ORCHESTRATION skill descriptions | about 1,420 | every session |
| audit agent descriptions | about 1,000 | whenever agents are listed |
| session-start injection | 2,000 to 4,500 | every session start, resume, clear, compact |
| post-compact-rules | about 800 | every compaction |
| reminder hooks | 100 to 500 | per code-writing turn |
| convention files | 1,100 to 15,300 each | when a matching path is touched |

Fixed per-session saving: roughly **7,000 to 10,000 tokens**, about 4 to 5 percent of a 200k window, before any convention file loads. On Python work the saving grows by up to about 19,000 tokens (CLAUDE-PYTHON.md and CLAUDE-OBSERVABILITY.md both match every `*.py`). These are character-based estimates; the ablation run should measure real token use per task.

## Proposed ablation suite (not run)

Each task replays completed work from the pre-fix commit, once under the full profile and once under `lean`. A task passes only when its objective condition holds; alongside pass or fail, record wall time, total tokens, guard denials, and defects found afterwards by CI or review.

| # | Task (source) | Repo | Kind | Pass condition |
|---|---|---|---|---|
| 1 | Expired password-reset rows are never deleted by the cleanup job (IAN-368) | template-fastapi-nuxt | backend bug | a new test inserts an expired row and a fresh row; after the job only the fresh row remains; the full server suite is green |
| 2 | Fix invalid Next.js route exports (IAN-487) | Doppelscript web | framework bug | `next build` exits 0; a route-module test asserts only allowed exports |
| 3 | Extension worker crashes: the shared barrel pulls `document` into the service worker (IAN-411) | Doppelscript extension | bundling bug | the service-worker bundle contains no DOM global reference (grep of the built file); the extension test suite is green |
| 4 | Cover the migration engine's production TLS branch with a test (IAN-306) | template-fastapi-nuxt | security test (R-406) | the new test passes, and removing TLS from the engine makes it fail (a one-line mutation check) |
| 5 | Replace the six bare `Any` annotations in apps/server/tests (IAN-384) | template-fastapi-nuxt | refactor | `mypy --strict apps/server/tests` exits 0 with no `Any`; tests unchanged and green |
| 6 | User-stories coverage test flakes under pipefail (IAN-403) | Voyager 2.0 | CI flake | a deterministic reproducer fails on the pre-fix revision and passes after the fix; 50 consecutive CI runs as supplementary evidence |
| 7 | Add microphone dictation to chat inputs (IAN-412) | Doppelscript web | UI feature | the e2e spec for dictation passes; Lighthouse accessibility is 100 on the chat page |
| 8 | tdd.sh cannot prove RED in a pnpm monorepo that keeps vitest per package (IAN-405) | agent-governance | harness bug | the tdd-monorepo-package fixture passes; the full fixture suite is green in CI |

Task 6 is scored on a deterministic reproducer, not on repeated runs alone: before scoring, the pre-fix revision must fail a test that forces the `printf | grep -q` under `pipefail` condition (for example a long enough restated criterion), and the fixed revision must pass it; 50 consecutive green runs are supplementary evidence only.

The suite mixes four repositories, three stacks, bugs, a feature, a refactor, a flake, and a security test, and task 8 exercises the harness on itself. A COACHING item earns its keep only if `lean` fails a task that `full` passes, or lets a defect through that `full` catches.
