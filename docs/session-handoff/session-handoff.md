# Session Handoff: 2026-09-20, five sessions: IAN-156, R-334, the R-2xx rules, the IAN-173 spec, the R-605 audit, the IAN-184 gate, the README landing copy

Five sessions ran today and all wrote here. This merges them; detail is on each ticket.

**Over R-602's 8 KB by about 1.5 KB, deliberately.** That limit assumes one session per handoff. Everything historical here has already been compressed to one line and pushed onto its ticket; what remains is the pending list, the production warnings, and the next-session rules, and cutting any of those to satisfy a size check would trade the document's purpose for its metric. Filed as IAN-266.

## 1. Last commit

- `main` is at `ce44eda`, `docs(readme): rewrite the root README as adoption-facing landing copy (#102)`. Today's merges: `#89` to `#93`, `#95`, `#96`, `#98`, `#102`. This file is `#103`, merging `#99` and the README session.
- `./sync.sh` ran from `main` at `ce44eda` after `#102`, so the live `~/.claude` is current. The earlier "predates R-334" warning is resolved.
- Open: `#94` (IAN-173 spec), `#97` (IAN-184, two HIGH), `#100` (IAN-218), `#101` (IAN-254).
- `#100` and `#101` are siblings forked at `7b72052`, not a stack: they share six commits and both rewrite this file. Fold them, or the second conflicts.

## 2. Production state

