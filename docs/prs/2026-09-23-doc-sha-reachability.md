# Cited commits must be reachable (IAN-308 phase 1)

Ticket: IAN-308. Branch: `feat/doc-sha-reachability`. Tier: standard.

## Summary

This repository ships mostly documents, and CI checks that its scripts run rather than that its documents are true. Every adversarial review over 2026-09-22 and 2026-09-23 returned a HIGH finding that CI had passed clean, and most of those findings were factual rather than behavioural. One of them is deterministically checkable, and it is the one this change implements.

A commit SHA written into a document is a promise that the commit can still be fetched. The IAN-260 spec, written the day before this change, cited four migration sources; three of them (`c6af9dd`, `23cdfca` and `ef2d24b`) sat on no ref at all, because the pull-request branches that carried them were deleted after merge. Each still resolved in the author's clone, so the document read as correct there and nowhere else: an unreachable object is prunable by auto-gc and absent from every fresh clone, so the slice that depended on those commits would have found its inputs gone. They were pinned as the tags `keep/ian260-migration-r605-audit`, `keep/ian260-migration-r605-corrected` and `keep/ian260-migration-ian184-gate` before that spec merged.

`claude/enforce/doc-sha-reachability.sh` is the check that would have caught it, and the fixture beside it carries that spec as a live regression case, so deleting any one of those three tags now turns the suite red.

Phase 2 of the ticket, which extends `rule-judge.yml` to judge factual self-consistency in documents, is deliberately not in this change, and no file under `.github/workflows/` is touched.

## What changed

- `claude/enforce/doc-sha-reachability.sh`, new. It collects every backticked 7-to-40 character hexadecimal token in the documents it is asked about, resolves them all in one `git cat-file --batch-check`, reads reachability from one `git rev-list --all`, and reports every token that resolves in this repository and that no ref reaches, naming the citing file and line.
- `claude/enforce/tests/doc-sha-reachability.test.sh`, new. Forty-one assertions over eleven behaviours, including the live IAN-260 case and the three `keep/` tags.
- `claude/hooks/pre-push.sample` runs the check in `--changed` mode, so a push that publishes a document citing an unreachable commit is refused.
- `claude/CLAUDE.md` and `claude/rulebook/reference.md` carry the new rule R-215, and `claude/enforce/manifest.json` registers its enforcer as `ci:doc-sha-reachability` (R-516). `codex/` and `cursor/` are the regenerated ports of those two rule files.
- `claude/enforce/hook-hashes.txt` is regenerated, because both new files sit under trees the integrity guard covers.

## Architectural decisions

**Where the gate runs: the local push boundary, not CI.** Chosen: `hooks/pre-push.sample` runs `--changed`, and CI runs the fixture. The alternative was a corpus gate as a CI step. It was rejected for a reason that is worth stating plainly, because it is the limit of the whole check: an unreachable object exists in the author's clone and nowhere else. A CI runner clones at depth 1 and fetches one ref, so every citation in it resolves to nothing and the check has nothing to judge. By the time a fresh clone could ask the question, the answer has already been lost. The only moment the question can be answered is while the author still holds the object, which is also the only moment the repair (pinning the commit under a tag) is still possible.

**A token that resolves to nothing is not a finding.** Documents in this repository legitimately cite other repositories' commits, and seven-character hexadecimal strings occur in prose. The check cannot tell a foreign SHA from a pruned one, so it reports neither, and says so in its own header rather than leaving the reader to infer it.

**The escape hatch is an adjacent marker, not an allowlist file.** Chosen: `<!-- unreachable-sha: <sha> <reason> -->` on the citing line. The alternative was a central allowlist. A list far from the citation rots: an entry outlives the line it excused, and nobody reading the document sees that an exception was taken. The marker sits where whoever edits the citation will see it. Three conditions make it hard to fire by accident, and each is fixtured in both directions: the marker must name the same token the citation names, so a marker copied onto another line excuses nothing; it must be on the same line, so a marker that drifts one line away excuses nothing; and it must carry a reason after the SHA, so a blank marker excuses nothing. The marker itself carries no backticks, so it is never read as a citation of its own.

**Three git processes, not one per token.** Chosen: one `git cat-file --batch-check` over all collected tokens and one `git rev-list --all`, with all the joining done in `awk`. The hook tree paid for the alternative expensively in IAN-183, where a process per path component put the whole Write chain over budget, so the fixture asserts the budget directly: thirty tokens must cost at most eight git invocations, counted through a logging shim on `PATH`.

**A shallow clone is declined, not passed.** Exit 2 with `DOC-SHA-DEGRADED`, rather than exit 0 with no findings. A shallow clone holds none of the objects beyond its graft, so every unreachable citation in it looks exactly like a citation of another repository, and a silent pass would be a false all-clear. The pre-push hook reports that state and does not abort the push, because a question the check cannot answer is not a finding.

**The historical corpus is reported, not gated.** `--all` over this repository today reports 73 citations in 10 documents, nearly all of them in pull-request documents citing the pre-squash commits of branches deleted after merge. Gating them would mean either 34 new tags or 73 new markers, which is a different change from this one; it is recorded as a finding and left to its own ticket.

## Testing

Test-first under the R-412 slice lock. `tdd.sh red` certified the fixture failing for an assertion with 104 other fixtures passing; `tdd.sh green` certified it passing with the same 104 outside.

Every one of the forty-one assertions was driven to FAIL by at least one deliberate mutation of the implementation, each applied to a copy of the harness outside the repository:

| Mutation | Assertions it breaks |
| --- | --- |
| No finding is ever reported | 6 |
| Reachability is never consulted | 7 |
| Every citation is excused | 18 |
| The marker ignores sha, line and reason | 5 |
| One `git` process per token | 20, including the batching budget |
| A shallow clone is judged rather than declined | 2 |
| `claude/docs/` is not a document root | 2 |
| `--changed` reads the whole corpus | 1 |
| The checkout carries no `keep/` tags | 4, including all three tag assertions |
| An unresolvable token is reported | 7 |
| The escape hatch never opens | 3 |
| No token is collected at all | 25 |
| Every repository is declined | 31 |
| The check declines, inside a repository | the IAN-260 spec assertions |
| Nothing is collected, inside a repository | the IAN-260 inspection assertion |

No assertion in the fixture asserts the absence of an error string. Each one asserts either the presence of a finding naming its SHA, its file and its line, or the presence of the clean summary line carrying a non-zero count of what was inspected. That rule is written into the fixture's header, because this repository shipped three absence-asserting tests in two days, each passing against an implementation that had stopped running.

## Reflection

What is clear now that was not at the start: this check can only ever work in the author's clone. The instinct was to make it a CI gate, because that is where a check cannot be skipped, and a CI gate here would have been theatre. The shallow checkout would have made every run vacuously green, and the greener it looked the less it would have been measuring. The honest arrangement puts the gate at the push boundary, where the objects still exist, and gives CI the fixture, which is a claim CI can actually verify.

What was wrong first: the intended design was a single corpus gate, and it survived until the corpus was actually scanned and returned 73 findings across 10 documents. Those are not defects introduced by carelessness; they are what a repository looks like after months of squash-merging and deleting branches. A gate that is red on arrival gets disabled, so the scope moved to the documents a branch touches, which is the ratchet the repository already applies elsewhere, and the backlog became a finding rather than a blocker.

One limit is worth carrying forward: the check catches a citation of a commit that is already unreachable when it is written, which is the IAN-260 case exactly. It does not catch the slower rot, where a document cites a live branch commit and that branch is deleted three days later. Nothing at write time can catch that, and a periodic `--all` sweep is what would.
