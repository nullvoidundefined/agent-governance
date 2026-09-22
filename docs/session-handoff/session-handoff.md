# Session Handoff: 2026-09-20 to 2026-09-22, seven sessions: IAN-156, R-334, the R-2xx rules, the IAN-173 spec, the R-605 audit, the IAN-184 gate, the README landing copy, PR triage, and the IAN-183 path-walk fix

Six sessions ran today and all wrote here. This merges them; detail is on each ticket.

**Over R-602's 8 KB by about 6 KB, deliberately, and the overage is growing each session.** That limit assumes one session per handoff. Everything historical here is already one line apiece and pushed onto its ticket; what remains is the pending list, the production warnings and the next-session rules, and cutting those to satisfy a size check trades the document's purpose for its metric. The earlier attempt to obey the cap is the direct cause of this session's worst finding: compressing four sessions into 8179 bytes silently dropped a retraction, and only an adversarial review caught it. Filed as IAN-266; **IAN-260 is the actual fix**, giving each session its own uncapped file behind a capped index, at which point this note goes away.

## 1. Last commit

`102d281` fix(hooks): walk a written path by expansion, not a process per component (IAN-183). PR #104 merged 2026-09-22 with all checks green; IAN-183, IAN-262 and IAN-301 closed. Superseded the entry below, which was current when the PR-triage session wrote this file.

- `main` is at `021c8fa`, `fix(hooks): replace mapfile so the scope guards run under bash 3.2 (#105)`. Today's merges: `#89` to `#93`, `#95`, `#96`, `#98`, `#102`, `#99`, `#103`, `#105`.
- `./sync.sh` ran from a worktree on `main` at `021c8fa`, so the live `~/.claude` carries the guard repair; both guards were re-verified firing against `~/.claude` itself.
- Open: `#94` (IAN-173 spec), `#97` (IAN-184, two HIGH), `#101` (IAN-254), `#104` (IAN-183, hook latency, CI green), `#106` (this file), `refactor/handoff-per-session-files` (IAN-260, pushed, no PR yet).
- **`#100` was closed, not merged**, at 19:31:55Z by another session or the owner, so IAN-218's branch `claude/harness-open-source-value-4mivg8` is pushed with no PR again. Reopen or re-PR it if that work is still wanted.
- `#100` and `#101` were siblings forked at `7b72052`, not a stack: they shared six commits and both rewrote this file. With `#100` closed, `#101` carries that history alone.

## 2. Production state