- **Two scope gates fail open on macOS. IAN-265, urgent.** `commit-message-guard.sh:217` and `scope-widening-gate.sh:102` call `mapfile`, a bash 4 builtin; `/usr/bin/env bash` here is `/bin/bash` 3.2.57. The call fails, the array is empty, and the next line is a length test returning allow on empty, so R-212 and R-214 do not fire here and emit nothing while not firing. CI is ubuntu with bash 5 and passes. Arrived in `9218cf4` (`#96`). Treat both as unenforced until fixed.
- **R-334 amended** (IAN-175): word order fixed, separator follows the engine's case convention. Fixture: `enforce/tests/r334-engine-case-rule-text.test.sh`.
- **`tdd.sh red` tolerates manifest drift** (IAN-156) when every reverse-closure line names a test file the red command named. `expected-red` answers the same read-only; `green` does not.
- **`.claude/tdd-lock.json` is untracked and gitignored** as of `#92`. IAN-188 closed on that evidence.
- **Do not sync from `fix/gate-expected-red` until `#97`'s H-1 and H-2 are fixed**: that build widens R-509, so a phase-`red` turn can end on a failing typecheck, lint or port check. `~/.claude` was rolled back to `main` at the gate session's end and re-synced from `main` at `ce44eda` after `#102`.
- The primary checkout sits on `fix/ticket-gate-exemption-telemetry`; check `git branch --show-current` before syncing from it.
- Codex over quota until 2026-09-21 02:26; every test author and R-517 review today ran on the Claude fallback. Codex exits 0 while printing its usage-limit error, so the log is the verdict, never the exit status.
- `hook-latency.test.sh` passed the gate session (308ms vs 348ms) and failed the README session (344ms vs 324ms). The budget is derived from a bare-spawn control measured per run, so it floats with load: both readings are real and the flake is load-dependent, not absent. Do not widen it (R-204).
- Storage branches, not work: `park/b3-gate-expected-red-fixture` (superseded), `docs/capability-assessment` at `43232f5` (unpushed, owner's R-106 call), `fix/tdd-red-commit-anchor` (empty).

## 3. Session metrics

Per-ticket actuals are on the tickets; these are the figures that change a future estimate.

- PRs merged: 5 code plus handoffs, rework 4, velocity normal.
- Ratios: IAN-156 1.42 (scope discovery, not a wrong tier), IAN-175 2.17 (human_speedup 0.35, half the time in the gate loop), IAN-257 0.56 (human_speedup 4.29).
- **R-906:** IAN-257's 50-min estimate came from the standard/llm median, a sample dominated by gate-loop work. Estimate documentation-only standard tasks near 30.
- Adversarial reviews: 21 on the IAN-173 spec, then 6, 8, 9, 9, 10 on `#92`, `#96`, `#97`, `#98`, `#102`; a HIGH in each.
- The audit session (35 min, 26 Linear writes) is **not comparable** to code velocity.

## 4. What shipped

Detail is on each ticket; these are one line apiece for traceability.

- **IAN-156 (#91).** `tdd.sh red` past manifest drift, so a test author here can reach a RED.
- **IAN-175 (#92).** The R-334 norm line and Spec, a 144-line fixture, both ports, the lock untracking.
- **R-212, R-213, R-214 (#96).** Scope declaration, provenance tags, findings-to-ticket, each with an enforcer, fixture and manifest row, plus the `chmod 000` fixture that asserted nothing as uid 0. Deferred: IAN-224, IAN-225. **Two of these enforcers do not run on macOS: IAN-265.**
- **IAN-173 spec (#94, draft).** `claude/docs/superpowers/specs/2026-09-20-database-engine-tracks-design.md`, 258 lines, 21 findings dispositioned.
- **IAN-184 B-3a and B-3b (#97, draft).** The gate asks `expected-red` after a check fails and releases on exit 0, failing closed. Nothing reached `main`.
- **R-605 audit (#98).** 86 commits since `6bc9b24`, 40 uncovered. The docs-versus-code split reproduces under no definition tried, so it and the IAN-226 to IAN-249 backfill are unverified; IAN-258 carries both. Backfilled tickets have no tier or estimate, so R-906 is unaffected.
- **IAN-257 (#102).** The root `README.md` rewritten 22 to 422 lines as adoption-facing landing copy: what the harness prevents, how a feature is built through the skills, the outer/inner split between `build-by-slice-require-review` and `tdd-gated-dispatch` with a comparison table, the layout, a limitations section. Contributor prose moved to the bottom, not deleted. Its R-517 review returned 10 findings, 2 HIGH, all fixed.
- **Withdrawn, do not re-open:** the claim that `#84` and `#88` violated R-605 (IAN-251 makes exemptions recordable), and the 09-18 gap, already closed by `ticket-at-start-gate` in `6f6ca63` (`#78`, IAN-149).
- Tickets opened: IAN-165, IAN-172, IAN-176, IAN-177, IAN-184, IAN-218, IAN-220, IAN-250 to IAN-254, IAN-258, **IAN-265**, IAN-261, IAN-264. Closed: IAN-188, IAN-257.

## 5. Pending (by urgency)

1. **IAN-265** (50 min, urgent): replace both `mapfile` calls with a bash 3.2 read loop, prove it with a fixture running the guard under `/bin/bash`, and guard against bash 4 constructs generally (`declare -A`, `${var^^}`, `&>>`). Until it lands, R-212 and R-214 are unenforced here.
2. **Sync** (2 min): `git pull --ff-only && ./sync.sh` in the primary checkout.
3. **`#97`'s two HIGH findings** (60 to 90 min). The IAN-184 comment of 16:5xZ carries both verbatim with the intended fixes. H-1: `is_expected_red` never reads which check failed. H-2: `exit 0` in the checks loop skips the rest. M-1 to M-3 are owed too, and `#97` needs its `## Codex review` section.
4. **IAN-220** (120 min): `tdd.sh green` cannot anchor its hash check to a git object (the lock is gitignored) and `fix-commit-requires-test.sh` denies every bug-fix slice's implementation commit. Both need "the locked tests are committed at HEAD".
5. **IAN-172** (4 h, high): the employer work profile. Open: Codex sending employer code to a personal ChatGPT plan, `settings.json` replaced at SessionStart, `claude/global-memory/` public behind only a `[manual]` rule.
6. **IAN-173** (2 h): the database engine-track split. Spec approved, three slices planned, nothing built.
7. **IAN-157** (3 h): `protected-path-guard` fired nine times on paths nobody was writing.
8. **IAN-258** (60 min): re-derive the R-605 audit figures and reconcile the backfill.
9. **IAN-261** (30 min): `SETUP.md` step 1, `AGENTS.md`, and `RECIPES.md` each describe this repository wrongly; `RECIPES.md` calls this file ignored when it is tracked. Also removes two caveats `ce44eda` added to `README.md`.
10. **IAN-250** (60 min): rewrite the criticism audit as a senior challenging a junior's assumptions; its closing argues for self-blame against the brief.
11. **IAN-251** (30 to 45 min): the four allow paths in `pr-ticket-ref-gate.sh` are bare `exit 0`, so an exemption is never recorded and reads later like a gate that never fired.
12. **IAN-252** (40 min): `tdd.sh close` should refuse while the lock path is tracked, reading git state rather than file existence.
13. Lower: **IAN-264** (10 min), **IAN-253** (R-512's bundle exception is dead here), **IAN-176** (20 min), **IAN-177** (15 min), **IAN-165** (45 min).
14. **No ticket yet:** `tdd.sh red` and `doctor.sh` both exit 0 while refusing or reporting a fail, so the printed verdict is the only truth. `pr-ticket-ref-gate.test.sh` prints a bare `true` mid-run. `#100` and `#101` have no `docs/prs/` document.

## 6. Next session

1. Run pending items 1 and 2 first, and rebase before starting and before merging: `main` moved nine times today and handoffs collided here four times, this file included.
2. **Run `doctor.sh --full` at session start, not at the end.** IAN-265 was found only because a documentation task happened to run the gate on its way out. A gate that emits nothing when broken is indistinguishable from one that ran and allowed.
3. Read the IAN-184 thread before touching `#97`, and fix `#97` before syncing it anywhere.
4. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` here: the installed copy can predate the edit.
5. A decision in a PR document and not in an assertion is enforced by nothing. When a document states a bound, write the assertion in the same slice.
6. The hash manifest's `--update` writes to `$HOME/.claude` unless `CLAUDE_INTEGRITY_ROOT=<checkout>/claude` is set. `protected-path-guard` reads shell text, not resolved paths: prefer the Write tool over a Bash heredoc.
7. Order work by dependency, not as the user listed it: the gate session opened IAN-220 first, then found every slice depends on the `test-author` subagent IAN-184 unblocks.
8. Cite `reference.md` by rule ID, never by line range: `#96` moved R-605 from 684 to 722, stale within hours.
9. When a command's output and a document in this repository disagree, the disagreement is the finding. Five errors in the README session came from believing `SETUP.md`, `AGENTS.md` or `RECIPES.md` over a command already run.
