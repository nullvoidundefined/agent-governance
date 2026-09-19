# Maintenance tax and team fit: the answer to "is this bureaucracy?"

Date: 2026-09-19

## The question

A skeptical reviewer reading this repository sees 81 numbered rules, a 100 KB rulebook, a rule about how to write rules (R-206), and a commit history where much of the work is the system maintaining itself: hash-manifest regeneration, port maps conflicting on merges, and sync bugs such as a sync that discarded its own stderr, so a file it kept instead of removing was reported to nobody (fixed in `bde12cd`). The fair version of the critique is not "this is bad". It is "what is the maintenance tax, and would the system survive contact with four other people's preferences?" This document answers both with numbers from the history, names what would change the answer, and says what would change in a team setting.

## The short answer

About a third of all commits carry harness self-maintenance, and roughly two thirds of the bug fixes are the harness repairing its own plumbing rather than catching a problem in product code. Most of that tax traces to three design choices: a checked-in hash manifest, checked-in generated ports for Codex and Cursor, and a copy-based sync into live directories. Each of the three has a known replacement. The part of the system that would survive four other engineers is the safety floor, roughly a fifth of the rules. Most of the rest is one person's workflow encoded as rules, and on a team it becomes an opt-in personal profile rather than a mandate. Whether the tax is one-time architecture debt or structural is being measured this week against a decision rule written before any data came in (IAN-121).

## The numbers

The history counts below were measured at commit `1aca2e6`, covering 282 commits from 2026-05-27 to 2026-09-19; later commits shift them by one or two without changing any percentage. Commits were classified by conventional type and by the files they touched.

| Measure | Value |
|---|---|
| Commits touching `claude/enforce/hook-hashes.txt` | 89 of 282 (32%) |
| Commits touching generated `codex/` or `cursor/` output | 42 |
| Commits touching port maps or port status | 15 |
| Commits touching only records (`docs/session-handoff`, `docs/prs/`, `docs/audits/`, `ISSUES.md`, `TODO.md`, `global-memory/`) | 30 (11%) |
| `fix` commits | 69 |
| Commits since 2026-09-15 | 120 in five days, driven by two audits and their remediation |
| Harness share of all commits across the owner's repositories, 2026-09-15 to 2026-09-18 | 85% (IAN-121 baseline) |
| Harness fix share over the same window | 36% (IAN-121 baseline) |

The 69 fixes, classified by hand from their subjects:

