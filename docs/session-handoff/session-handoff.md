# Session Handoff: 2026-09-20, IAN-156 (#91), three tickets opened from questions

## 1. Last commit

- Last commit on `main` from this session: `1770b25` (fix(tdd): let a slice reach its intended RED past manifest drift, IAN-156, #91). This handoff ships in its own trivial PR after it.
- A parallel session merged `#89` (IAN-174) and `#90` on `main` during this one. `#92` (IAN-175) is open and belongs to that session, not this one.

## 2. Production state

- The primary checkout is on `main` at `1770b25`, clean, and `./sync.sh` has run: the live `~/.claude/enforce/tdd.sh` matches `main` byte for byte, and `.sync-source` points at the primary checkout.
- Codex is over quota until 2026-09-21 02:26. Every test author and both R-517 reviews this session ran on the recorded Claude fallback.
- A local branch `park/b3-gate-expected-red-fixture` holds a deliberately red fixture for IAN-184. Do not merge it; it is storage, not work in progress.
- A local branch `docs/capability-assessment` holds `43232f5`, the 2026-09-19 capability assessment, committed and deliberately unpushed. The owner has not decided whether to publish a personal assessment to the public remote (R-106).

## 3. Session metrics

- PRs merged: 1 (#91). IAN-156 closed at 170 attributable minutes against a 120-minute estimate, ratio 1.42, rework 1.
- R-906 recalibration: the standard/llm estimate holds. The overrun came from scope discovery rather than from the tier being wrong, and the p80 (93) would still have been short.
- Tickets opened: IAN-165 (hook language policy), IAN-172 (employer work profile), IAN-184 (gate wiring plus the hook-latency flake). IAN-162 narrowed from 60 to 30 minutes when IAN-156 absorbed its second item.

## 4. What shipped

- **IAN-156 (#91).** `tdd.sh red` now tolerates a failing `hook-hashes-closure.test.sh` when every reverse-closure line names a test file the red command named. Before this, writing a slice's own fixture made the closure fixture red, and `tdd.sh red` refused, so a test author in this repository could never reach a RED at all. The new read-only `tdd.sh expected-red` answers the same question from outside for the R-509 gate. Nothing rewrites the integrity manifest, and `green` tolerates nothing.
- The R-517 review found a high-severity defect: the toleration also reached `cmd_green`, so an edited hook plus an unhashed fixture recorded GREEN during the implementer's turn, which is the opposite of what the PR document recorded as the decision. Slice B-4 fixed it with four fixture directions. The re-review verified the fix by rebuilding the original scenario against both revisions and returned "merge".

## 5. Pending (by urgency)

1. **IAN-184** (about 90 minutes): wire `verification-gate.sh` to `expected-red`, and fix the `hook-latency.test.sh` flake that blocks its RED. Until this lands, a test author still gets blocked at Stop even though `tdd.sh red` now works. The fixture is written and parked; see section 2.
2. **The `hook-latency` flake is back.** It fails inside `tdd.sh`'s suite run and passes standalone, reproducibly, twice each: standalone it measured 330ms against a 348ms budget. It already carries `# Shard: serial`. IAN-115 closed as having fixed this. Do not widen the budget (R-204).
3. **IAN-172** (about 4 hours, high): the employer work profile. The owner expects to join a company soon. Verified safe already: the ticket gate and the personal Linear writes both disable themselves when `~/.claude/TICKET-TRACKER.json` is absent, and that file is gitignored. Still open: Codex sending employer code to a personal ChatGPT plan, `settings.json` being replaced automatically at SessionStart, and `claude/global-memory/` being 30 tracked files on a public remote with only a `[manual]` rule keeping employer content out.
4. **IAN-157** (about 3 hours): fired three times in this one session. It refused a `tdd.sh close` because the command text mentioned a path, refused two of a test author's writes for the same reason, and refused a commit against a branch that `git checkout -b` had not actually created.
5. **IAN-165** (about 45 minutes): write down the hook language policy, so the shell-versus-TypeScript question is answered once rather than re-argued.

## 6. Next session

1. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` inside this repository, never `~/.claude/enforce/tdd.sh`. Three consecutive red attempts failed today because the installed copy predated the edit under test, and `harness-root.sh` does not cover a human typing the installed path.
2. A decision recorded in a PR document and not in an assertion is enforced by nothing. Both fixtures passed against code doing the opposite of what the document said, and only an adversarial reviewer running the scenario caught it. When a document states a bound, write the assertion in the same slice.
3. The R-801 engineering-audit signal has fired on every push today: 30 commits on `claude/enforce` and 15 on `claude/hooks` since the 2026-09-18 audit. It is advisory and accumulating.
