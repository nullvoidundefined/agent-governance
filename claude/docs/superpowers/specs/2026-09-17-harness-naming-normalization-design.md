# Harness naming normalization

## Goal

Normalize names across skills, hooks, agents, rules, docs, and generated port files so the harness presents a professional and predictable lexicon. Names should describe the capability in plain operational terms. Abbreviations and informal labels such as `gof` or "Gang of Four" should be replaced with descriptive names such as `core-team-audit`.

## Inputs

- Skill directories and frontmatter under `claude/skills/`, `codex/skills/`, and `cursor/skills/`.
- Agent files under `claude/agents/`, `codex/agents/`, and `cursor/agents/`.
- Hook filenames under `claude/hooks/` and generated hook references under `codex/hooks.json` and `cursor/hooks.json`.
- Rule names and enforcer tags in `claude/CLAUDE.md`, `claude/rulebook/*.md`, `claude/enforce/manifest.json`, and `claude/enforce/README.md`.
- README, setup, recipe, and spec references.
- Translator maps that generate Codex or Cursor names.

## Outputs

- A naming lexicon for harness components: approved nouns, suffixes, and rename rules.
- A rename plan for non-professional, abbreviated, or inconsistent names.
- Updated file paths, frontmatter names, references, tests, manifests, port maps, and generated outputs for accepted renames.
- Backward-compatibility notes for old names where user muscle memory or generated ports need a transition.

## Acceptance criteria

- B-1: The audit lists every skill, hook, agent, and generated command name with current name, proposed name, category, and action.
- B-2: `gof` and "Gang of Four" are renamed to `core-team-audit` or another approved descriptive name everywhere: skill directory, frontmatter, README references, generated ports, and docs.
- B-3: Hook suffixes follow a documented convention: blocking hooks use `-guard`, advisory hooks use `-reminder`, check-only hooks use `-check`, generated helpers use a noun phrase without a misleading guard suffix.
- B-4: Audit role names use a consistent `audit-<domain>` pattern, and role descriptions avoid persona titles as primary labels.
- B-5: Skill names use verb-noun or domain-operation names, not metaphors or abbreviations.
- B-6: Rule enforcer tags match actual filenames or documented runtime rule ids.
- B-7: Translator output for Codex and Cursor reflects the renamed skills and agents, or records compatibility aliases explicitly.
- B-8: Tests and manifests fail when a referenced old name remains without an alias entry.
- B-9: README, setup, recipes, and handoff docs use the new names.
- B-10: Renames preserve behavior and are shipped with focused tests or check commands for references.

## Invariants

- A name should tell a new reader what the component does without opening the file.
- Renaming cannot break sync, generated ports, hook registration, or role-policy enforcement.
- Compatibility aliases must be temporary and documented with a removal condition.

## Failure modes

- A rename touches generated files: update the generator or port map first, then regenerate.
- A hook name changes but `settings.json` still references the old path: tests must fail before merge.
- A skill name changes but docs keep the old trigger phrase: reference check must catch it.
- A short old name is widely used in memory or handoffs: add a compatibility note rather than keeping the informal name as canonical.

## State transitions

- Name lifecycle:
  - `current`: canonical name in use.
  - `renaming`: both old and new names may appear with an alias.
  - `canonical`: new name is the only documented name.
  - `retired`: old name removed from files and generated outputs.

## Non-goals

- No behavior changes to hooks, skills, rules, or agents.
- No rule renumbering.
- No rewrite of role content except names, descriptions, and references needed for consistency.
- No broad terminology redesign outside harness component names.

## Dependencies

- Public documentation refresh and recipes should use final names.
- Source-neutral sync and Codex translator checks must account for renamed generated files.
- Existing naming lexicon in `claude/enforce/lexicon.json` may inform but does not automatically govern harness component filenames.

## Observability

- The rename plan is reviewable before changes.
- The final implementation reports old-to-new mappings and check commands run.

## Security

- Renames must not expose local paths or private repo names in generated headers.
- Compatibility aliases must not bypass guards or permissions.

## Domain vocabulary

- harness lexicon - approved names and suffixes for harness components - chosen over: glossary because it also governs renames.
- component name - file, skill, hook, agent, command, or enforcer label used to refer to a harness capability - chosen over: identifier because many names appear in prose and filenames.
- canonical name - the current approved name after a rename decision - chosen over: preferred name because the harness needs one source of truth.
- compatibility alias - temporary reference from an old name to a new name - chosen over: synonym because aliases have removal conditions.
- rename plan - table of current names, proposed names, references, tests, and migration actions - chosen over: find-and-replace because generated outputs and aliases need sequencing.
