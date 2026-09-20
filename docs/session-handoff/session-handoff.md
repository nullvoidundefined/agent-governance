# Session Handoff: 2026-09-20, IAN-156 (#91), R-334 (#92), IAN-173 spec (#94), R-605 ticket audit

Three sessions ran today and all wrote here. This file merges them.

## 1. Last commit

- `main` is at `d426098`, `docs(handoff): record the R-334 amendment and the specced database split (#95)`. Today's merges, oldest first: `#89` (IAN-174), `#90`, `#91` (`1770b25`, IAN-156), `#92` (`1e0c8af`, IAN-175), `#93`, `#95`.
- `./sync.sh` last ran before `#92` merged, so the live `~/.claude` carries the old R-334. Run it first next session.
- `#94` is an open draft holding only the IAN-173 spec.
- Unpushed local branches from the audit session: `chore/handoff-2026-09-20-ticket-audit` (this file) and `fix/ticket-gate-exemption-telemetry` (empty, reserved for IAN-251).

## 2. Production state

- **R-334 amended.** Word order fixed (base noun first, aggregate root repeated); the separator follows the engine's or language's case convention. `trip_legs` and `tripLegs` are the same name. Fixture: `enforce/tests/r334-engine-case-rule-text.test.sh`.
- **`tdd.sh red` tolerates manifest drift** (IAN-156): a failing `hook-hashes-closure.test.sh` no longer blocks a RED when every reverse-closure line names a test file the red command named. `expected-red` answers the same question read-only. `green` tolerates nothing.
- **`.claude/tdd-lock.json` is untracked and gitignored** as of `#92`. Verified this session with a throwaway clone of `main`: no lock file, `tdd.sh status` reports `no slice open`. IAN-188 closed on that evidence.
- Codex over quota until 2026-09-21 02:26. Every test author and R-517 review today ran on the recorded Claude fallback. Codex exits 0 while printing its usage-limit error, so the log is the verdict, never the exit status.
- Storage branches, not work: `park/b3-gate-expected-red-fixture` (deliberately red fixture for IAN-184, do not merge) and `docs/capability-assessment` at `43232f5`, deliberately unpushed pending the owner's R-106 call.
- No deploy or migration. Baseline green: `pr-ticket-ref-gate.test.sh` passes all 48 directions.

## 3. Session metrics

- PRs merged today: 4 plus two handoffs. Open: `#94` (draft).
- IAN-156: 170 actual minutes against 120 (ratio 1.42), rework 1. Overrun was scope discovery, not a wrong tier.
- IAN-175: 130 against 60 (ratio 2.17), human estimate 45 (human_speedup 0.35, slower than a senior engineer alone), rework 1. Roughly half was the gate loop: each RED and GREEN runs the full fixture suite at 3 to 4 minutes.
- Audit session: 1 commit (this file), 26 Linear writes, rework 0, about 35 minutes. **Not comparable** to code velocity; do not fold into the baseline.
- Adversarial reviews: 21 findings on the IAN-173 spec, 6 on the `#92` diff, one HIGH each.

## 4. What shipped