| Fix class | Count | What it means |
|---|---|---|
| The harness fixing its own machinery (sync, fixture hermeticity, ports, doctor, docs drift, the judge's plumbing) | about 44 (64%) | This is the maintenance tax proper. |
| Guard bypasses closed (fail-open error paths, `core.hooksPath` forms, interpreter allow-list escape, push gates that executed target-repository code, secret-scan coverage of Write and Edit) | about 12 | This is the product doing its job: each fix made a safety guard harder to get around. |
| Rules tuned after meeting real code (Next.js route handlers, Nuxt and FastAPI route surfaces, Prettier import grouping, `@/` aliases, test-directory exemptions, a spuriously blocking Stop gate) | about 13 | This is the "other people's preferences" signal, discussed below. |

## Where the tax comes from, and what replaces each source

1. **The checked-in hash manifest.** Every edit to a hook, rule, or fixture regenerates `hook-hashes.txt`, which is why a third of all commits touch it and why it conflicts whenever two branches edit enforcement files. Git already stores a content hash for every tracked file, so the integrity check can compare each live file against the blob hash of the commit that `sync.sh` recorded in its source stamp, with no separate manifest. To confirm before changing: that the tamper cases the manifest currently catches (a hook body replaced by `exit 0` in the live tree or in the checkout) are all still caught when the expected hash comes from `git ls-tree` at the stamped commit.

2. **Checked-in generated ports.** `codex/` and `cursor/` are generated from `claude/` by `translate/*.mjs`, yet they are committed, so every rule change produces a second diff and every merge can conflict in generated output and in the port maps. The usual remedy is to stop committing generated output and generate it at sync time, keeping a CI `--check` that the generator runs cleanly. If committed output must stay for readability, mark it generated and resolve conflicts by regenerating rather than merging.

3. **Copy-based sync into three live trees.** The sync bugs (files left behind after the repository stopped tracking them, lockfile changes that did not reinstall dependencies, a successful sync that discarded its stderr so a kept file was reported to nobody) all come from copying a checkout into live directories and then reconciling drift. Plugin packaging, which Claude Code supports natively and which ECC uses, removes the copy step for the Claude side. This is exactly the counter-hypothesis that IAN-121 is testing: if harness fixes stay high after the test-architecture work, the distribution design is the structural cost.

4. **Fixture hermeticity.** About ten fixes made tests stop reading ambient harness state or the real repository. This source looks like one-time debt: once fixtures run from scratch directories with their own configuration, it should stop recurring.

## The bureaucracy objection, rule by rule

Rule IDs are the join key between a norm, its enforcer, its fixture, and its fire log. They are what make "which rules actually fire, and which depend on recall" answerable at all: at the time of writing, 51 of the 81 norms are enforced mechanically, 2 by the judge, and 28 depend on recall, and that split is only knowable because each rule has an ID and a manifest entry. That is the engineering answer. The presentation answer is weaker, because a reader meets the IDs before meeting the reasons.

- **R-003 (synced harness at SessionStart).** This reads as process, but it is the distribution mechanism, and its bug history is the largest single source of the tax above. It is the rule most likely to be replaced rather than defended.
- **R-105 (confirm destructive MCP actions).** This is safety floor and a team keeps it. It reads as bureaucracy mainly because its exemption for tracker writes is spelled out in the norm line; that detail belongs in the reference, not the always-loaded line.
- **R-206 (model-facing instructions are direct imperatives, no rationale).** The rule governs one channel: text the model loads every turn. Rationale in that channel costs tokens in every session, and in practice it invites the model to argue its way to an exception. The rationale is not deleted; it lives in `claude/PROTOCOL.md` (45 KB) and `claude/rulebook/reference.md`. The fair criticism is that a human reading the rule file sees the model's format without the reasons. The remedy is presentational: each norm links to its PROTOCOL entry, and the human-facing README leads with the outcomes the rules protect rather than with the rule list.
- **R-607 (product docs in every application repository).** This is one person's product-management preference, not engineering safety. It already has an opt-out (`.enforce.json` `"productDocs": false`). On a team it should be opt-in.

## Would it survive four other people's preferences?

Not as a single mandatory rule set, and it should not have to. The 13 rule-tuning fixes above came from one person's four repositories; each is a rule meeting code it did not anticipate. Five people's repositories and habits would multiply that rate, and without a way to adjudicate false positives, every one of them becomes a person either fighting the harness or asking to disable a guard. The 2026-09-18 criticism audit already names the missing piece: there is no false-positive adjudication workflow.

What a team version looks like:

| Layer | Contents (sketch) | Who decides |
|---|---|---|
| Safety floor | Destructive-command and destructive-database guards, secret scanning and redaction, hook integrity, protected gate inputs, never merging without authorization, the P1 ports from the ECC audit | Non-negotiable for everyone; changes by review |
| Team conventions | Naming, structure, layering, testing discipline, the TDD lock, commit and PR shape | Negotiated once, then per repository through `.enforce.json` |
| Personal profile | Session declaration, prose style, the em-dash ban, progress percentages, ticket bookkeeping, handoff format, product docs | Each engineer's own; never imposed on others |

Two mechanisms make the layering hold:

- **An override path with a reason.** A guard that fires on legitimate work can be overridden with a logged reason instead of a disable switch. The override log is the false-positive data.
- **A retirement rule.** A rule whose override rate passes a threshold, or that has not fired in a set period, is demoted a layer or deleted. That turns "the rules only grow" into a measured lifecycle.

## What would change this answer

- **IAN-121 verdict, due 2026-09-26.** If the harness fix share falls to 25% or lower and the harness share falls below 85%, the tax was mostly one-time debt and the three design changes above are lower priority. If the fix share stays at 36% or higher, the tax is structural and the distribution redesign (items 1 to 3 above) comes first.
- **Outcome evidence.** None of these numbers says whether the harness makes product code better. The honest ceiling on every claim here is that the system is measured on its own activity. A before-and-after measure on product repositories (escaped defects, reverted commits, review rework) is what would turn "impressive control plane" into "worth the tax".
