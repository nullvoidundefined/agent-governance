# Cited commits must be reachable (IAN-308 phase 1)

Ticket: IAN-308. Branch: `feat/doc-sha-reachability`. Tier: standard.

## Summary

This repository ships mostly documents, and CI checks that its scripts run rather than that its documents are true. Every adversarial review over 2026-09-22 and 2026-09-23 returned a HIGH finding that CI had passed clean, and most of those findings were factual rather than behavioural. One of them is deterministically checkable, and it is the one this change implements.

A commit SHA written into a document is a promise that the commit can still be fetched. The IAN-260 spec, written the day before this change, cited four migration sources; three of them (`c6af9dd`, `23cdfca` and `ef2d24b`) sat on no ref at all, because the pull-request branches that carried them were deleted after merge. Each still resolved in the author's clone, so the document read as correct there and nowhere else: an unreachable object is prunable by auto-gc and absent from every fresh clone, so the slice that depended on those commits would have found its inputs gone. They were pinned as the tags `keep/ian260-migration-r605-audit`, `keep/ian260-migration-r605-corrected` and `keep/ian260-migration-ian184-gate` before that spec merged.

`claude/enforce/doc-sha-reachability.sh` is the check that would have caught it, and the fixture beside it carries that spec as a live regression case, so deleting any one of those three tags now turns the suite red.

Phase 2 of the ticket, which extends `rule-judge.yml` to judge factual self-consistency in documents, is deliberately not in this change, and no file under `.github/workflows/` is touched.

## What changed

- `claude/enforce/doc-sha-reachability.sh`, new. It collects every backticked 7-to-40 character hexadecimal token in the documents it is asked about, in either case, normalises them to lowercase, resolves them all in one `git cat-file --batch-check`, reads reachability from one `git rev-list --all`, and reports every token that resolves in this repository and that no ref reaches, naming the citing file and line.
- `claude/enforce/tests/doc-sha-reachability.test.sh`, new. Seventy-five assertions over nineteen behaviours, including the live IAN-260 case and the three `keep/` tags.
- `claude/hooks/pre-push.sample` runs the check in `--push` mode over the refs git hands it on stdin, so a push that publishes a document citing an unreachable commit is refused.
- `claude/CLAUDE.md` and `claude/rulebook/reference.md` carry the new rule R-215, and `claude/enforce/manifest.json` registers its enforcer as `ci:doc-sha-reachability` (R-516). `codex/` and `cursor/` are the regenerated ports of those two rule files.
- `claude/enforce/hook-hashes.txt` is regenerated, because both new files sit under trees the integrity guard covers.

## Architectural decisions

**Where the gate runs: the local push boundary, not CI.** Chosen: `hooks/pre-push.sample` runs `--push`, and CI runs the fixture. The alternative was a corpus gate as a CI step. It was rejected for a reason that is worth stating plainly, because it is the limit of the whole check: a clone can only be asked about objects it holds. The objects behind an unreachable citation exist in the author's clone and, once the branch carrying them is deleted, nowhere else; a clone that never received them cannot tell such a citation from a citation of some other repository's commit, and the check deliberately reports neither. So the only moment the question can be answered is while the author still holds the object, which is also the only moment the repair (pinning the commit under a tag) is still possible.

**The gate reads the pushed commits, not the working tree.** What is about to become public is the commit. An earlier draft of this change read the working tree, which meant a committed unreachable citation passed the moment an uncommitted edit happened to remove it, and a first-push branch with no upstream produced "cannot judge" rather than an answer. The hook now hands the check git's pre-push ref list, and the check derives each pushed ref's new commits with one `git rev-list <tip> --not --remotes=<remote>`, their changed paths with one `git diff-tree --stdin`, and each document's content with `git show <tip>:<path>`.

**A state the check cannot judge aborts the push.** Exit 2 is a decline, not a pass: a shallow clone, a document it cannot read, a change set it cannot list, and a resolver that failed all reach it, and the hook treats it exactly as it treats a finding. A question that cannot be answered must not be recorded as an answer of "fine", and there is no path through the check on which it reports success without having resolved what it collected.

**A token that resolves to nothing is not a finding.** Documents in this repository legitimately cite other repositories' commits, and seven-character hexadecimal strings occur in prose. The check cannot tell a foreign SHA from a pruned one, so it reports neither, and says so in its own header rather than leaving the reader to infer it.

