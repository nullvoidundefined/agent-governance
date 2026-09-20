# Session Handoff: 2026-09-20, four sessions: IAN-156, R-334, the R-2xx rules, the IAN-173 spec, the R-605 audit, the IAN-184 gate

Four sessions ran today and all wrote here. This merges them; detail is on each ticket.

## 1. Last commit

- `main` is at `ce44eda`, `docs(readme): rewrite the root README as adoption-facing landing copy (#102)`. Today's merges: `#89` to `#93`, `#95`, `#96`, `#98`, `#102`. This file is `#99` on `docs/handoff-2026-09-20-gate`.
- `./sync.sh` last ran before `#92`, so the live `~/.claude` predates R-334 and `#96`. Run it first.
- Open: `#94` (IAN-173 spec), `#97` (IAN-184, two HIGH), `#100` (IAN-218), `#101` (IAN-254).
- `#100` and `#101` are siblings forked at `7b72052`, not a stack: they share six commits and both rewrite this file. Fold them, or the second conflicts.

## 2. Production state

- **R-334 amended.** Word order fixed (base noun first, aggregate root repeated); the separator follows the engine's case convention, so `trip_legs` and `tripLegs` are the same name. Fixture: `enforce/tests/r334-engine-case-rule-text.test.sh`.
- **`tdd.sh red` tolerates manifest drift** (IAN-156): a failing `hook-hashes-closure.test.sh` no longer blocks a RED when every reverse-closure line names a test file the red command named. `expected-red` answers the same read-only; `green` does not.
- **`.claude/tdd-lock.json` is untracked and gitignored** as of `#92`, verified against a throwaway clone. IAN-188 closed on that evidence.
- **`~/.claude` was rolled back to `main` deliberately** at the gate session's end. **Do not sync from `fix/gate-expected-red` until `#97`'s H-1 and H-2 are fixed**: that build widens R-509, so a phase-`red` turn can end on a failing typecheck, lint or port check.
- The primary checkout sits on `fix/ticket-gate-exemption-telemetry`; check `git branch --show-current` before syncing from it.
- Codex over quota until 2026-09-21 02:26; every test author and R-517 review today ran on the Claude fallback. Codex exits 0 while printing its usage-limit error, so the log is the verdict, never the exit status.
- `hook-latency.test.sh` passed every run, 308ms against 348ms. IAN-183's flake never fired; IAN-184's title still claims it did.
- Storage branches: `park/b3-gate-expected-red-fixture` (superseded), `docs/capability-assessment` at `43232f5` (unpushed, owner's R-106 call), `fix/tdd-red-commit-anchor` (empty).
- No deploy or migration; baseline green (`pr-ticket-ref-gate.test.sh`, 48 directions).

## 3. Session metrics

- PRs merged: 4 code plus four handoffs, 64 paths changed, rework 3, velocity normal.
- IAN-156: 170 actual against 120, ratio 1.42, rework 1; the overrun was scope discovery, not a wrong tier.
- IAN-175: 130 against 60, ratio 2.17, human estimate 45 (human_speedup 0.35), rework 1. Half went to the gate loop, each RED and GREEN running the full fixture suite at 3 to 4 minutes.
- Gate session 71 min (`#97`, 6 files, 548 insertions); audit session 35 min, 26 Linear writes, **not comparable** to code velocity.
- Adversarial reviews: 21 on the IAN-173 spec, 6 on `#92`, 8 on `#96`, 9 on `#97`, 9 on `#98`; a HIGH in each.

## 4. What shipped

- **IAN-156 (#91).** `tdd.sh red` past manifest drift, so a test author here can reach a RED.
- **IAN-175 (#92).** The R-334 norm line and Spec, a 144-line fixture, both ports, the lock untracking.
- **R-212, R-213, R-214 (#96).** Scope declaration, provenance tags, findings-to-ticket, each with an enforcer, fixture and manifest row. Also fixed the `chmod 000` fixture that asserted nothing as uid 0, which had made `tdd.sh red` unusable in cloud containers. Deferred: IAN-224, IAN-225.
- **IAN-173 spec (#94, draft).** `claude/docs/superpowers/specs/2026-09-20-database-engine-tracks-design.md`, 258 lines, 21 findings dispositioned.
- **IAN-184 B-3a and B-3b (#97, draft).** The gate asks `expected-red` after a check fails and releases on exit 0, failing closed; B-3a made `expected-red` require a locked test to still be failing, closing Finding 3 of the `#91` review. Nothing reached `main`.
- **R-605 audit (#98).** 86 commits since `6bc9b24`, 40 uncovered; by day 09-17 4/4, 09-18 47/28, 09-19 21/2, 09-20 14/6. The docs-versus-code split reproduces under no definition tried, so it and the IAN-226 to IAN-249 backfill are unverified. IAN-258 carries both, and the backfilled tickets have no tier or estimate, so R-906 is unaffected.
- **Withdrawn:** the claim that `#84` and `#88` violated R-605. The fixture covers the trivial-tier path three ways, so the gate most likely exempted them correctly and the evidence is gone either way; IAN-251 fixes that. The 09-18 gap was already known and fixed: `reference.md` records a 2026-09-19 audit of about 14 unticketed PRs, closed by `ticket-at-start-gate` in `6f6ca63` (`#78`, IAN-149), which is why 09-19 onward is near-clean. Do not re-open either.
- Tickets opened: IAN-165, IAN-172, IAN-176, IAN-177, IAN-184, IAN-218, IAN-220, IAN-250, IAN-251, IAN-252, IAN-254, IAN-258. IAN-188 closed.

## 5. Pending (by urgency)

1. **Sync** (2 min): `git pull --ff-only && ./sync.sh` in the primary checkout.
2. **`#97`'s two HIGH findings** (60 to 90 min). The IAN-184 comment of 16:5xZ carries both verbatim with evidence and the intended fixes. H-1: `is_expected_red` never reads which check failed. H-2: `exit 0` in the checks loop skips the rest. M-1 to M-3 are on the same comment and are also owed fixes. `#97` also needs its `## Codex review` section.
3. **IAN-220** (120 min): `tdd.sh green` cannot anchor its hash check to a git object because the lock is gitignored, and `fix-commit-requires-test.sh` denies every bug-fix slice's implementation commit. Both need the primitive "the locked tests are committed at HEAD".
4. **IAN-172** (4 hours, high): the employer work profile. Open: Codex sending employer code to a personal ChatGPT plan, `settings.json` replaced at SessionStart, and `claude/global-memory/` public with only a `[manual]` rule holding employer content out.
5. **IAN-173** (2 hours): the database engine-track split. Spec approved, three slices planned, nothing built.
6. **IAN-157** (3 hours): `protected-path-guard` fired nine times on paths nobody was writing.
7. **IAN-258** (60 min): re-derive the R-605 audit figures and reconcile the backfill.
8. **IAN-250** (60 min): rewrite the criticism audit as a senior engineer challenging a junior's assumptions; its closing section argues for self-blame against the brief.
9. **IAN-251** (30 to 45 min): the four allow paths in `pr-ticket-ref-gate.sh` are bare `exit 0`, so an exemption is never recorded and later reads like a gate that never fired.
10. **IAN-252** (40 min): `tdd.sh close` should refuse while the lock path is tracked, reading git's state rather than file existence.
11. Lower: **IAN-253** (no rebase or merge commits here, so R-512's bundle exception is dead), **IAN-176** (20 min), **IAN-177** (15 min), **IAN-165** (45 min).
12. **No ticket yet:** `tdd.sh red` exits 0 when it refuses to certify, so the printed verdict is the only truth. `pr-ticket-ref-gate.test.sh` prints a bare `true` mid-run. `#100` and `#101` have no `docs/prs/` document.

## 6. Next session

1. Run pending item 1 first, and rebase before starting and before merging: `main` moved eight times today and handoffs collided here three times.
2. Read the IAN-184 thread before touching `#97`, and fix `#97` before syncing it anywhere.
3. Invoke `tdd.sh` as `bash claude/enforce/tdd.sh` here: the installed copy can predate the edit.
4. A decision in a PR document and not in an assertion is enforced by nothing. When a document states a bound, write the assertion in the same slice.
5. The hash manifest's `--update` writes to `$HOME/.claude` unless `CLAUDE_INTEGRITY_ROOT=<checkout>/claude` is set. `protected-path-guard` reads shell text, not resolved paths: use the **Write tool** over a Bash heredoc.
5. Order work by dependency, not as the user listed it: the gate session opened IAN-220 first, then found every slice depends on the `test-author` subagent IAN-184 unblocks.
7. Cite `reference.md` by rule ID, never by line range: `#96` moved R-605 from 684 to 722 and the prior citation was stale within hours.