- **The two scope gates are enforcing again** (`#105`, IAN-267, which is canonical; IAN-265 and IAN-271 are the same bug filed by two other sessions). `mapfile` is gone from both hooks; `enforce/tests/bash32-builtin-floor.test.sh` holds the floor for the class across `claude/hooks`, `codex/hooks` and `cursor/hooks`. They were dead for about two and a half hours, from `#96` at 16:59:51Z to `#105` at 19:31:43Z.
- **A bash 4 construct does not always abort a hook**, which bounds what that fixture can promise. A parse error (`;;&`) kills the hook before it writes anything and the fixture's behavioural anchors catch it; an expansion error does not, so `${v^^}` prints "bad substitution", fails one command, and execution continues with a wrong value. The `mapfile` break was fatal only because it left `SCOPE` unset and the next line read it under `set -u`.
- **R-334 amended** (IAN-175): word order fixed, separator follows the engine's case convention. Fixture: `enforce/tests/r334-engine-case-rule-text.test.sh`.
- **`tdd.sh red` tolerates manifest drift** (IAN-156) when every reverse-closure line names a test file the red command named. `expected-red` answers the same read-only; `green` does not.
- **`.claude/tdd-lock.json` is untracked and gitignored** as of `#92`. IAN-188 closed on that evidence.
- **Do not sync from `fix/gate-expected-red` until `#97`'s H-1 and H-2 are fixed**: that build widens R-509, so a phase-`red` turn can end on a failing typecheck, lint or port check.
- **`~/.claude/.sync-source` now points at `.claude/worktrees/epic-poitras-097aba`, which is on `docs/handoff-2026-09-20-pr-triage`, not `main`.** That pointer was rewritten by this session's own `./sync.sh`. Today it is harmless, because that branch differs from `main` only by this file, but `./sync.sh` installs from whatever checkout it runs in, so a source on a code branch installs that branch. The primary checkout is separately stale, sitting on `fix/ticket-gate-exemption-telemetry` at `d426098`. Check `git -C "$(cat ~/.claude/.sync-source)" log -1` before syncing.
- Codex over quota until 2026-09-21 02:26; every test author and R-517 review today ran on the Claude fallback. Codex exits 0 while printing its usage-limit error, so the log is the verdict, never the exit status.
- `hook-latency.test.sh` passed the gate session (308ms vs 348ms), failed the README session (344ms vs 324ms) and failed this one at 450ms vs 378ms. The budget floats with load because it is six times a bare-spawn control measured per run, but the cause is not load: `#104` measured it as three hooks resolving a written file's directory one component at a time, spawning a `dirname` or `basename` per level, and its fix gives ten consecutive runs at 199 to 225ms. While red it blocks `tdd.sh red` for any slice whose tests sit in `claude/enforce/tests/`, because a RED cannot be certified while that suite is red. Do not widen it (R-204).
- `#101` conflicts on this file and cannot be resolved without cutting content that includes three owner actions; `#100` had the same conflict before it was closed. IAN-260 dissolves that class of conflict by giving each session its own file.
- Storage branches, not work: `park/b3-gate-expected-red-fixture` (superseded), `docs/capability-assessment` at `43232f5` (unpushed, owner's R-106 call), `fix/tdd-red-commit-anchor` (empty).

## 3. Session metrics

Per-ticket actuals are on the tickets; these are the figures that change a future estimate.

- PRs merged: 6 code plus handoffs, rework 6, velocity normal. The triage session merged `#98`, `#99` and `#105`, opened `#100`, `#101`, `#105` and `#106`, and closed `#100` unmerged. `#103` merged fifteen seconds before `#105` opened.
- Ratios: IAN-156 1.42 (scope discovery, not a wrong tier), IAN-175 2.17 (human_speedup 0.35, half the time in the gate loop), IAN-257 0.56 (human_speedup 4.29), IAN-267 0.60, IAN-259 0.50.
- **IAN-259's 0.50 is misleading**: the ticket was opened retroactively mid-work and never bounded the fold it is supposed to measure. Keep it out of the standard-tier baseline.
- **R-906:** IAN-257's 50-min estimate came from the standard/llm median, a sample dominated by gate-loop work. Estimate documentation-only standard tasks near 30.
- Adversarial reviews: 21 on the IAN-173 spec, then 6, 8, 9, 9, 10, 7 on `#92`, `#96`, `#97`, `#98`, `#102`, `#105`, and `#99`'s nine itemized plus about a dozen accepted content losses; a HIGH in each, and every one of those HIGHs passed CI clean.
- The audit session (35 min, 26 Linear writes) is **not comparable** to code velocity.

## 4. What shipped

Detail is on each ticket; these are one line apiece for traceability.

- **IAN-156 (#91).** `tdd.sh red` past manifest drift, so a test author here can reach a RED.
- **IAN-175 (#92).** The R-334 norm line and Spec, a 144-line fixture, both ports, the lock untracking.
- **R-212, R-213, R-214 (#96).** Scope declaration, provenance tags, findings-to-ticket, each with an enforcer, fixture and manifest row, plus the `chmod 000` fixture that asserted nothing as uid 0. Deferred: IAN-224, IAN-225. Two of these enforcers shipped dead on macOS and were repaired in `#105` (IAN-267).
- **IAN-173 spec (#94, draft).** `claude/docs/superpowers/specs/2026-09-20-database-engine-tracks-design.md`, 258 lines, 21 findings dispositioned.
- **IAN-184 B-3a and B-3b (#97, draft).** The gate asks `expected-red` after a check fails and releases on exit 0, failing closed. Nothing reached `main`.
- **R-605 audit (#98).** 86 commits since `6bc9b24`, 40 uncovered. The docs-versus-code split reproduces under no definition tried, so it and the IAN-226 to IAN-249 backfill are unverified; IAN-258 carries both. Backfilled tickets have no tier or estimate, so R-906 is unaffected.
- **The four-session fold (#98, #99).** Both merged after correcting the R-605 audit figures: 86 commits not 87, day rows 09-17 4/4 and 09-20 14/6, and a restored retraction the compression had dropped. `#99`'s review also caught the file recording a `main` its own merge list contradicted.
- **IAN-267 (#105).** The bash 3.2 guard repair, a class fixture covering nine bash 4 constructs across three hook trees, manifest rows, regenerated hashes.
- **IAN-260 (pushed, no PR).** Spec plus a 14-direction fixture for the per-session handoff split; 4 directions red awaiting the `handoff-check.sh` change.
- **IAN-257 (#102).** The root `README.md` rewritten 22 to 422 lines as adoption-facing landing copy: what the harness prevents, how a feature is built through the skills, the outer/inner split between `build-by-slice-require-review` and `tdd-gated-dispatch` with a comparison table, the layout, a limitations section. Contributor prose moved to the bottom, not deleted. Its R-517 review returned 10 findings, 2 HIGH, all fixed.
- **Withdrawn, do not re-open:** the claim that `#84` and `#88` violated R-605 (IAN-251 makes exemptions recordable), and the 09-18 gap, already closed by `ticket-at-start-gate` in `6f6ca63` (`#78`, IAN-149).
- Tickets opened: IAN-165, IAN-172, IAN-176, IAN-177, IAN-184, IAN-218, IAN-220, IAN-250 to IAN-254, IAN-258, IAN-259, IAN-260, IAN-261, IAN-264, IAN-265, IAN-266, IAN-267, IAN-271, IAN-272. Closed: IAN-188, IAN-257, IAN-259, IAN-267. IAN-265 closed as duplicate of IAN-267.
- **IAN-265, IAN-267 and IAN-271 are one bug**, fixed under IAN-267. Three sessions filed three tickets for the dead scope gates inside ten minutes, none seeing the others, because each was working from a handoff loaded before the others landed theirs. IAN-265 is closed as a duplicate; **IAN-271 still needs closing the same way.**

## 5. Pending (by urgency)

1. **IAN-295** (1 to 2 h, urgent): a cloud session with no installed harness runs **zero hooks** and says nothing. `~/.claude` is empty until `./sync.sh` runs, so R-212's scope gate, R-214's commit gate, R-518's draft-PR hook, `no-em-dash`, `secret-scan` and the rest all silently do nothing. Found because R-518's auto-draft-PR never fired for `#104`. R-003's enforcer is itself a SessionStart hook, so it cannot repair this: a hook cannot install the hooks. Same fail-open shape as IAN-267, wider blast radius.
2. **Repoint `.sync-source` and re-sync** (5 min): it currently names a worktree on a handoff branch (section 2). Point it at a checkout on `main`, run `./sync.sh`, and confirm `~/.claude/hooks/scope-widening-gate.sh` matches `main`.
3. **`#97`'s two HIGH findings** (60 to 90 min). The IAN-184 comment of 16:5xZ carries both verbatim with the intended fixes. H-1: `is_expected_red` never reads which check failed. H-2: `exit 0` in the checks loop skips the rest. M-1 to M-3 are owed too, and `#97` needs its `## Codex review` section.
4. **IAN-260** (75 min remaining): slice 1's fixture is written, pushed and red; `handoff-check.sh` needs the session-file path, then slices 2 to 4. Unblocks `#101`, and retires the fold this file keeps needing.
5. **IAN-220** (120 min): `tdd.sh green` cannot anchor its hash check to a git object (the lock is gitignored) and `fix-commit-requires-test.sh` denies every bug-fix slice's implementation commit. Both need "the locked tests are committed at HEAD".
6. **IAN-172** (4 h, high): the employer work profile. Open: Codex sending employer code to a personal ChatGPT plan, `settings.json` replaced at SessionStart, `claude/global-memory/` public behind only a `[manual]` rule.
7. **IAN-173** (2 h): the database engine-track split. Spec approved, three slices planned, nothing built.
8. **IAN-157** (3 h): `protected-path-guard` fired nine times on paths nobody was writing.
9. **IAN-258** (60 min): re-derive the R-605 audit figures and reconcile the backfill.
10. **IAN-261** (30 min): `SETUP.md` step 1, `AGENTS.md`, and `RECIPES.md` each describe this repository wrongly; `RECIPES.md` calls this file ignored when it is tracked. Also removes two caveats `ce44eda` added to `README.md`.
11. **IAN-250** (60 min): rewrite the criticism audit as a senior challenging a junior's assumptions; its closing argues for self-blame against the brief.
12. **IAN-251** (30 to 45 min): the four allow paths in `pr-ticket-ref-gate.sh` are bare `exit 0`, so an exemption is never recorded and reads later like a gate that never fired.
13. **IAN-252** (40 min): `tdd.sh close` should refuse while the lock path is tracked, reading git state rather than file existence.
14. **From the IAN-183 session** (`#104`, merged as `102d281`): **IAN-300** (30 min, the one red fixture on `main`, `session-end.test.sh`), **IAN-297** (2 h, `SessionStart:resume` now the thinnest timed chain at 423 to 428ms against 402ms), **IAN-298** (45 min, the new path-walk fixture probes only outside a git work tree), **IAN-299** (20 min, `tdd.sh` reads `role-policy.json` from `$HOME` not `CLAUDE_TDD_HOME`). **IAN-301** is Done (retroactive).
15. Lower: **IAN-264** (10 min), **IAN-253** (R-512's bundle exception is dead here; corrected 2026-09-22, the block is the `main` **ruleset's** `allowed_merge_methods`, not the repository setting, which already allows rebase), **IAN-176** (20 min), **IAN-177** (15 min), **IAN-165** (45 min).
16. **No ticket yet:** `tdd.sh red` and `doctor.sh` both exit 0 while refusing or reporting a fail, so the printed verdict is the only truth. `pr-ticket-ref-gate.test.sh` prints a bare `true` mid-run. `#101` has no `docs/prs/` document, and `#100` had none when it was closed. Whether the fixture suite should run under bash 3.2 in CI, and whether hooks should fail closed on an internal fault rather than by each one's structure, are both open from IAN-267 and unticketed.

## 6. Next session

1. **Re-read this file on `main` before opening any ticket**, not the copy injected at session start. Three sessions filed three tickets for one bug today because each trusted a handoff loaded before the others landed theirs. `git log origin/main -- docs/session-handoff/` costs seconds.
2. **Check `git worktree list` for a parallel session on the same work** before starting (R-501). Two sessions built the same fixture for the same bug today, and one of them is still uncommitted.
3. Rebase before starting and before merging: `main` moved twelve times today and handoffs collided here seven times, this file included.
4. **Run `doctor.sh --full` at session start, not at the end.** IAN-265 was found only because a documentation task happened to run the gate on its way out. A gate that emits nothing when broken is indistinguishable from one that ran and allowed.
5. **A test for a fail-open must assert the expected thing still happens**, never that an error string is absent. The first `bash32-builtin-floor.test.sh` anchor checked only that the output lacked "command not found", which an empty output satisfies, so it passed against a guard sabotaged into exactly the silence it existed to catch. The R-517 review found it; running the fixture did not, because a passing test says nothing about what it does when the code is wrong.
6. **CI passing is not evidence a guard works.** CI is ubuntu with bash 5; these hooks run on macOS with bash 3.2, the one configuration CI never exercises.
7. Read the IAN-184 thread before touching `#97`, and fix `#97` before syncing it anywhere.
8. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` here: the installed copy can predate the edit.
9. A decision in a PR document and not in an assertion is enforced by nothing. When a document states a bound, write the assertion in the same slice.
10. The hash manifest's `--update` writes to `$HOME/.claude` unless `CLAUDE_INTEGRITY_ROOT=<checkout>/claude` is set. `protected-path-guard` reads shell text, not resolved paths: prefer the Write tool over a Bash heredoc.
11. Order work by dependency, not as the user listed it: the gate session opened IAN-220 first, then found every slice depends on the `test-author` subagent IAN-184 unblocks.
12. Cite `reference.md` by rule ID, never by line range: `#96` moved R-605 from 684 to 722, stale within hours.
13. When a command's output and a document in this repository disagree, the disagreement is the finding. Five errors in the README session came from believing `SETUP.md`, `AGENTS.md` or `RECIPES.md` over a command already run.
