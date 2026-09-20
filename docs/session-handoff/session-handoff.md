# Session Handoff: 2026-09-20, README landing copy (IAN-257, #102)

## 1. Last commit

- `main` is at `ce44eda`, `docs(readme): rewrite the root README as adoption-facing landing copy (#102)`, squash-merged from `claude/readme-landing-page-3e7d15` (branch deleted).
- This handoff is on `chore/handoff-2026-09-20-readme-landing`, not yet merged.
- `./sync.sh` ran after the merge, so the live `~/.claude`, `~/.cursor`, and `~/.codex` match `ce44eda`.

## 2. Production state

- `README.md` on `main` is 422 lines, verified by reading the file on `origin/main` rather than by the PR badge. Both HIGH review fixes are present (lines 182 and 276).
- CI on the merged range: `fixtures` pass (3m5s), `rule-judge` pass, GitGuardian pass.
- **Two scope gates are dead on this machine. IAN-265, urgent, full detail there.** `doctor.sh --full` reported `fail fixture-suites` locally on `ce44eda` while CI passed on the same content. Not a flake: `commit-message-guard.sh:217` and `scope-widening-gate.sh:102` both call `mapfile`, a bash 4 builtin, and `/usr/bin/env bash` here is `/bin/bash` 3.2.57. The call fails, the array is empty, and the next line is a length test that returns allow on empty, so R-212 and R-214 **fail open** on macOS while emitting nothing. CI is ubuntu with bash 5. Both calls arrived in `9218cf4` (#96).
- `doctor.sh` exited 0 while printing `1 fail`, the same trap as `tdd.sh red` exiting 0 when it refuses to certify. The printed verdict is the truth.
- `hook-latency.test.sh` also failed at 344ms against a 324ms budget: the known flake (IAN-184). Do not widen the budget (R-204).
- **Codex was out of quota all session** (reset 2:26 AM local), and it exits 0 while printing the limit error, so the log is the verdict. Every R-517 review today ran on the Claude fallback. Third consecutive session; treat the fallback as the default path.

## 3. Session metrics

```
## Session metrics
- Commits this session: 2
- Files changed: 3
- Files revisited (touched by 2+ commits): 0
- Velocity flag: NORMAL
```

- The script counts 2 because the branch's three commits (`3bbbb84`, `0ca6b7d`, `4cd69e1`) squashed to one on `main`.
- IAN-257: 28 actual against a 50-minute estimate, ratio 0.56, rework 1, human speedup 4.29.
- **R-906 recalibration:** the 50 came from the standard/llm median (n=21), a sample dominated by hook and enforcement work whose real cost is the gate loop. Documentation-only work does not pay that cost. Estimate documentation-only standard tasks near 30 and reserve the tier median for work that runs slices through `tdd.sh`.

## 4. What shipped

- **IAN-257 (#102).** The root `README.md` rewritten from 22 lines to 422 as adoption-facing landing copy, with the previous contributor prose relocated to `## Working in this repository` rather than deleted. Sections: positioning and quick start, why this exists, what you get (measured counts), how a feature gets built, the two build skills, the four layers, repository layout, one source three tools, install, verification, what this does not do.
- The two-build-skills section is the substantive addition: `build-by-slice-require-review` as the outer loop (cadence, two human gates) and `tdd-gated-dispatch` as the inner loop (one behavior, authorship boundaries, machine-proved RED and GREEN), with a seven-row comparison table and a paragraph stating that step 4 of the outer loop is the inner loop.
- `docs/prs/2026-09-21-readme-landing-page.md`, the required PR document.
- Tickets opened: **IAN-265** (urgent, the dead gates), **IAN-261** (three stale self-describing documents), **IAN-264** (undeclared `.enforce.json` opt-out).

## 5. The pattern worth carrying forward

Five instances in one session of one failure: **a document in this repository describing this repository, drifting from it, and being believed.** Two caught before review (unexecuted absolute claims about the slice lock; the `doctor.sh` check list copied out of `SETUP.md`). Two were the R-517 review's HIGH findings: the code-block isolation written for the wrong role, and `doctor.sh` named as a port-checks caller when it keeps its own list, where the correct three callers had already been printed by a grep earlier in the same session and `SETUP.md` was believed over that output anyway. The fifth surfaced at cleanup, `RECIPES.md` calling the handoff ignored when it is tracked.

Recorded on IAN-261: generated content is gated (`translate/*.mjs --check` fails CI on drift) and hashed content is gated (`hook-hashes.txt`), but **hand-authored prose describing the repository has no gate at all**, and agents read it as authoritative. A cheap partial answer is a fixture asserting the checkable claims those documents make: named paths exist, a file called ignored is ignored, an enumerated list matches the JSON key it mirrors.

IAN-265 is the same lesson one layer down. A gate that emits nothing when broken is indistinguishable from a gate that is allowing, so the absence of a complaint is not evidence that a guard ran.

## 6. Pending (by urgency)

1. **IAN-265** (50 minutes, urgent, start here): replace both `mapfile` calls with a bash 3.2 read loop, prove it with a fixture running the guard under `/bin/bash` specifically, and add a recurrence guard for bash 4 constructs generally (`declare -A`, `${var^^}`, `&>>`). Until it lands, treat R-212 and R-214 as unenforced here and honor them by hand.
2. **IAN-261** (30 minutes, trivial): correct `SETUP.md` step 1 (pre-monorepo clone path), `AGENTS.md` (two hand-authored `codex/` paths where the port map has four), and `RECIPES.md` (handoff claimed ignored). Delete the two caveat paragraphs `ce44eda` added to `README.md` in the same change, or they become permanent.
3. **IAN-184** (about 90 minutes): wire `verification-gate.sh` to `expected-red` and fix the `hook-latency.test.sh` flake blocking its RED. It failed again this session at 344ms against 324ms. Fixture parked on `park/b3-gate-expected-red-fixture`. Do not widen the budget (R-204).
4. **IAN-173** (about 2 hours): the database engine-track split. Spec approved, three slices planned, nothing built. Start at slice 1 (the invariants-test block), not the files.
5. **IAN-172** (about 4 hours, high): the employer work profile.
6. Lower: **IAN-157** (about 3 hours), **IAN-264** (10 minutes), **IAN-176** (20 minutes), **IAN-177** (15 minutes), **IAN-165** (45 minutes).
7. **Advisory, accumulating:** the R-801 engineering-audit signal fired on every push today. Since the 2026-09-18 audit: 26 commits on `claude/enforce`, 17 on `claude/hooks`, 15 on `cursor/rules`, 14 on `claude/rulebook`. Advisory for three sessions now.

## 7. Next session

1. **IAN-265 before anything else**, because until it lands two of the newest gates are inert here and every task run on this machine is unprotected by them.
2. **Run `bash claude/enforce/doctor.sh --full` at the start of the next session, not the end.** This session found a dead guard only because a documentation task happened to run the verification gate on the way out. Had the README work not called for it, the gates would still be silently open. Worth deciding whether that run belongs in `SessionStart`, and whether CI should carry a macOS job for the hook suites, since the whole class was invisible to an ubuntu-only matrix.
3. IAN-261 is a good follow-on: small, and it removes two caveats from the document that just became the repository's front door.
4. Before trusting any statement in `SETUP.md`, `AGENTS.md`, or `RECIPES.md`, run the command that checks it. Three of this session's five errors came from those three files.
5. When a command's output and a prose document disagree, **the disagreement is the finding**. The document does not get the benefit of the doubt for living in the same repository.
6. Assume Codex is out of quota and go to the fallback agent as soon as a first attempt prints the limit error. Do not wait for a reset, and never read its exit status as the verdict.
7. `mcp__ccd_pr__get_status` lagged real CI by minutes this session, reporting 3 passing / 0 pending while `gh pr checks` showed `fixtures` still running. Use `gh pr checks` for a merge decision.
