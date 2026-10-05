# Why the harness has this shape

This file is history, not instructions. It is not loaded automatically. Read it before adding a rule, hook, or gate.

## 2026-05 to 2026-09: a rules file became a compliance system

The harness started as one global rules file. Over the summer it added numbered rules, hooks to enforce them, and tests for the hooks. It then added manifests and closure tests to prove that every rule had an enforcer, which brought integrity hashes, harness profiles, ports to Codex and Cursor, and a TDD state machine (`tdd.sh`) with a separate test author, implementer, and critic for each slice.

Each step answered a real incident. Together they took over the work:

- 73% of `main` commits touched hooks or enforce code; 83% touched some plumbing.
- 35,900 lines of hook tests existed to test 17,200 lines of hooks. Nine of them only checked that rule prose contained certain words.
- About 64% of fixes in one audit window were harness plumbing. The harness was 75 to 85% of the owner's merged PRs across four repositories.
- On product work the process cost ran at 7 to 15 times the implementation time. Voyager PR 2 took about 6 hours for about 250 lines, including 2 hours of test disputes and a lock deleted by hand three times.

The loops were structural, not accidental:

- A review fix reopened the whole TDD lifecycle.
- The security review required a fresh insecure-value test for every new control, and it had to cover the head commit. So any fix, even for a LOW finding, forced another full round: 69 rounds across 17 PRs.
- A keyword detector decided which PRs needed security review, and the word `rate_limits` was enough to trigger one.
- Gates were added to protect other gates.

## 2026-10-02: IAN-568 pruned to a 1:1 process budget

IAN-568 cut the loaded rules to 14 lines, deleted 13 rules and 9 hooks, and introduced risk tiers. High-risk work kept the TDD lock and the three roles. Standard work got "tests written alongside the code" and one review.

It kept the security review's unbounded rounds as the single exception to the budget, and it left the plumbing that caused most of the maintenance in place. A new mandatory rule (R-708) arrived the next day, at 837 lines for a single incident.

## 2026-10-03: an over-prune (#187), then this recovery

A follow-up prune (#187) deleted almost every process control. The recovery that replaced it looked at what had actually caught bugs:

- **Caught real bugs:**
  - The pre-merge review found PII in Voyager #16, tests that could not fail, and a masking bug six security rounds missed.
  - The security review caught real issues, including a command injection through a git option.
  - The rule that tests must fail when the code is wrong caught a parser that would have returned null.
- **No recorded product catch:** the TDD lock (over 300 denies across its rules), the per-slice critic, the spec-conformance review, the turn-end verification gate (320 blocks), and most of the policing hooks.

So the recovery kept the practices and changed how they are enforced:

- Standard work went back to test-first, which IAN-568 had dropped. A different model writes the failing test, and RED is observed and committed. There is no lock.
- One fresh-context review per PR, with explicit stopping rules.
- A security review capped at three rounds, with a frozen list of controls and a severity ceiling for inputs only the owner controls. Cut to two rounds on 2026-10-05 (below).
- Evidence before "done": the PR records its verification, and CI is the backstop.
- The lock, role boundaries, and threat models remain, for high-risk work only.
- Manifests, integrity hashes, profiles, the verification gate, ticket and provenance bookkeeping, and the rule IDs were retired.

## The security review leash (2026-10-05)

A doppelscript quality program ran high-risk slices for 3 to 5 hours each. The security review paid for itself once: on the billing slice it found a free rewrite usable as an unlimited general generator. On the LLM failover slice the general review found the HIGH and five MEDIUMs, and the security review found only LOWs. Background jobs and retries were high risk only because the list named "locks, queues, or retries". The owner narrowed high risk to security controls (auth, secrets and PII, payments and quota, SQL from input, trust-boundary input, destructive data operations, CORS and headers), moved reliability work to standard risk with an integration test against the real dependency, cut both reviews to one round plus one more for a HIGH or a MEDIUM fixed in code, waived LOW findings into one follow-up ticket per PR, capped owned-dependency-outage findings at LOW, froze PR scope, and time-boxed high-risk tasks at about 90 minutes from RED.

## The lesson

A harness drifts toward optimizing its own measurable artifacts: rounds completed, checks satisfied, tests counted. Its own maintenance is easy to leave out of its cost. The anti-recursion rules in `CLAUDE.md` exist to stop that. Before adding anything here, answer the five questions in "Prefer simple enforcement", count the maintenance, and ask the owner.
