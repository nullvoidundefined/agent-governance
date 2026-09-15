# Global Rules Restructure: Design

**Date:** 2026-07-03
**Scope:** `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md`, `~/.claude/PROTOCOL.md`, plus every live reference to a rule ID (hooks, enforce/, skills, prompts, memory, living project CLAUDE.md files).
**Status:** Approved by user 2026-07-03 (template, century-block renumber, map-driven migration, hooks staged as PR 2, detail kept in CLAUDE.md, rationale moved to PROTOCOL.md).

## Problem

1. **Numbering is disordered.** Document order is "by importance, not by ID," so IDs appear scrambled within sections (R-225 before R-224, R-220, R-234). Gaps and inline tombstones (R-105, R-216) add noise.
2. **Grammar is inconsistent.** Rules range from 5 words (R-006) to ~250-word paragraphs (R-235, R-241) mixing the norm with examples, counter-examples, incident anecdotes, and enforcement narration.
3. **Enforcement is described narratively** inside rule text instead of a uniform machine-checkable field, despite R-518 making enforcement manifest-driven.

The file violates its own R-512 (direct imperatives, omit rationale).

## Goals

- One grammatical template for every rule, in every rule file.
- Clean numerical order: document order equals numeric order, sequential within category blocks, no gaps at rewrite time, no tombstones.
- Rationale and incident history relocated to `PROTOCOL.md`; rules become pure norms.
- Zero behavior change: every current norm survives with identical meaning; all enforcement keeps firing.
- Mechanizable prose rules converted to hooks in a staged follow-up PR.

## Non-goals

- No rule is added, weakened, or retired in this restructure (PR 1). Semantic changes are out of scope.
- Convention files (`CLAUDE-BACKEND.md`, etc.) are not restructured; only their rule-ID citations update.
- Historical documents (audit reports, PR docs, specs, plans in project repos) are never edited.
- No changes to the lazy-load architecture: `CLAUDE.md` always-loaded, `rules/*.md` loaded per session type.

## Design

### 1. Rule template

Every rule in every rule file follows one anatomy. Simple rules collapse to the first line; `Scope`/`Spec`/`Enforcement` fields appear only when needed.

```
R-NNN [ts]: <One imperative sentence stating the norm.>
  Scope: <where it applies; exceptions>
  Spec: <bulleted thresholds, orderings, vocabularies, mappings>
  Enforcement: hook:<name> | eslint:<rule> | judge | manual
```

Grammar constraints:

- Line 1 is a single imperative sentence, present tense, second person implied. No rationale, no history, no examples-as-narrative, no "because", no incident references.
- Stack tags (`[ts]`, `[py]`) stay in their current position after the ID.
- `Spec` bullets carry all normative detail currently embedded in prose (the R-235 file-split rules, the R-236 monorepo shape, the R-218 layout order). Nothing normative is dropped; full detail stays in the always-loaded file.
- Cross-references keep the form `(R-NNN)` and use new IDs.
- `Enforcement` names the manifest enforcer exactly as `enforce/manifest.json` spells it; `manual` marks honor-system rules. This replaces all inline "Enforced by X.sh (PreToolUse)..." narration.
- Tombstones are deleted. Git history is the retirement record.

### 2. Numbering: century blocks, R-NNN shape preserved

The `R-\d{3}` shape is kept deliberately: `llm-rule-judge`, `enforcement-guard-check`, and the R-305 memory-tag convention (`fired: R-NNN`) parse rule IDs generically. Category prefixes (SEC-01) would break those parsers; renumbering within R-NNN only changes literals.

Blocks, in document order (document order = numeric order, sequential within block):

| Block | Category | File | Today's sources |
|---|---|---|---|
| R-0xx | Session init & meta | CLAUDE.md | R-300, R-007, session-init section |
| R-1xx | Secrets & trust | CLAUDE.md | R-101 to R-111 except R-103 |
| R-2xx | Conduct & output | CLAUDE.md | R-001, R-002, R-003, R-005, R-008, R-009, R-010, R-512, R-513 |
| R-3xx | Architecture & naming | CLAUDE.md | R-217 to R-242 (ordered macro to micro as today) |
| R-4xx | Testing & quality | CLAUDE.md | R-200 to R-208, R-004, R-006 |
| R-5xx | Git & process | CLAUDE.md | R-209 to R-215, R-505, R-507 to R-510, R-515 to R-519 |
| R-6xx | Lifecycle & memory | CLAUDE.md | R-301, R-302, R-305, R-103 |
| R-7xx | Agents & dispatch | rules/agents.md | R-102, R-303, R-304, R-501, R-511, R-514 |
| R-8xx | Audits | rules/audits.md | R-400 to R-403, R-107 |
| R-9xx | Cost, routing, estimation | rules/cost.md | R-500, R-502 to R-504, R-506, R-600 |

Assignment rules:

- Within each block, numbering starts at x01 and increments by 1 with no gaps.
- Ordering within a block mirrors today's intent (secrets: most protective first; architecture: macro to micro; process: workflow order).
- A rule living in a lazy-loaded `rules/*.md` file takes an ID from that file's block, so block membership also encodes load tier.
- Future rules append at the end of their block; the "document order is by importance" convention is abolished.
- The authoritative old-to-new mapping is a single table produced in the implementation plan and reviewed before any file changes. Every one of the 94 currently referenced IDs must appear exactly once as a source.

