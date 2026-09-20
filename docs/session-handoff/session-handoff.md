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

Merged 2026-09-20 (detail in `git log` and each ticket): IAN-156 (#91), which unblocked test authors from an impossible RED, and IAN-175 (#92), the R-334 engine-case amendment plus the slice-lock untracking. IAN-173's spec is open as draft #94, 258 lines, adversarially reviewed with all 21 findings dispositioned. Tickets opened: IAN-165, IAN-172, IAN-176, IAN-177, IAN-184.

## 5. Pending (by urgency)

Linear is authoritative for all of these; the detail lives on each ticket.

1. **Sync** (2 min): `git pull --ff-only && ./sync.sh` in the primary checkout.
2. **IAN-183 then IAN-184** (~90 min): until both land, a test author is still refused at Stop. IAN-183 is in flight, see section 7.
3. **IAN-173** (~2 h): spec approved, three slices planned, nothing built. The only shovel-ready item.
4. **IAN-172** (~4 h, high): employer work profile. Open risks: Codex sending employer code to a personal plan, `settings.json` replaced at SessionStart, `global-memory/` tracked on a public remote behind a `[manual]` rule.
5. Lower: IAN-157, IAN-176, IAN-177, IAN-165, IAN-195.

**No ticket yet:** `tdd.sh red` exits 0 when it refuses to certify. The printed verdict is the only truth, which is worse than the existing "never pipe through tail" lesson, because capturing the exit status correctly still misleads.

## 6. Next session

1. Run pending item 1 before anything else.
2. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` inside this repository, never `~/.claude/enforce/tdd.sh`: the installed copy can predate the edit under test.
3. A decision recorded in a PR document and not in an assertion is enforced by nothing: two fixtures passed against code doing the opposite of their document, caught only by an adversarial reviewer. When a document states a bound, write the assertion in the same slice.
4. IAN-173 starts at slice 1 (the invariants-test block), not at the files. B-2's line-coverage check reads `git show 48f3b5c:claude/CLAUDE-DATABASE.md`; pin that sha.
5. IAN-173's HIGH finding, easy to lose: `paths:` frontmatter globs are what auto-load a convention file, and a dispatch table loads nothing. The engine files take disjoint globs and the shared `**/migrations/**`, `**/src/database/**`, `**/src/repositories/**` stay on the base file alone, or every project loads both engines' rules.
6. Rebase before starting, and again before merging. `main` moved three times today under one session, and two handoffs collided in the same file.
7. The R-801 engineering-audit signal fires on every push and is accumulating: `claude/enforce` and `claude/hooks` are both well past the threshold since the 2026-09-18 audit. Advisory.

## 7. Second session, 2026-09-20 afternoon (IAN-218, closed)

Appended, not overwritten: sections 1 to 6 are still live and untouched.

- **Branch:** `claude/harness-open-source-value-4mivg8`, pushed, no PR.
- **Shipped:** `docs/tickets/2026-09-20-track-and-release-backlog.md` (sixteen items) and a `linear` block in `claude/TICKET-TRACKER.template.json`.
- **Tickets:** IAN-202 to IAN-217 opened, plus IAN-218 for this session, closed at 76 actual minutes against 90 (ratio 0.84, rework 1).
- **The rework:** the R-605 gate was disabled all session (no tracker config) and activated the moment that file was written, refusing a commit after four had landed. A gate depending on a gitignored per-machine file is off by default on every fresh checkout.
- **IAN-219 (new):** the MCP permission layer does not port. Cursor runs the R-105 guard but never evaluates an `mcp__*` allow entry; whether Codex reaches the guard at all is unverified, and that decides whether it is an ergonomics or a security gap.
- **Carried forward:** that live config was written in an ephemeral container and does not reach the laptop. Copy the `linear` block from the template and fill in team and project locally, or R-605 stays disabled there.

### Findings worth keeping

1. The `linear` block never existed in the template despite Linear being the live tracker since at least IAN-121. Its convention (fields in a fenced `ticket-fields` description block, four states as labels since Linear has no custom fields) was reconstructible only by reading existing issues.
2. `sync.sh:161` is `rsync -a --checksum` with no `--backup`, so a live file still tracked upstream and edited locally is overwritten without notice at every SessionStart. Detail in IAN-204.
3. `CLAUDE-PYTHON.md` serves 1000 lines of FastAPI conventions to every Django repository, naming Django zero times. IAN-205, decided 2026-09-20: add Django, re-estimated 300 to 180 from tracker history.


### In flight when this session closed

Two sibling cloud sessions were spawned on 2026-09-20 and were still working:

- `session_01XHrKchQUahdxbyBtr4Tya5`: IAN-183, the hook-latency flake, on `fix/hook-latency-flake` cut from `origin/main`. Told not to widen the budget (R-204) and that IAN-115 already claimed this fix.
- `session_018t47yhHeX319uN9Wj1hNhR`: re-baselining IAN-202 to IAN-219 estimates against tracker history, on `chore/re-baseline-estimates`. IAN-205 is its worked example.

Neither had reported back. Check with `get_session` and `list_events` before redoing either.

### Owner actions carried forward

1. Add the seven `mcp__Linear__*` entries to `permissions.allow` in `claude/settings.json`, or every MCP call keeps prompting. An agent cannot do this; the self-modification classifier refuses it.
2. Create `~/.claude/TICKET-TRACKER.json` from the template's new `linear` block, or R-605's gate stays off locally.
3. `claude/harness-open-source-value-4mivg8` fails R-509 on a pre-existing `session-end.test.sh` assertion that also fails at its base commit `d426098`. `main` passes it. Merge `main` (needs `git fetch --unshallow`) rather than re-fixing it.

<!-- task-state:begin -->
## Task state

- [completed] Add a linear block to TICKET-TRACKER.template.json (task 1) (updated 2026-09-20T14:33:10Z)
<!-- task-state:end -->