**The escape hatch is an adjacent marker, not an allowlist file.** Chosen: an `unreachable-sha` HTML comment on the citing line. The alternative was a central allowlist. A list far from the citation rots: an entry outlives the line it excused, and nobody reading the document sees that an exception was taken. The marker sits where whoever edits the citation will see it. Six conditions keep it from opening by accident, and each is fixtured in both directions: it names the same commit the citation names, compared with both lowercased; it sits on the citing line; its reason carries a real word, so whitespace, an empty reason and `...` all fail; it is not inside inline code, not inside a fenced block, and not inside an HTML comment that opened on an earlier line, so a marker shown as an example in prose (this document, the rule text and the check's own header all show one) excuses nothing; and one marker excuses one citation, so a line citing the same commit twice needs two markers.

**Four git processes, not one per token.** One `git cat-file --batch-check` over all collected tokens, one `git rev-list --all`, and the two `git rev-parse` calls that locate the repository and detect a shallow clone. All the joining is done in `awk`. The hook tree paid for the alternative expensively in IAN-183, where a process per path component put the whole Write chain over budget, so the fixture asserts the budget directly: thirty citations of thirty distinct commits that all resolve and are all unreachable must cost at most eight git invocations, counted through a logging shim on `PATH`. Documents cost one read process each, and in `--push` mode that read is a `git show`, which is per changed document rather than per token.

**Hostile filenames are handled by never delimiting a path.** Every document is copied to a numbered file and its real path stored beside it, so nothing downstream parses a path out of a delimited record. A document named `docs/with:colon.md` and one whose name contains a newline are both inspected, and the fixture carries both.

**The historical corpus is reported, not gated.** `--all` over this repository today reports 73 citations in 10 documents, nearly all of them in pull-request documents citing the pre-squash commits of branches deleted after merge. Gating them would mean either 34 new tags or 73 new markers, which is a different change from this one; it is IAN-322.

## Testing

Test-first under the R-412 slice lock, twice: once for the original implementation and once for the review round, each with `tdd.sh red` certifying the fixture failing for an assertion with 104 other fixtures passing and `tdd.sh green` certifying it passing with the same 104 outside.

Every one of the seventy-five assertions was driven to FAIL by at least one deliberate mutation of the implementation, each applied to a copy of the harness outside the repository, and the coverage is computed rather than remembered: a prover runs each mutation, unions the assertions that went red, and prints the ones no mutation reached. That list is now empty.

| Mutation | Assertions it breaks |
| --- | --- |
| No finding is ever printed | 26 |
| Reachability is never consulted | 11 |
| No citation is collected | 56 |
| Every repository is declined | 65 |
| A shallow clone is judged rather than declined | 2 |
| `claude/docs/` is not a document root | 7 |
| A token that resolves to nothing is reported | 3 |
| The escape hatch never opens | 11 |
| `--changed` reads the whole corpus | 7 |
| The push gate reads the working tree | 6 |
| Uppercase hexadecimal is not a citation | 3 |
| The marker match is case sensitive | 6 |
| Whitespace and punctuation count as a reason | 8 |
| An example marker in code or a comment excuses | 10 |
| One marker excuses the whole line | 6 |
| The document list is newline delimited | 10 |
| A failing resolver is swallowed | 6 |
| An unreadable document is skipped | 6 |
| One resolver process per token | 49, including the batching budget |
| The hook lets a decline through | 5 |
| The hook asks `--changed` rather than `--push` | 6 |
| The sample hook carries no gate | 8 |
| The installer refuses to upgrade an installed hook | 2 |
| The checkout carries no `keep/` tags | 4, including all three tag assertions |

No assertion in the fixture asserts the absence of an error string. Each one asserts either the presence of a finding naming its SHA, its file and its line, or the presence of the clean summary line carrying a non-zero count of what was inspected. That rule is written into the fixture's header, because this repository shipped three absence-asserting tests in two days, each passing against an implementation that had stopped running.

The live spec reports `OK, 9 cited token(s) in 1 document(s), 7 resolve here, all of those reachable`, in four git processes.

## What this does not enforce

`.git/hooks` is not version-controlled, so editing `hooks/pre-push.sample` changes nothing in a repository that already installed an older copy. The hook installed in this checkout on 2026-09-18 does not carry this gate, and will not until `bash ~/.claude/hooks/install-git-hooks.sh <repo>` is re-run; the installer upgrades an installed hook in place when its header marks it as the installer's own, and the fixture proves that path rather than assuming it. Until that is run, R-215 is manual in that repository, and nothing detects the staleness automatically today. The rule says so in the same words.

CI runs the fixture, not a corpus gate. The checkout there is a depth-1 clone, so the check declines on it outright and the fixture's live-corpus block states that it did not run instead of passing blind. Giving that job a full clone is IAN-323.

## Reflection

What is clear now that was not at the start: this check can only ever work in the author's clone. The instinct was to make it a CI gate, because that is where a check cannot be skipped, and a CI gate here would have been theatre. The runner's clone does not hold the objects the question is about, and the greener that job looked the less it would have been measuring. The honest arrangement puts the gate at the push boundary, where the objects still exist, and gives CI the fixture, which is a claim CI can actually verify.

What was wrong first, and this is the part worth carrying: the first implementation gated the working tree rather than the commits being pushed. That reads as a small slip and is not one. A gate that inspects the working tree answers a question nobody asked, because the working tree is not what a push publishes, and the failure it allowed was the silent direction, where an uncommitted edit makes a committed defect invisible. The review also found that a brand-new branch, which is the common case for the gate, returned "cannot judge" and that the hook then let it through, so the gate was open exactly when it was most needed. Both came from the same habit of reasoning about the files in front of me rather than about the artifact the command actually produces.

The second thing wrong first: the scope was a single corpus gate, and it survived until the corpus was actually scanned and returned 73 findings across 10 documents. Those are not defects introduced by carelessness; they are what a repository looks like after months of squash-merging and deleting branches. A gate that is red on arrival gets disabled, so the scope moved to the documents a push carries, and the backlog became its own ticket.

One limit is worth carrying forward: the check catches a citation of a commit that is already unreachable when it is written, which is the IAN-260 case exactly. It does not catch the slower rot, where a document cites a live branch commit and that branch is deleted three days later. Nothing at write time can catch that, and a periodic `--all` sweep is what would.