- **IAN-156 (#91).** Writing a slice's own fixture used to make the closure fixture red, so a test author here could never reach a RED. Its R-517 review found a HIGH: the toleration also reached `cmd_green`, recording GREEN for an edited hook plus an unhashed fixture. Fixed in B-4.
- **IAN-175 (#92).** R-334 norm line, the Spec in `rulebook/reference.md`, a 144-line fixture, both regenerated ports, the hash manifest, and the slice-lock untracking.
- **IAN-173 spec (#94, draft).** `claude/docs/superpowers/specs/2026-09-20-database-engine-tracks-design.md`, 258 lines, adversarially reviewed and owner-approved, 21 findings dispositioned.
- **R-605 ticket-coverage audit.** 87 commits on `main` since `6bc9b24` (2026-09-17T12:37:01Z). Missing a ticket key by day, total/missing: 09-17 10/10, 09-18 47/28, 09-19 21/2, 09-20 14/5. Of the 40 uncovered, 11 docs-only (exempt by design), 29 code.
- **Backfill IAN-226 to IAN-249:** 24 retroactive tickets, all Done, one per uncovered code commit from 09-18 and 09-20, each carrying SHA, branch, PR, date. Tier and estimate unset: the work predates its ticket, so `actual_minutes` is not attributable and a guess would corrupt R-906 calibration.
- Tickets opened: IAN-165, IAN-172, IAN-176, IAN-177, IAN-184, plus IAN-251 and IAN-252 from the audit. IAN-188 closed.

## 5. Pending (by urgency)

1. **Sync** (2 min): `git pull --ff-only && ./sync.sh` in the primary checkout.
2. **IAN-184** (~90 min): wire `verification-gate.sh` to `expected-red`, fix the `hook-latency.test.sh` flake blocking its RED. Until this lands a test author is still blocked at Stop even though `tdd.sh red` works. Fixture parked (section 2). The flake is real and reproducible (330ms against a 348ms budget standalone), already `# Shard: serial`, IAN-115 closed claiming to have fixed it, and it fires when two suites run at once. Do not widen the budget (R-204).
3. **IAN-172** (~4 hours, high): employer work profile. Safe: the ticket gate and Linear writes disable themselves without `~/.claude/TICKET-TRACKER.json` (gitignored). Open: Codex sending employer code to a personal ChatGPT plan, `settings.json` replaced at SessionStart, and `claude/global-memory/` as 30 tracked files on a public remote with only a `[manual]` rule keeping employer content out.
4. **IAN-173** (~2 hours): database engine-track split. Spec approved, three slices planned, nothing built.
5. **IAN-157** (~3 hours): fired five times, refusing a `tdd.sh close`, two test-author writes, a commit against a branch `git checkout -b` had not created, and a scratchpad write read as production.
6. **IAN-251** (~30-45 min): `pr-ticket-ref-gate.sh` has four allow paths, all bare `exit 0`; `record_fire` runs only from `emit_degraded_warning` and `emit_deny`, so an exemption is never recorded. With `.claude/task-tier.json` untracked, an exemption and a gate that never fired are indistinguishable afterwards. Branch cut, ledger set.
7. **IAN-252** (~40 min): `tdd.sh close` should refuse while the lock path is tracked. Must read git's tracked state, not file existence.
8. Lower: **IAN-176** (20 min; IAN-173 adds two files needing porting), **IAN-177** (15 min), **IAN-165** (45 min).
9. **No ticket yet:** `tdd.sh red` exits 0 when it refuses to certify; the printed verdict is the only truth. Separately, `pr-ticket-ref-gate.test.sh` prints a bare `true` to stdout mid-run (~10 min to trace).

## 6. Next session

1. Run pending item 1 before anything else.
2. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` inside this repository, never `~/.claude/enforce/tdd.sh`: the installed copy can predate the edit under test.
3. A decision recorded in a PR document and not in an assertion is enforced by nothing. Two fixtures passed against code doing the opposite of their document; only an adversarial reviewer caught it. When a document states a bound, write the assertion in the same slice.
4. IAN-173 starts at slice 1 (the invariants-test block), not the files. B-2's line-coverage check reads the pinned pre-split copy `git show 48f3b5c:claude/CLAUDE-DATABASE.md`; pin that sha.
5. IAN-173's HIGH, easy to lose: `paths:` frontmatter globs are what auto-load a convention file; a dispatch table loads nothing. Engine files take disjoint globs and the shared `**/migrations/**`, `**/src/database/**`, `**/src/repositories/**` stay on the base file alone, or every project loads both engines' rules.
6. For IAN-251 read `claude/hooks/pr-ticket-ref-gate.sh` (82-106 `record_fire`, 128-138 the allow paths), then `claude/enforce/tests/pr-ticket-ref-gate.test.sh:126-138`. For the R-605 rule text read `claude/rulebook/reference.md:684-696`; do not re-derive the exemptions from the hook.
7. The audit's initial claim that PRs #84 and #88 violated R-605 was **withdrawn**. The fixture covers the trivial-tier path three ways, so the gate likely exempted them correctly. The evidence is unrecoverable, which is what IAN-251 fixes. The 09-18 gap was already known: `reference.md:692` records a 2026-09-19 audit of about 14 unticketed PRs, fixed by `ticket-at-start-gate` in `6f6ca63` (#78, IAN-149). That is why 09-19 onward is near-clean.
8. Rebase before starting and before merging. `main` moved three times today and handoffs collided here twice.
9. The R-801 engineering-audit signal has fired on every push today: 30 commits on `claude/enforce`, 15 on `claude/hooks` since the 2026-09-18 audit.