### 3. File roles (unchanged, reformatted)

- `CLAUDE.md`: preamble (trimmed), session-init block, then R-0xx to R-6xx sections in numeric order, then the convention-files table.
- `rules/agents.md`, `rules/audits.md`, `rules/cost.md`: same template, R-7xx/R-8xx/R-9xx. `rules/session-types.md` holds tables, not numbered rules; it is reformatted for consistency but gets no IDs.
- `PROTOCOL.md`: gains two appendices. **Rule origins** holds the rationale and anecdotes removed from rule text, one short entry per rule that had any. **Legacy ID alias table** holds the complete old-to-new map, permanent, so historical docs and old memory tags remain interpretable.

### 4. Migration procedure (map-driven, two-phase)

Validated against the temporary audit association map (scratchpad artifact, 94 IDs across four tiers; regenerated post-migration; never committed).

1. Branch `refactor/rules-restructure` in `~/.claude`. Leave the currently dirty `settings.json` and untracked `chrome/`, `.superpowers/` out of every commit.
2. Rewrite the five rule files to the new template and numbering by hand (not sed); content is being restructured, not just renamed.
3. Mechanical ID migration for all other live references using the map: two-phase rename (each `R-OLD` to a unique temp token, then to `R-NEW`) so swaps cannot collide.
   - **Tier A, live enforcement (same commit, atomic):** `hooks/*.sh`, `hooks/tests/`, `enforce/manifest.json`, `enforce/eslint.config.mjs`, `enforce/lint.mjs`, `enforce/rules/`, `enforce/tests/`, `enforce/README.md`, `enforce/judge-prompt.md`.
   - **Tier B, canonical docs and skills:** `PROTOCOL.md`, `README.md`, `SETUP.md`, `prompts/`, `audits/*.md` (role definitions), `skills/*/SKILL.md`.
   - **Tier C, memory:** the 7 `global-memory/` files with live rule citations.
   - **Tier D, project trees:** update only living rule-citing config (`personal/.claude/CLAUDE.md`, per-project `CLAUDE.md` files). Historical audit/PR/spec/plan docs are left untouched; the alias table covers them.
4. Commits on the branch: (1) spec; (2) rewritten rule files plus Tier A/B migration plus PROTOCOL appendices, atomic; (3) Tier C/D updates. Squash-merge to `main` only with explicit user authorization; R-108 pre-push checks before any push (public remote).

### 5. Validation gates (all must pass before merge)

1. Regenerated association map shows zero references to any old ID outside historical docs (Tier D) and the alias table.
2. Every ID cited anywhere resolves to a rule that exists in the rewritten files; every manifest entry's ID exists; every rule with `Enforcement: hook:*|eslint:*|judge` has a manifest entry (R-518 closure).
3. `enforce/` fixture tests pass; `hooks/tests/` pass.
4. Hook smoke test: em-dash hook, secret-scan, and structure-gate each fire on a synthetic violation (temp paths only, per R-111).
5. Fresh-session check: `enforcement-guard-check.sh` and `redaction-guard-check.sh` report clean.
6. Diff review confirms no norm was semantically altered: rule-by-rule old-vs-new comparison in the PR doc.

### 6. Hook conversions: PR 2 (separate, after PR 1 soaks)

Rules that are honor-system today but mechanizable. Each conversion adds a manifest entry and fixture test per R-518. Scoped per one-PR-one-scope; lands only after the renumber is verified stable.

| Rule (old ID) | Conversion |
|---|---|
| R-111 | Extend `secret-scan.sh` to block `>`, `>>`, `rm`, `mv`, `cp` targeting the protected-path list |
| R-204 / R-510 | PreToolUse hook on `git commit`: subject/ID format, one-sentence body |
| R-229 | Extend `structure-gate.sh` with an abbreviated-directory denylist (`db/`, `di/`, `utils/`, ...) |
| R-219 | ESLint `no-magic-numbers`, scoped with the rule's exemptions |
| R-515 | Pre-push: diff constants files, grep tests for removed values |

Candidates evaluated and left manual: R-212 (squash-merge discipline; merge intent is not reliably detectable at the tool layer), R-009/R-008 (prose style; judge tier at best, deferred).

## Risks and mitigations

- **A missed live reference silently disables enforcement.** Mitigated by map-driven migration, gate 1 (zero stale IDs), gate 2 (bidirectional ID-manifest closure), and gates 3 to 5 (tests, smoke, session guards).
- **ID collision mid-rename** (old R-301 exists while R-224 becomes R-301). Mitigated by two-phase rename through temp tokens.
- **Semantic drift while reformatting prose.** Mitigated by the rule-by-rule old-vs-new comparison (gate 6) and the no-semantic-change non-goal.
- **Old IDs in memory tags and historical docs become unreadable.** Mitigated by the permanent alias table in PROTOCOL.md.
- **Public remote.** No push without R-108 checks and explicit user authorization (R-516).
