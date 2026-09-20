# Session Handoff: 2026-09-20, IAN-156 RED fix (#91), R-334 engine case convention (#92), database split specced (#94)

Two sessions ran in parallel today and both wrote here. This file merges them; where a fact came from one session only, it is still true.

## 1. Last commit

- `main` is at `1d3305f`. Today's merges, oldest first: `#89` (IAN-174, codex hook adapter), `#90` (handoff), `#91` (`1770b25`, IAN-156, tdd RED past manifest drift), `#92` (`1e0c8af`, IAN-175, R-334 engine case convention), `#93` (handoff), `#95` (this handoff).
- `./sync.sh` last ran before `#92` merged, so the live `~/.claude` carries the old R-334. Run it first next session.
- `#94` is an open draft holding only the IAN-173 spec.

## 2. Production state

- **R-334 amended.** The word order is fixed (base noun first, aggregate root repeated by every entity in the aggregate) and the separator follows the case convention of the engine or language the name lives in. `trip_legs` and `tripLegs` are the same name; reordering the words or dropping the root is the defect. Fixture: `enforce/tests/r334-engine-case-rule-text.test.sh`.
- **`tdd.sh red` tolerates manifest drift** (IAN-156): a failing `hook-hashes-closure.test.sh` no longer blocks a RED when every reverse-closure line names a test file the red command named. `tdd.sh expected-red` answers the same question read-only. `green` tolerates nothing.
- **`.claude/tdd-lock.json` is untracked and gitignored** as of `#92`. `#89` had committed it, so every checkout pulling `main` inherited a foreign open slice and `tdd.sh open` refused to start one. It blocked this session twice and needed the owner to authorise closing another session's lock.
- Codex is over quota until 2026-09-21 02:26. Every test author and every R-517 review today ran on the recorded Claude fallback. Codex exits 0 while printing its usage-limit error, so the log is the verdict, never the exit status.
- Local branches that are storage, not work: `park/b3-gate-expected-red-fixture` (a deliberately red fixture for IAN-184; do not merge) and `docs/capability-assessment` at `43232f5`, committed and deliberately unpushed pending the owner's call under R-106.

## 3. Session metrics

- PRs merged today: 4 plus two handoffs. Open: `#94` (draft).
- IAN-156: 170 actual minutes against 120 (ratio 1.42), rework 1. The overrun was scope discovery, not a wrong tier; the p80 would still have been short.
- IAN-175: 130 actual minutes against 60 (ratio 2.17), human estimate 45 (human_speedup 0.35, slower than a senior engineer alone), rework 1. Roughly half was the gate loop: every RED and GREEN runs the full fixture suite at 3 to 4 minutes, two test-author dispatches cost 6 and 17 minutes, and two reviews cost 7 minutes each.
- Adversarial reviews returned 21 findings on the IAN-173 spec and 6 on the `#92` diff, including one HIGH each. Both caught defects no fixture would have.

## 4. What shipped

- **IAN-156 (#91).** Before it, writing a slice's own fixture made the closure fixture red and `tdd.sh red` refused, so a test author in this repository could never reach a RED. Its R-517 review found a HIGH: the toleration also reached `cmd_green`, recording GREEN for an edited hook plus an unhashed fixture. Fixed in slice B-4 with four fixture directions.
- **IAN-175 (#92).** The R-334 norm line, the Spec in `rulebook/reference.md`, a 144-line fixture, both regenerated ports, the hash manifest, and the slice-lock untracking.
- **IAN-173 spec (#94, draft).** `claude/docs/superpowers/specs/2026-09-20-database-engine-tracks-design.md`, 258 lines, adversarially reviewed and owner-approved, all 21 findings dispositioned in its `## Spec review` section.
- Tickets opened: IAN-165 (hook language policy), IAN-172 (employer work profile), IAN-176 (translator `--check` in CI), IAN-177 (`CLAUDE-BACKEND.md` pool path), IAN-184 (gate wiring plus the hook-latency flake).

## 5. Pending (by urgency)

1. **Sync** (2 minutes): `git pull --ff-only && ./sync.sh` in the primary checkout.
2. **IAN-184** (about 90 minutes): wire `verification-gate.sh` to `expected-red`, and fix the `hook-latency.test.sh` flake that blocks its RED. Until this lands, a test author still gets blocked at Stop even though `tdd.sh red` now works. The fixture is parked; see section 2. The flake is real and reproducible (330ms against a 348ms budget standalone), it already carries `# Shard: serial`, IAN-115 closed as having fixed it, and it also fires when two suites run at once. Do not widen the budget (R-204).
3. **IAN-173** (about 2 hours): the database engine-track split. Spec approved, three slices planned, nothing built.
4. **IAN-172** (about 4 hours, high): the employer work profile. Verified safe: the ticket gate and the Linear writes disable themselves without `~/.claude/TICKET-TRACKER.json`, which is gitignored. Open: Codex sending employer code to a personal ChatGPT plan, `settings.json` replaced at SessionStart, and `claude/global-memory/` as 30 tracked files on a public remote with only a `[manual]` rule keeping employer content out.
5. **IAN-157** (about 3 hours): fired five times across the two sessions, refusing a `tdd.sh close`, two test-author writes, a commit against a branch `git checkout -b` had not actually created, and a scratchpad write whose path it read as production.
6. Lower: **IAN-176** (20 minutes, and IAN-173 adds two convention files that need porting), **IAN-177** (15 minutes), **IAN-165** (45 minutes).
7. **No ticket yet:** `tdd.sh red` exits 0 when it refuses to certify. The printed verdict is the only truth, which is worse than the existing "never pipe through tail" lesson because capturing the exit status correctly still misleads.

## 6. Next session

1. Run pending item 1 before anything else.
2. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` inside this repository, never `~/.claude/enforce/tdd.sh`: the installed copy can predate the edit under test, and `harness-root.sh` does not cover a human typing the installed path.
3. A decision recorded in a PR document and not in an assertion is enforced by nothing. Two fixtures passed against code doing the opposite of their document, and only an adversarial reviewer running the scenario caught it. The same failure appeared in `#92`, where the rule text claimed the judge receives an input that does not exist. When a document states a bound, write the assertion in the same slice.
4. IAN-173 starts at slice 1 (the invariants-test block), not at the files. B-2's line-coverage check reads the pinned pre-split copy `git show 48f3b5c:claude/CLAUDE-DATABASE.md`; pin that sha rather than re-deriving it.
5. IAN-173's HIGH finding, easy to lose: `paths:` frontmatter globs are what auto-load a convention file, and a dispatch table loads nothing. The engine files take disjoint globs and the shared `**/migrations/**`, `**/src/database/**`, `**/src/repositories/**` stay on the base file alone, or every project loads both engines' rules.
6. Rebase before starting, and again before merging. `main` moved three times today under one session, and two handoffs collided in the same file.
7. The R-801 engineering-audit signal has fired on every push today: 30 commits on `claude/enforce`, 15 on `claude/hooks` since the 2026-09-18 audit. Advisory and accumulating.
