# Slice 02: Application Baseline Rules

Spec: `claude/docs/superpowers/specs/2026-09-17-application-baseline-design.md`
Branch: `feat/python-vue-conventions` (shared slice branch; each PR branches from it and squash-merges back)
Status: awaiting spec review, then Gate 1
Tracker: Linear project Agent Governance, slice ticket IAN-74, one child ticket per PR
Starts after: slice 01 PR 7 merges

## Purpose

Every application build must carry four test levels, tracing on top of the existing observability rules, and, when it contains an agent or an LLM call, an eval harness. This slice adds the rules, makes the spec template demand the sections, extends the hook that reminds on a thin spec, and points the build skills at the baseline. It also folds in two tracker items this session surfaced: Linear as a provider in the ticket-lifecycle skill and the one-project-per-repository rule.

## Execution record

| PR | Concern | Share | PR number | Merged | Scope change |
|---|---|---|---|---|---|
| 1 | Rulebook and norm lines: R-347, R-413, R-421 to R-426, plus the R-907 model-line fix | 36% | | | |
| 2 | Spec template headings and `spec-glossary-check.sh` extension | 31% | | | |
| 3 | Skill pointers, ticket-lifecycle Linear row, repo-setup skill, README, sync, hashes, handoff | 23% | | | Adds the Linear provider row, the project-per-repository rule, and a new `repo-setup` skill (repo creation, branch protection with required checks and squash-only, the Copilot auto-review ruleset, Dependabot, CI and Docker scaffolds, the Linear project), raised 2026-09-17 during slice 01 |
| 4 | R-333 function comment blocks: rule, shell-side hook, fixture | 10% | | | Added 2026-09-17: every function carries a comment block, mandatory in shell |

Later list (deferred, not in this slice): judge calibration tooling; `observability-reminder.sh` span detection; the reference `evals/` runner (template workstream).

## PR 1: Rulebook and norm lines

**Context:** Slice 01 has merged and synced. The rulebook carries observability rules R-341 to R-346 and testing rules R-401 to R-412. No rule names the four test levels, no rule covers tracing, and no rule mentions evals, judges, datasets, or trajectories. The spec for this slice fixes the text of eight rules.

**Problem:** The template workstream's spec is written next, and it must cite rules for its Testing, Observability, and Evals sections. Without rule IDs, those sections would restate portfolio-level project instructions that carry no enforcer and no Spec block.

**Approach:** Add the eight rules exactly as the spec's Design section 1 words them. Each rule gets a one-line norm in `claude/CLAUDE.md` with its enforcer bracket, and a Spec block in `claude/rulebook/reference.md` with Scope and Enforcement lines, matching the format of the neighboring rules.

R-347 joins the R-34x observability block. R-413 follows R-412 in testing. R-421 to R-426 open an agent-evals sub-block inside testing with a two-line preface stating that the block applies to any application making an LLM call. Manifest entries are added for R-413 and R-422 only, both on `hook:spec-glossary-check` at the advisory tier, because PR 2 makes that hook enforce their spec sections; the other six are manual and carry no entry.

**Contents:** `claude/CLAUDE.md` (eight norm lines); `claude/rulebook/reference.md` (eight Spec blocks, about 90 lines); `claude/enforce/manifest.json` (two entries); `claude/rulebook/cost.md` R-907 model line corrected: `gpt-5.1-codex-mini` is rejected on a ChatGPT-login Codex account, so routine test authoring omits `-m` and takes the account default (found 2026-09-17).

**Tests:** `manifest.test.sh` (closure: every rule citing a hook enforcer has an entry, the hook script exists). `claude-md-lint.test.sh` (norm line shape). `convention-rules.test.sh` where it asserts rule-ID cross-references. All three green; cites B-1 and B-2.

**Review focus:** R-423 and R-425, because they change how CI behaves for every agentic project: the cross-provider gating judge and the no-worse-than-baseline gate. Confirm each rule's Enforcement line says `manual` where no hook exists rather than implying one.

**Size:** 3 files, about 120 lines.

## PR 2: Spec template headings and hook extension

**Context:** PR 1 has landed. `prompts/spec-template.md` carries twelve headings including `## Observability` but no `## Testing` or `## Evals`. `hooks/spec-glossary-check.sh` fires on every Write to `docs/superpowers/specs/*-design.md` and reminds when Domain vocabulary, Acceptance criteria, or Non-goals is missing; it never blocks and exits 0 on any fault.

**Problem:** A spec written without a Testing or Evals section is the point where the baseline is lost, and today nothing notices. The hook is the one mechanism that already reads every spec at write time.

**Approach:** Two headings join the template after `## Dependencies`: `## Testing` (one paragraph per level naming runner, CI job, and the acceptance criteria it proves) and `## Evals` (dataset path, cases per level, gating and advisory judges with providers, gate definition; present when the feature makes an LLM call).

The hook's jq program gains two checks in the same advisory shape. Testing is required on every design spec and its body must contain `unit`, `integration`, `end-to-end` or `e2e`, and `smoke`; the reminder names the missing words. Evals is required when the spec content matches, case-insensitively, `agent`, `LLM`, `language model`, `prompt`, `LangGraph`, `tool call`, or `model call`; the reminder names the trigger word. The R-330 manifest note is updated to list the five sections.

**Contents:** `claude/prompts/spec-template.md`; `claude/hooks/spec-glossary-check.sh`; `claude/hooks/tests/spec-glossary-check.test.sh` (five new cases); `claude/enforce/manifest.json` (R-330 note).

