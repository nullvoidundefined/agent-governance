# B. Independent review and security review: findings for the recovery proposal

Scope: read-only. Sources: /home/user/ag-main (main at afa13a6, post-IAN-568 baseline), /home/user/agent-governance (branches, PR #183 artefact), predecessor repo (history ends 2026-09-12, no review controls beyond Copilot R-516/R-517-old).
Paths below are relative to /home/user/ag-main unless noted. "pre" = 676f39b~1 (the commit before IAN-568, 2026-10-02).

## 0. Headline findings

1. The review PRACTICE has the only recorded real-defect catches in the whole harness (proposal line 11: R-109 on sync.sh, R-517 on voyager PR #16 unscrubbed PII, R-401). The MECHANISM that polices the practice (git-workflow-guard.sh, 1,535 lines, 16 fixtures, 5,671 fixture lines) has no recorded catch and is itself the most review-churned file in the repo.
2. Nearly every HIGH the security review ever caught is in the harness's own gate code (agent-governance reviewing agent-governance). 10 HIGH across 7 artefacts: PR-169 (tdd.sh baseline hid a deleted fixture), PR-172 (hex-named branch resolved as the review head), PR-180 (code file renamed into docs/ read as docs-only; SIGPIPE 141 answered "skip"), PR-182 x3 (case-insensitive launcher denylist bypass; session-written formatter decides green), PR-184 x2. The only product-code catch on record is voyager #16 (PII), which is not in these repos and was found by R-517, not R-109. So the value is real but concentrated in gate-on-gate recursion; it is weak evidence for a general "run security review round after round" rule on ordinary product code.
3. The loop engine is structural, not accidental. Three coupled rules generate unbounded rounds: (a) R-109 requires a test feeding every touched control its insecure value, and the review prompt makes a missing such test a MEDIUM (security-review-prompt.md step 4), so every fix that adds a control (a lock, a validator, a denylist) creates a new MEDIUM "no insecure-value test" row; (b) the R-109 artefact range must end at the PR head with no fixed-sha tail (git-workflow-guard.sh:593-598, "R-109 passes 0"), so ANY commit after the review, including a LOW fix, forces another full round; (c) "a security finding of any severity, LOW included, is never ticketed: fixed, with a further round allowed, or waived by the owner" (reference.md R-517 Rounds bullet). Together: LOW fix -> head moves -> new round -> new LOW on the fix -> repeat. The "stops at the first round that finds nothing above LOW" clause (R-109 Budget exception) is defeated because the stop requires a round whose range ends at head with zero findings above LOW, and every LOW fix moves the head.
4. The detector is the front door to all of it and it is a substring grep. On main, 103 of 553 tracked non-docs non-.md files match a path pattern (security 34, cors 25, session 17, cookie 9, auth 4, ...); content patterns include `rate[-_]?limit` which fired on Claude Code's `rate_limits` status field (PR #183) and `CORS` in a test fixture (PR #161). Unmerged branch fix/security-surface-skip-tests (PR #171) tried to exempt five lines of `# Shard:` fixture metadata and took 15 commits, 551 lines and 4 security rounds, and never merged: fixing the detector's false positive is itself security-surface work.

## 1. Control by control

### R-517: one fresh-context pre-merge review
1. Required / enforced.
   - Strongest point (pre, claude/CLAUDE.md:115 at 676f39b~1): fresh-context reviewer (pr-reviewer on sonnet, diff pasted), run after bookkeeping commits, at most two rounds, LOW after round 2 ticketed, section `## Codex review` with reviewer/model/range lines, range head must equal PR head (docs-only tail exempt since #172), exactly one section, trivial-tier exemption read from an untracked ledger. Gate: hooks/git-workflow-guard.sh read_codex_review_verdict at :1442-1444 (deny on merge). Rounds were manual ("the merge gate does not yet parse review rounds", reference.md R-517 Rounds).
   - Origin (afaea90, 2026-09-19, PR #71): Codex reviews every PR, blocking, alongside Copilot. Reversed to a Claude subagent in 4.6 days (docs/audits/2026-09-26-process-and-rules.md:103-106: 5 revisions in 5 days, #71 -> #119, #121, #128, #130).
   - Main: CLAUDE.md:22 (one line), reference.md R-517 (about 9 KB of spec text), gate unchanged in kind but with the I6 tail (git-workflow-guard.sh is_reviewed_tail, :585-610): range may end at an ancestor if every later commit is a clean base merge or named `fixed <sha>` in the findings table. Still manual: round count, severity handling, LOW ticketing.
2. IAN-568 change: two-round cap became "one round, second only when round one finds a HIGH"; fixes are ordinary commits with a test (no TDD slice); LOW after the last round becomes a ticket; I6 lets fix commits merge without re-review; section grammar moved into task-cleanup skill; short PR-body template for standard risk (task-cleanup/SKILL.md).
3. Value (concrete).
   - voyager PR #16: unscrubbed-PII HIGH caught by the pre-merge review (proposal :11; the artefact is not in these repos).
   - PR #183 (docs via commit messages, afa13a6): R-517 r1 rows 1-6: two MEDIUM "test cannot fail" (reset-sooner case never reached projected days < 1; offset case could not see a wrongly opened window), three LOW (explicit stale flag; empty buckets file silently reported nothing; no writer lock), one portability (GNU-only `date -d`). R-517 second review on 676f39b..9c0add6: MEDIUM real correctness bug (a provider's paceRatio skipped a current bucket whose ratio was null, so a 100%-used bucket hid behind a healthy sibling), MEDIUM untested trailing-burn pairing and clamp. That bug survived six R-109 rounds; the security reviewer's scope (controls and insecure inputs) does not read for acceptance or business-logic correctness. This is the clearest evidence that the general reviewer and the security reviewer find different things and neither substitutes.
   - PR #160: R-517 found the Semgrep step failing closed on the PR head because `site/` export-ignore kept a target out of git archive, after four R-109 rounds had passed (PR-160 artefact note).
   - PR #71 itself: the first R-517 gate shipped with merge-matcher and fence bypasses found by the review (multi-merge command, `--repo` before subcommand, fenced heading) and by Copilot; hardened in follow-up commits inside the same PR.
4. Pathology.
   - Cost per review: 55k-135k tokens, 1-25 min (reference.md R-517 Reviewer bullet, measured 2026-09-24). Section grammar alone is about 1.1 KB of norm text; the 2026-09-26 audit counted R-517 as 27% of norm-line bytes with seven other rules.
   - Rule churn: 5 revisions in 5 days; the gate was re-edited for docs-only tails (#172, five review rounds, 9 findings incl. 2 HIGH on the exemption itself) then again for I6 (#182).
   - Gate telemetry noise: 8,663 R-517 denials, 99% fixture-test bursts; voyager real count 1 (proposal :13).
   - Section theatre: heading still `Codex review` though the reviewer is Sonnet (audit 2026-09-26:219-227 proposed renaming; not done).
   - Ordering trap: a review is invalidated by any later commit (Timing bullet), so bookkeeping and docs are forced before the review; IAN-568 I6 relaxed this but only for base merges and `fixed <sha>` rows.
5. Classification: practice KEEP; mechanism MODIFY. Keep one fresh-context review on every non-trivial PR (it is the only control with a non-security product catch). Shrink the mechanism to: a section exists with a head-covering or I6-tail range. Drop the exactly-one-section, trivial-ledger and fence-parsing machinery only if trivial tier is removed (see other topic files); otherwise leave. Do not REINSTATE the Codex cross-model requirement: it cost 4.6 days of churn, 60-86k Codex tokens per call on a $20 plan, and no catch is recorded that a cross-model reviewer found and a Sonnet reviewer would not have.

### R-109: security review on the strongest model, rounds continue while MEDIUM+
1. Required / enforced.
   - Strongest point (pre, same as main for this rule): clean Semgrep pack (hooks/push-semgrep-gate.sh fail-closed, CI security.yml), detector (hooks/security-surface.sh, 395 lines) decides if the range touches a control, `## Security review` section by security-reviewer subagent on `securityReviewModel` (enforce/security-review-model.json), range head == PR head, `artefact` line naming a committed JSON bound by a shared ledger (enforce/security-review-record.sh, hooks/security-review-ledger-path.sh), `--match-head-commit`, findings table parsed (open row denies; `fixed <sha>` must be in range; `waived by owner <date>` turns the merge into an ask). Gate at git-workflow-guard.sh :1088-1100 (verdict) and :1445-1452 (deny/ask). Fail closed on missing detector/Semgrep/unparseable file.
   - Introduced: PRs #141-#145 (2026-09-25/26), IAN-381.
   - Main: CLAUDE.md:12; reference.md R-109 adds the Budget exception (owner decision 2026-10-02: the only step allowed past 1:1, rounds continue while each round finds MEDIUM+) and I7 (docs/ and .md paths skip the PATH patterns; content patterns still apply).
2. IAN-568 change: I7 detector fix (security-surface.sh +19 lines); added the budget exception; kept the artefact/ledger machinery and strict head-range (explicitly refused the `fixed <sha>` tail for R-109, R-109 r1 #3 on PR #182 because the cell is self-attested in a mutable PR body). Net effect: R-109 became MORE unbounded by decision (explicit "round after round") while everything else was cut.
3. Value (concrete). Artefacts under docs/security-reviews/ (16) plus docs/audits/2026-10-03-ian605-...json:
   - PR #159 (sync.sh release-file validation): seven rounds, 15 findings, one real hole per later round (path escape); cited in the proposal as the value case (:286). One finding (GitHub Pages without frame-ancestors/nosniff) waived.
   - PR #161: MEDIUM option-shaped PR base ref (`--upload-pack=<command>`) reached `git fetch` as an option and ran a command: a genuine command-injection class bug in a gate helper.
   - PR #172: HIGH hex-named branch/tag resolved before the object name so any commit passed as the review head; HIGH refs/replace could hide a security surface. PR #180: HIGH renamed code file in docs/ skipped required suites; HIGH SIGPIPE under pipefail answered "skip" on lists over 64 KiB. PR #169: HIGH deleted RED-passing fixture masked by a count-only baseline. PR #182: three HIGH in the formatter/lock tolerance verdict.
   - PR #158 IAN-480: three MEDIUM, one of them "no test fed the shipped list its insecure value", which prevented a later silent widening back to docs/**.
4. Pathology (numbers).
   - Rounds across the 17 PRs with artefacts: 69 rounds (154: 12, 159: 7, 183: 7, 182: 6, 160: 5, 172: 5, 184: 8, 158: 4, others 1-3).
   - Findings by severity where tabulated: 10 HIGH, 32 MEDIUM, majority LOW; at least 4 artefacts (157, 162, 176, 178) were pure detector false positives with zero findings but still paid the full review plus artefact plus ledger plus a PR-body section; 163, 161, 169 and 183 were triggered by a hooks path, a CORS string in a fixture, fixture header paths, and the `rate_limits` field respectively.
   - PR #183 (afa13a6): a quota pace calculator estimated at about 450 lines grew to about 1,100 (slice plan docs/slices/slice-04-quota-aware-routing.md:53). 34 findings over 7 rounds (10 MEDIUM, 24 LOW). The writer lock that dominates rounds 2-7 was ADDED by an R-517 round-1 fix for a LOW finding ("record needs a writer lock"); of 34 findings, 18 concern that lock or its liveness and about 10 more are local-CLI input hardening (relative HOME, +99:99 offsets, symlinked quota file, hidepid /proc, QUOTA_PROC_MOUNTS naming no /proc mount). Rounds 6 and 7 found only LOWs yet round 7 ran because round 6's LOW fixes moved the head. Two LOWs were finally waived by the owner (ids 29, 30). The owner called it yak shaving. The artefact note itself lists four post-artefact commits that only made the fixture portable to macOS and each needed the artefact commit re-appended.
   - PR #184 (IAN-605, post-IAN-568): 8 rounds, 16 findings, rounds 4-8 each found one LOW (rows 13-16), contradicting the "stops at the first round that finds nothing above LOW" text; round 7 was killed by the new watchdog after a 10-minute stall; owner finally chose to remove the tool-name check altogether, which closed six rows.
   - PR #154: 12 rounds; PR #182 (the pruning PR): 6 rounds on its own gate changes, including a denylist of launchers that kept growing (go, bundle, pipenv; case variants), which is exactly the fuzzy-control pattern R-110 says needs an owner-stated acceptance boundary first.
   - PR #171 (unmerged): detector false-positive fix, 15 commits, 551 lines, 4 rounds.
   - Review-added code: round-1 R-517 fix (lock) spawned 5 R-109 rounds; PR #172's own `docs-only tail` feature spawned 9 findings; I6 (#182) mutated the same gate again.
   - Missing-test MEDIUMs are a loop generator (ids 7, 8, 10, 27 on #183; #172 rows 4, 7; #182 "no fixture fed the allowlist its insecure values"): they recur because each new control needs its own insecure-value test and a reviewer is told to flag its absence.
   - Detector cost: 1,535-line gate + 395-line detector + 16 fixtures (5,671 lines); hook-hashes churn on every edit.
5. Classification: practice KEEP for real trust-boundary controls (auth, sessions, cookies, CORS/CSP, SQL construction, secrets, redaction, path/command construction from input); MODIFY the stopping rule and the scope; the mechanism (gate, artefact JSON, shared ledger, `--match-head-commit`) MODIFY: keep the fail-closed "no merge without a covering review", retire the self-referential tail restrictions that force re-review of LOW fixes. Do NOT REINSTATE anything from before IAN-568; the budget exception is the regression, not the cut.

### R-514: owner reads and merges security-touching and guarded PRs
1. Required: owner merges security-touching (detector hit) and build-lane guarded ranges; others per slice plan merge mode (green by default since #173, 2026-10-01 after being owner-merge by default #132 2026-09-24, and merge-on-green before that: 11 h 20 m reversal, audit 2026-09-26:104). Enforced: gh pr merge always `ask` via git-workflow-guard.sh :1453 (R-514), main push ask :1489. Owner-merge itself is manual; the hook cannot tell who is merging.
2. IAN-568: kept M on security/guarded ranges, D otherwise; proposal stats: 242 real asks, rationale "exists for understanding, not correctness".
3. Value: no recorded defect catch. Its recorded value is comprehension (owner's own reading) and a single waiver channel for R-109 (waived rows turn into an ask).
4. Pathology: any detector false positive (handoffs, hooks paths, rate_limits) also forces owner-merge, so false positives cost the owner's time as well as agent rounds. Merge-mode asked per slice adds a tile.
5. KEEP the practice for genuine security controls; MODIFY so that owner-merge is triggered only by a detector "strong" hit (content/semgrep/known-control path), and a path-only hit yields an advisory. Keep the per-merge confirmation (it is the one thing the owner uses as the waiver and the destructive-action stop).

### R-110: risk tiers as they pick review
1. Required: classify each slice high/standard (security, money, concurrency; default high when unsure), record `**Risk:**` in the slice plan; high -> TDD lock + test-author/implementer/slice-critic triad; standard -> lean tier, one sonnet review (reference.md R-110). Enforcement: manual; detector does not read the Risk line, no merge-time check that a high slice ran the triad (stated as deferred, reference.md R-110 Deferred).
2. IAN-568: standard-risk dropped the TDD lock; fuzzy-control owner tile kept; measurement fields (`risk`, `findings_by_round`, `escaped_bugs`) kept but optional at close (R-606 six fields).
3. Value: the fuzzy-control rule is the one place the harness names why rounds don't end ("a control with no stated boundary gives every round a new finding", reference.md R-110). PR #16 reflection: rounds 3+ produced only LOW; a regex PII scrubber went through four critic rounds before anyone asked for its threat model (PROTOCOL.md:336-338). No data on escaped bugs yet: report risk needs ten PRs.
4. Pathology: "default high when unsure" plus detector union means R-110 high-risk catches everything the detector flags (incl. false positives) and sends it to the heaviest lane. PR #183 was high-risk because of the word `rate_limits`.
5. KEEP the tiering idea (it is how cost scales with risk); MODIFY: make the threat-model tile the gate for rounds (see 3 below) and make the risk line, not the filename, drive detector escalation.

### Spec-conformance review (agent)
1. Required: dispatch after implementing against an approved spec; reports only gaps vs named requirements; stops without a spec path (agents/spec-conformance-review.md, opus). Not enforced by any hook (agents.md "Review agents"). Spec review at task-start by Codex is a different control (codex-spec-review-prompt.md).
2. IAN-568: untouched; R-517 reviewer reads "the spec and acceptance criteria" so the two overlap.
3. Value: no recorded catch in docs/ (searched session-handoff, slices, tickets, prs, audits).
4. Pathology: opus on every Complex PR; duplicates R-517 item 1 and 6 (UNMET CRITERIA, SPEC DRIFT) in the pr-reviewer prompt; precedence text in agents.md exists to explain which of four reviewers (code-review, gof, spec-conformance, pr-reviewer) runs.
5. RETIRE as a separate required step. Fold acceptance-criteria conformance into the single pr-reviewer prompt (already items 1 and 6). Keep the agent file as an on-request tool (cost: 5 KB, no mechanism).

### slice-critic (per-slice fresh review, high-risk only)
1. Required: seven fixed questions after each green high-risk slice; opus; read-only (agents/slice-critic.md; R-412/R-707). Enforced: role-policy.json write boundaries only; the dispatch is manual.
2. IAN-568: high-risk only (already narrowed by IAN-521 on 2026-10-01 from every Complex slice); kept.
3. Value: PROTOCOL.md:336-340 states "per-slice critic rounds there have no recorded catch" for PR #16; proposal :286 repeats it. No other recorded catch.
4. Pathology: 4 critic rounds on one PII regex (PR #16); each round is opus; ordering with R-517 and R-109 makes three independent reviews of the same code on a high-risk slice (critic per slice, R-517 per PR, R-109 per PR).
5. RETIRE as a mandatory per-slice step; MODIFY into an optional check run once per high-risk PR before R-517 (or fold its seven questions into the R-517 prompt: items 2, 4, 6, 7 are already weak-test/failure-mode/state questions). If the owner wants the triad's independence for money/concurrency, keep test-author separation (not slice-critic) because the independence that has catches is "tests written by a different context", and that is covered by R-401 and the R-517 weak-test item.

### Codex / cross-model review
1. Required (afaea90): every PR reviewed by Codex, with Claude fable/opus fallback; spec review by Codex for Complex/Saga; Codex authors tests. Enforced: gate checks the section only; `reviewer` and `model` lines are free text.
2. IAN-568/IAN-521/IAN-333: default became Sonnet pr-reviewer; Codex only on owner opt-in; R-907 (test-author separation hook) deleted (421 asks, no catch); R-908 metered-Codex warning kept.
3. Value: Copilot (predecessor) caught the CORS `*` in template-fastapi-nuxt #27 that every Claude reviewer passed (R-109 incident text); that is the only recorded cross-model catch and it motivated R-109 rather than R-517. Codex found real parity/criteria/security gaps in a template spec on 2026-09-19 (codex-spec-review-prompt.md purpose). In PR #171, "Codex R-517 round 3 showed diff parsing could still be misled", but the same class was being found by the Claude R-109 rounds.
4. Pathology: $20 plan, one unfocused spec review hit the usage limit; each call 60-86k Codex tokens; section is still titled Codex review.
5. RETIRE as a requirement (already so); KEEP as an owner opt-in, and as the router's cross-provider reviewer when quota allows (slice-04 plan). Rename section to `## Review` with the gate accepting both (audit 2026-09-26 recommendation, never done).

### Round caps ("second round only when round one finds a HIGH")
1. Required: reference.md R-517 Rounds bullet, build-by-slice, task-cleanup, build-fast step 9. Manual. The prompt carries `<ROUND: r1|r2>`.
2. IAN-568 replaced the earlier two-round cap with "second only on HIGH".
3. Value: untested; evidence for the cap is the PR #16 reflection (rounds 3+ only LOWs). Evidence against cap on a MEDIUM: PR #183's R-517 second review found a real MEDIUM masking bug.
4. Pathology: the cap is not mechanical and applies only to R-517; R-109 has the opposite rule. In practice PR #183 ran 2 R-517 rounds with no HIGH in round 1 and 7 R-109 rounds.
5. KEEP the principle; MODIFY into the explicit stopping rules in section 2.

### Security-surface detector and false positives
1. Required/enforced: hooks/security-surface.sh + enforce/security-surface.json: path regexes (unanchored substrings: cors csrf csp auth session cookie crypto password token security permission policy middleware workflows Dockerfile .enforce.json .gitattributes .semgrepignore), content regexes (CORSMiddleware, cors\(, set_cookie, SameSite, jwt, hashlib, verify=, helmet\(, rate[-_]?limit|throttl|limiter, rejectUnauthorized, csrf, ...), Semgrep rule pack; fail closed when semgrep missing or unparseable (README-only PR #157 reviewed for that reason). `securitySurfaceExclude` in .enforce.json.
2. IAN-568: I7 only: skip PATH patterns for docs/ and *.md.
3. Value: found the one detector true positive class that matters: it forced review on the gate-hardening PRs where HIGHs were found (#172, #180, #182).
4. False positives recorded: handoff path `session` (IAN-541, PR #162, #178), claude/hooks/session-start.sh (PR #176), README (#157 semgrep missing), fixture `# Shard:` header lines (#169, #171), CORS string in a fixture (#161), hooks path (#163), `rate_limits` (#183). On main today 103 of 553 non-docs files match a path pattern (session: 17, security: 34, cors: 25) and a typical fixture or test file for any of these is flagged.
5. MODIFY: split detector output into strong (a content or Semgrep hit on an added/removed line in non-test, non-fixture code; or a path in a short explicit control list) and weak (path-substring only, or a hit in tests/fixtures/docs). Weak -> one pass, no artefact JSON, no ledger, no rounds; the PR body line `Security review: weak hit, reviewed in R-517` suffices. Anchor patterns: `(^|/)(auth|session|cookie|cors|csp)[^/]*\.(py|ts|js|go|rb)$` rather than substring; `rate_limit` only inside `limit(` or middleware/config contexts; tests and fixtures excluded because the Semgrep pack and CI still read them. Add `.enforce.json` `securitySurfaceExclude` for known harness-own paths (hooks/session-*.sh, rate_limits status field). The detector must never be the subject of a multi-round review: a change to security-surface.* patterns is reviewed in one round with the false-positive corpus (the 16 artefacts above) as its fixture.

### build-by-slice-require-review and build-fast
1. build-by-slice: Gate 1 (plan with Risk and Merge mode lines, one owner tile per fuzzy control), build, one pre-merge review, merge per mode. Enforcement: none except spec-glossary-check reminder and the merge guard. build-fast: Haiku builds, strongest model reviews once in parallel with CI, lane predicted by build-lane.sh (fast/guarded; guarded -> owner merge), one fix round, "stop and hand to owner" conditions (step 10).
2. IAN-568: build-by-slice shrank by about 100 lines to the lean tier (one review round; second only on HIGH; short PR template); build-fast edited (+16/-?) and `build-lane.sh` now predicts docs and Markdown as fast.
3. Value: build-fast has the best-shaped stopping rule in the repo (step 9-10: one fix round; a new finding in round 2 stops the run and hands to the owner; no hunting; "no yak-shaving" hard rule 3). No recorded catch attributable.
4. Pathology: build-fast says the R-517 reviewer runs on securityReviewModel while R-517 elsewhere says sonnet for all; the two can disagree on one PR. The skills restate R-517 round text in 4 places (reference.md, CLAUDE.md, task-cleanup, build-by-slice, build-fast, codex-pr-review-prompt.md header) which is where drift enters.
5. KEEP both skills; MODIFY: make build-fast's stop condition ("second review round raises a new finding -> stop, owner decides") the common rule for all PRs, and state the round text once.

## 2. Proposed bounded-review rules

### 2.1 Independent review (R-517 replacement text, same gate)
- Round 1: one fresh pr-reviewer (sonnet) over merge-base..head at dispatch time, with diff and requirements pasted. Time-box: reviewer is told to stop after the pasted diff is read once; max 10 findings, ranked.
- Findings are graded:
  - HIGH: shipped bug, data loss, security hole, acceptance criterion unmet in a way the user would see. Blocks. Fix with a test.
  - MEDIUM: test that cannot fail for a claimed criterion; missing failure handling on an external boundary; wrong edge-case behavior with a concrete input. Blocks, but may be answered with a reason or a ticket if the owner-approved scope excludes it.
  - LOW: everything else. Never fixed by a further round, never re-reviewed; the author fixes it in the same commit stream if it takes under 5 minutes, otherwise tickets it. LOWs are never grounds for another review.
- Second review round is allowed only when a trigger fires:
  1. Round 1 found a HIGH. Round 2 reviews ONLY the fix commits for HIGH rows plus the findings table ("delta review": did each HIGH fix land, does it have a test, did the fix diff add a new defect). It does not re-read the PR.
  2. The fix commits for HIGH and MEDIUM rows add more than max(100 lines, 25% of the original diff) of production code (new surface): delta review of that fix diff only.
  3. The author adds a new file, endpoint, dependency, migration, or control after round 1 that was not in the reviewed range. Treated as a new PR slice: new round 1 on that slice, not a re-review.
- No third round, ever, in either direction. A finding still HIGH after round 2 goes to the owner as an explicit decision (fix with their direction, waive, or split the PR). This is the same as build-fast step 10: "the second review round raises a new finding -> stop".
- Findings on code added by an earlier review fix are out of scope in round 2 unless the code is itself a HIGH/MEDIUM-row fix.
- Merge gate (mechanical part): section exists, range head is the PR head or the I6 tail; findings table has no `open` HIGH/MEDIUM. Round counting stays manual, but record `findings_by_round` at ticket close as already specified so the stopping rule can be checked (report risk after ten PRs).

### 2.2 Security review stopping rule that cannot restart unrelated stages
Principles: freeze the scope in round 1; separate "found" from "must re-review"; never let LOW fixes change the gate state; keep the security review a stage with its own ledger that nothing else invalidates.
1. Scope freeze. Round 1 (security-reviewer, strongest model) enumerates the controls in range (prompt Procedure step 1) and writes the control list into the artefact JSON as `controls: [file:line, ...]`. Only these controls and the fix hunks of HIGH/CRITICAL/MEDIUM rows are ever in scope for later rounds. A finding about a control that was not in the round-1 list, or about code added by a fix to a LOW row, is recorded as a ticket (never blocks) unless it is CRITICAL/HIGH, which reopens that one control.
2. Round budget. Round 1 full. Round 2 only if round 1 had a CRITICAL/HIGH or a MEDIUM the author is fixing in code (not by test or ticket); round 2 reviews fix diff + the controls named in those rows. Round 3 only for a CRITICAL/HIGH still open after round 2. Hard stop at 3: after that, owner decision (waive with `waived by owner`, accept, or split). Today's 7-, 8- and 12-round reviews would have stopped at round 2 or 3 and ended with owner decisions on the remaining rows. Exceeding 3 rounds needs the owner's explicit yes in the current turn, via the merge-gate ask.
3. Severity discipline that stops the generators.
   - A missing insecure-value test is a MEDIUM once per control, and only for a control added or changed in the PR. A pre-existing control with no test is a ticket. The fix that adds a new control (lock, validator) is not itself reviewed for missing tests in round N+1; its test is part of its commit and CI checks it.
   - Severity is capped by the owner's threat model tile (R-110 fuzzy controls tile or, for a local CLI, a one-line trust statement in the slice plan): if the only input source is the owner's own environment, config file or CLI, the finding ceiling is LOW. This replaces prompt step 5 ("never grade a finding down because configuration is trusted") for local-only tools; it stays for network-facing settings (CORS, cookies, headers), where the incident (template #27) motivated it.
   - Concurrency, liveness and portability findings on a non-security tool are R-517 findings (correctness), not R-109.
4. LOW security findings: fix in place or record as `ticketed-low` in the artefact; neither triggers a round. The owner reads the list at the R-514 merge, which is the existing waiver channel. This changes "never ticketed" (reference.md R-517 Rounds) and is an owner decision; the evidence is #183 (24 LOW of 34 findings, 5 of the 7 rounds on LOW follow-ups) and #184 (rounds 4-8 on one LOW each).
5. Stage independence (the mechanism change).
   - Order: R-517 first on the finished code; R-109 second on the R-517-fixed head. A R-517 fix commit after R-109 is allowed only if its diff touches no file named in the artefact `controls` list and no security-surface hit (checked by the same detector on the tail diff). In #183 the R-517 round-2 ratio fix would have been inside the tail test and would not have forced round 7.
   - Tail rule for R-109 (replaces "no tail except base merges"): a commit after the reviewed commit is accepted when it is a clean base merge, OR docs/tests-only, OR the detector run over the tail diff alone returns no strong hit and no control in the frozen list is touched. Rationale: the self-attested `fixed <sha>` concern (PR #182 r1 #3) is addressed by a mechanical check on the tail diff, not by a table cell. The artefact stays hash-bound to the reviewed commit through the shared ledger as today.
   - Security artefact commit, ledger entry and PR-body section are written once, at the end of the last round, not per round. Intermediate rounds produce prompt/response files in the scratchpad only (cuts the "this artefact commit follows..." note chains seen in PR-183).
   - Docs/handoff/PR-body changes never invalidate the security review (already true for the body; extend to docs/ via I7).
   - A security finding never reopens R-517, CI, the TDD lock, ticket or handoff stages; it only appends commits.
6. Detector changes ride one round only (section 1 detector item 5).
7. Budget exception text (CLAUDE.md:7, R-109): replace "round after round while each round still finds a MEDIUM or higher" with "up to three rounds, each limited to the frozen control list and the prior round's fix hunks; further rounds need the owner's yes."

### 2.3 What the reviewer prompt must focus on
Order by likelihood of a real catch in this repo's history:
1. Correctness and edge cases of the changed behavior (the #183 masked-bucket bug; the #172 hex-branch resolution): trace inputs through changed lines, boundary and null/empty values.
2. Acceptance conformance: each criterion the PR claims, mapped to a test that would fail if the behavior were missing.
3. Weak or misleading tests: assertion that cannot fail; mocks that hide behavior; test that passes without the change (the #183 rows 1-2 and PR-158 and PR-172 missing insecure-value tests).
4. Failure handling at external boundaries: timeouts, partial failure, swallowed errors, retries, idempotency.
5. Regression risk: callers outside the hunks, changed return shapes, changed defaults.
6. Stack and convention violations: only the sections cited by the touched files.
7. Abstractions: layer bypass, duplicate helper, new dependency not in spec (items 5 of slice-critic), at most two findings.
8. Security: authn/authz, injection, secrets, PII, weakened protection (CORS/CSP/rate limits); a security-touching PR also gets the R-109 review.
The prompt (prompts/codex-pr-review-prompt.md) already carries items 1-6 in a different order; reorder and add regression risk and failure handling explicitly.

### 2.4 What it must not do
- No style, naming, wording or formatting comments; no suggestions that add scope or "defense in depth" beyond stated acceptance criteria and the owner's threat-model answers.
- No findings on code outside the pasted diff (except callers read to answer a specific question), and none on previous review fixes in a later round unless the fix is wrong for the row it closes.
- No re-grading earlier dispositions or reopening a finding the author answered with a reason.
- No more than 10 findings; no LOW findings in a final round; no "missing test" finding for a control the PR did not add or change.
- No manufactured findings: if nothing is found, say "No findings" with areas checked (already in prompt output format and slice-critic).
- No hardening of local-only inputs the owner supplies (relative HOME, symlinked quota file, hidepid /proc, `QUOTA_PROC_MOUNTS`) when the threat model names the owner as the only input source.
- No grading by "could be exploited if" chains that need a second precondition not in the PR; HIGH needs a concrete input.
- No tool use beyond the pasted diff unless a named question needs it (keeps tokens at the 55-90k measured).

## 3. Summary classification

| Control | Practice | Mechanism |
|---|---|---|
| R-517 pre-merge review | KEEP | MODIFY (section exists + I6 tail; rename section; drop single-section/fence parsing once trivial tier is settled elsewhere) |
| R-109 security review | KEEP (real controls only) | MODIFY (frozen scope, 3-round cap, LOW fixes never restart; tail rule by detector, not by cell) |
| R-514 owner merge | KEEP for strong-detector and guarded ranges | KEEP the per-merge ask; MODIFY trigger to strong hits |
| R-110 risk tiers | KEEP | MODIFY (threat-model tile caps severity and rounds; risk line drives escalation) |
| spec-conformance-review | RETIRE as required step | fold into R-517 prompt items 1 and 6; keep agent on request |
| slice-critic | RETIRE as per-slice requirement (no recorded catch) | optional once per high-risk PR; items folded into R-517 prompt |
| Codex/cross-model review | RETIRE as requirement; KEEP as opt-in and router option | none |
| Round caps | KEEP principle | MODIFY to explicit triggers (2.1, 2.2) |
| Detector | KEEP strong hits | MODIFY (anchor patterns, tests/fixtures/docs weak, one-round rule for detector edits) |
| build-by-slice / build-fast | KEEP | MODIFY (single statement of review rounds; build-fast stop-on-new-round-2-finding as the general rule) |
| Artefact JSON + shared ledger + head pin | KEEP the fail-closed binding | MODIFY (write once, tail rule); retire the per-round paperwork |

## 4. Evidence index (file:line / sha)
- Proposal: docs/proposals/2026-10-02-governance-pruning.md:11 (three real catches), :13 (telemetry noise), :90 (R-109 40 real blocks; session substring), :124, :213, :257 (I6, I7), :281, :286 (sync.sh seven rounds; later rounds only pay on security), :289 (budget exception), :382 (owner answer).
- Rule text: claude/CLAUDE.md:7,12,13,21,22; claude/rulebook/reference.md R-109 (line 102), R-110 (114), R-514 (785), R-517 (817).
- Gate: claude/hooks/git-workflow-guard.sh:1-70 (rule header), :585-610 (is_reviewed_tail, "R-109 passes 0"), :1088, :1242, :1409-1453 (deny/ask), :1489.
- Detector: claude/hooks/security-surface.sh:1-60; claude/enforce/security-surface.json (49 lines).
- Artefacts: docs/security-reviews/PR-{154,156,157,158,159,160,161,162,163,169,172,176,178,180,182,183}-*.json; docs/audits/2026-10-03-ian605-subagent-watchdog-security-review.json; PR #171 artefact at origin/fix/security-surface-skip-tests:docs/security-reviews/PR-171-IAN-515.json.
- PR #183: afa13a6 commit message (R-517 r1 findings 1-6, R-109 r1-r7 fix commits, "waived by the owner on 2026-10-03"), docs/slices/slice-04-quota-aware-routing.md:53 (450 -> 1,100 lines), artefact note (rate_limits trigger).
- Protocol: claude/PROTOCOL.md:305-345 (2026-10-01, 2026-10-02 entries).
- History: afaea90 (R-517 origin, 2026-09-19), 4739b97/0170ce1 (reviewer mechanics), facc726 (#172 docs-only tail, 5 rounds), 0045ad4 (#177 two-round cap, R-110), 676f39b (#182 IAN-568), docs/audits/2026-09-26-process-and-rules.md:103-106.
- Caveat: voyager PR #16 and the sync.sh round data are cited from the proposal; the underlying voyager artefact is not in these repos. Per-round time/token cost of R-109 rounds is not recorded anywhere; the counts above are rounds and findings only. The R-517 PR #183 table (rows 1-11) is reconstructed from commit messages; the PR body itself is not in the repository.
