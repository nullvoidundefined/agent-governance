# Session Handoff: 2026-09-20, IAN-156 RED fix (#91), R-334 engine case convention (#92), database split specced (#94)

Two sessions ran in parallel on 2026-09-20 and both wrote here; a third appended section 7.

## 1. Last commit

- `main` is at `1d3305f`. 2026-09-20 merges, oldest first: `#89` (IAN-174), `#90`, `#91` (`1770b25`, IAN-156), `#92` (`1e0c8af`, IAN-175), `#93`, `#95`.
- `./sync.sh` last ran before `#92` merged, so a live `~/.claude` may carry the old R-334. Run it first next session.
- `#94` is an open draft holding only the IAN-173 spec.

## 2. Production state

- **R-334 amended.** Word order is fixed (base noun first, aggregate root repeated by every entity); the separator follows the engine's case convention. `trip_legs` and `tripLegs` are the same name; reordering or dropping the root is the defect. Fixture: `enforce/tests/r334-engine-case-rule-text.test.sh`.
- **`tdd.sh red` tolerates manifest drift** (IAN-156) when every reverse-closure line names a test file the red command named. `expected-red` answers the same question read-only. `green` tolerates nothing.
- **`.claude/tdd-lock.json` is untracked and gitignored** as of `#92`. `#89` had committed it, so every checkout pulling `main` inherited a foreign open slice and `tdd.sh open` refused to start one.
- Codex was over quota until 2026-09-21 02:26; every test author and R-517 review on 2026-09-20 ran on the recorded Claude fallback. Codex exits 0 while printing its usage-limit error, so the log is the verdict, never the exit status.
- Local branches that are storage, not work: `park/b3-gate-expected-red-fixture` (deliberately red fixture for IAN-184; do not merge) and `docs/capability-assessment` at `43232f5`, deliberately unpushed pending the owner's call under R-106.

## 3. Session metrics

- PRs merged: 4 plus two handoffs. Open: `#94` (draft).
- IAN-156: 170 actual against 120 (ratio 1.42), rework 1. IAN-175: 130 against 60 (ratio 2.17), human_speedup 0.35, rework 1. Roughly half of IAN-175 was the gate loop: every RED and GREEN runs the full fixture suite at 3 to 4 minutes.
- Adversarial reviews returned 21 findings on the IAN-173 spec and 6 on the `#92` diff, one HIGH each, catching defects no fixture would have.

## 4. What shipped

- **IAN-156 (#91).** Test authors could never reach a RED in this repository: writing a slice's own fixture made the closure fixture red and `tdd.sh red` refused. Its R-517 review found a HIGH, the toleration also reaching `cmd_green`; fixed in slice B-4.
- **IAN-175 (#92).** The R-334 norm line, its Spec, a 144-line fixture, both regenerated ports, the hash manifest, and the slice-lock untracking.
- **IAN-173 spec (#94, draft).** `claude/docs/superpowers/specs/2026-09-20-database-engine-tracks-design.md`, 258 lines, adversarially reviewed and owner-approved, all 21 findings dispositioned.
- Tickets opened: IAN-165, IAN-172, IAN-176, IAN-177, IAN-184.

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
2. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` inside this repository, never `~/.claude/enforce/tdd.sh`: the installed copy can predate the edit under test.
3. A decision recorded in a PR document and not in an assertion is enforced by nothing. Two fixtures passed against code doing the opposite of their document, caught only by an adversarial reviewer; the same failure appeared in `#92`. When a document states a bound, write the assertion in the same slice.
4. IAN-173 starts at slice 1 (the invariants-test block), not at the files. B-2's line-coverage check reads `git show 48f3b5c:claude/CLAUDE-DATABASE.md`; pin that sha.
5. IAN-173's HIGH finding, easy to lose: `paths:` frontmatter globs are what auto-load a convention file, and a dispatch table loads nothing. The engine files take disjoint globs and the shared `**/migrations/**`, `**/src/database/**`, `**/src/repositories/**` stay on the base file alone, or every project loads both engines' rules.
6. Rebase before starting, and again before merging. `main` moved three times today under one session, and two handoffs collided in the same file.
7. The R-801 engineering-audit signal fires on every push and is accumulating: `claude/enforce` and `claude/hooks` are both well past the threshold since the 2026-09-18 audit. Advisory.

## 7. Second session, 2026-09-20 afternoon (IAN-218, closed)

Appended, not overwritten: sections 1 to 6 are still live and untouched.

- **Branch:** `claude/harness-open-source-value-4mivg8`, pushed, no PR opened.
- **Shipped:** `docs/tickets/2026-09-20-track-and-release-backlog.md` (sixteen work items, four workstreams) and a `linear` block in `claude/TICKET-TRACKER.template.json`.
- **Tickets:** IAN-202 to IAN-217 opened, plus IAN-218 for this session, closed at 76 actual minutes against 90 (ratio 0.84, rework 1).
- **The rework:** the R-605 gate was disabled all session (no `~/.claude/TICKET-TRACKER.json`) and activated the moment that file was written, refusing a commit after four had landed. A gate depending on a gitignored per-machine file is off by default on every fresh checkout and cloud container.
- **Carried forward:** that live config was written in an ephemeral container and does not reach the laptop. Copy the `linear` block from the template and fill in team and project locally, or R-605 stays disabled there.

### Findings worth keeping

1. The `linear` block never existed in the template despite Linear being the live tracker since at least IAN-121. Its convention (canonical fields in a fenced `ticket-fields` description block, four states carried as labels since Linear has no custom fields) was reconstructible only by reading existing issues.
2. `sync.sh:161` is `rsync -a --checksum` with no `--ignore-existing` and no `--backup`, so a live file still tracked upstream and edited locally is overwritten without notice at every SessionStart. Detail in IAN-204.
3. `CLAUDE-PYTHON.md` serves 1000 lines of FastAPI conventions to every Django repository, naming Django zero times. Detail in IAN-205, which needs an add-or-narrow decision before scheduling.
4. A fresh checkout needs `npm ci --prefix claude/enforce` before the enforcement fixtures run; the R-509 gate caught it at this session's end.

<!-- task-state:begin -->
## Task state

- [completed] Add a linear block to TICKET-TRACKER.template.json (task 1) (updated 2026-09-20T14:35:00Z)
<!-- task-state:end -->