**Tests:** B-3 no Testing section reminds naming it; B-4 Testing with three of four levels reminds naming end-to-end; B-5 a spec containing "agent" with no Evals reminds naming the trigger word; B-6 a spec with no trigger word and no Evals is silent; B-7 a complete agentic spec is silent. Existing three cases unchanged. `hooks/tests/run-tests.sh` green (B-9).

**Review focus:** The jq regex for the trigger words (false positives on "prompt" in the permission-prompt sense are accepted and documented in the spec's Risks) and that the hook still exits 0 on malformed input, since a hook fault must never break a Write.

**Size:** 4 files, about 90 lines.

## PR 3: Skill pointers, ticket-lifecycle Linear row, README, sync, hashes, handoff

**Context:** PRs 1 and 2 have landed. The build skills (task-start, feature-create, build-by-slice-require-review) do not mention the baseline. The ticket-lifecycle skill's provider table lists Jira, Notion, and Asana, and this session configured Linear through the template's generic tool map with four labels standing in for missing states.

**Problem:** A session that starts from a build skill never reaches the baseline unless the skill points at it. A session that opens a ticket on Linear has no provider row to follow and no rule saying a new repository gets a Linear project.

**Approach:** One pointer sentence per build skill, no rationale: task-start's Complex and Saga process blocks name the three spec sections and their rules; feature-create gains a scaffold step creating `evals/datasets/` with a `.gitkeep` when the plan names an agent or LLM call; build-by-slice's hard first step names the Testing, Observability, and Evals sections and requires an agentic slice plan to include the evals PR.

The ticket-lifecycle skill gains a Linear column in its provider mapping table (create and update through `save_issue`, comment through `save_comment`, search through `list_issues`, read through `get_issue`, labels through `save_issue_label`, project through `save_project`), a `state_labels` config key for canonical states the provider's workflow lacks, and a rule under Operation open: one tracker project per repository, created when the repository is created. The template config gains a `linear` block mirroring `~/.claude/TICKET-TRACKER.json` with identifiers blanked.

Then the closing ceremony: README convention-files and skills tables, `sync.sh`, `hook-integrity-check.sh --update`, handoff, this execution record.

**Contents:** `claude/skills/task-start/SKILL.md`; `claude/skills/feature-create/SKILL.md`; `claude/skills/build-by-slice-require-review/SKILL.md`; `claude/skills/ticket-lifecycle/SKILL.md`; `claude/TICKET-TRACKER.template.json`; `README.md`; `claude/enforce/hook-hashes.txt`; `docs/session-handoff/session-handoff.md`; this file. The codex port of each changed skill is regenerated by the translator (`translate/codex.mjs --check` must exit 0).

**Tests:** B-8 as a grep assertion on the three pointer sentences, added to `convention-rules.test.sh`. `translate-codex.test.sh` green after re-cloning the ports. B-9 both suites green. B-10 no integrity drift after sync. `git diff origin/main` reviewed for secrets, local paths, and client content before push (R-106).

**Review focus:** The `git diff origin/main` output, since this push publishes the slice, and the ticket-lifecycle table row, since the Linear identifiers in the live config must not leak into the template.

**Size:** 9 files, about 120 lines.

## PR 4: R-333 function comment blocks

**Context:** PRs 1 to 3 have landed. The owner set a standing rule on 2026-09-17: every function carries a comment block saying what it does, mandatory in shell scripts, and in every other language except a function whose name and signature already say everything. R-320 covers file headers only; nothing covers functions.

**Problem:** Shell has no types, signatures, or return values beyond an exit code, so a function's contract lives nowhere unless a comment carries it. The shell half of the rule is mechanizable (a comment line immediately above every `name() {` or `function name`), so it should not depend on recall.

**Approach:** One rule, R-333, in the R-3xx block: a norm line in `claude/CLAUDE.md`, a Spec block in `claude/rulebook/reference.md` stating the shell mandate and the other-language exemption for trivially self-explanatory functions, enforcement `hook:function-comment-reminder` for shell (advisory) and the judge for the rest.

The hook is a PostToolUse reminder on Write and Edit of `*.sh` files: it lists every function definition whose preceding non-blank line is not a comment and reminds naming them. Advisory, never blocking, exits 0 on any fault, matching `new-file-header-reminder.sh`. The codex test-author prompt in tdd-gated-dispatch gains the requirement so dispatched tests comply from the first draft.

**Contents:** `claude/CLAUDE.md`; `claude/rulebook/reference.md`; `claude/hooks/function-comment-reminder.sh`; `claude/hooks/tests/function-comment-reminder.test.sh`; `claude/enforce/manifest.json`; `claude/skills/tdd-gated-dispatch/SKILL.md` (one line in the test author prompt); `claude/enforce/hook-hashes.txt`.

**Tests:** Fixture: a shell file with one commented and one uncommented function reminds naming only the uncommented one; a fully commented file is silent; a non-shell file is silent; malformed hook input exits 0. `manifest.test.sh` and `hook-hashes-closure.test.sh` green.

**Review focus:** The function-definition regex (both `name()` and `function name` forms) and that the reminder never fires on a heredoc line that happens to look like a definition.

**Size:** 7 files, about 120 lines.

## Gate rules for this slice

- Spec review precedes Gate 1: the owner reviews the slice 02 spec, then this document.
- Gate 1: this document approved by the owner before PR 1 starts.
- Gate 2: each PR approved on GitHub before merge. Squash merge, branch deleted, landing verified with `git log`.
- No PR starts before the previous one is merged, and PR 1 does not start before slice 01 PR 7 has merged and synced.
- New ideas go to the Later list above.
- Time estimate for the executor, divided per R-906: about 30 minutes each for PRs 1 and 2, about 50 minutes for PR 3 (the repo-setup skill added), about 25 minutes for PR 4, plus review wait at each gate.
