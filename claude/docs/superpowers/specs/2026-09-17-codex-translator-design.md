# Codex translator

## Goal

Resurrect the port pipeline the 2026-09-12 monorepo migration deferred: a checked-in generator that regenerates `codex/`'s generated files from their `claude/` sources, so the "GENERATED" headers become true again, `PORT-STATUS.md` stops lying about hook counts (42 claimed, 49 real), and a `claude/` edit can never again leave the Codex port silently stale. Closes the 2026-09-17 hygiene-audit P2 in `claude/ISSUES.md` ("resurrect-versus-retire") on the resurrect side.

## Inputs

- `claude/CLAUDE.md` and `claude/rules/session-types.md` (markdown; the rule corpus and session table).
- `claude/agents/*.md` (YAML frontmatter + markdown body).
- `claude/skills/*/SKILL.md` (YAML frontmatter + markdown body).
- `claude/settings.json` (the `hooks` object: event -> matcher groups -> command hooks).
- `translate/codex-port-map.json` (new, checked in): for each Claude Code hook event, the Codex event it ports to or `null`; per-hook overrides; the list of hand-authored `codex/` files. The single authority on "what ports".
- CLI: `node translate/codex.mjs --write | --check` (exactly one mode required).

## Outputs

- `--write` regenerates in place: `codex/AGENTS.md`, `codex/agents/*.toml`, `codex/skills/*/SKILL.md`, `codex/hooks.json`, `codex/PORT-STATUS.md`, `codex/.gitignore` (the allowlist of tracked paths), and `codex/.claude-port.json` (manifest: builder name, per-file sha256, source path or `hand-authored`). Every generated file opens with a header naming `translate/codex.mjs` and its source path. Exit 0.
- `--check` writes nothing; exit 0 when every generated file matches what `--write` would produce and every registered hook is classified in the port map; otherwise exit 1 listing each stale or unclassified item, one per line.

## Acceptance criteria

- B-1: `codex.mjs --write` renders `codex/AGENTS.md` from `CLAUDE.md` plus `rules/session-types.md` with the Codex preamble prepended, and rewrites the enforcer tag of every rule whose hook the port map marks unported to `hook:<name> in Claude Code; manual in Codex`, leaving ported hooks' tags unchanged.
- B-2: `--write` renders each `claude/agents/<name>.md` to `codex/agents/<name>.toml` carrying `name`, `description` (frontmatter), and the body as `developer_instructions`; `tools` and `model` do not appear in the TOML.
- B-3: `--write` renders each `claude/agents/audit-*.md` additionally to `codex/skills/audit-*/SKILL.md`, and each `claude/skills/<name>/SKILL.md` to `codex/skills/<name>/SKILL.md` as a verbatim copy with the GENERATED header inserted immediately after the frontmatter block.
- B-4: `--write` renders `codex/hooks.json` from `claude/settings.json`: for each event the port map translates, the adapter invocation lists exactly the hooks registered under that event whose map entry ports, in `settings.json` order; unported hooks appear nowhere in `hooks.json`.
- B-5: `--write` renders `codex/PORT-STATUS.md` with one row per hook registration in `settings.json` and a derived ported/unported count line; no count in the file is hand-typed.
- B-6: `--write` writes `codex/.claude-port.json` listing every generated file with its sha256 and source, and every hand-authored file from the port map marked `hand-authored` with no hash requirement.
- B-7: `--check` exits 0 on a tree where `--write` would change nothing, and exits 1 naming the file when any generated file's content differs from what `--write` would produce.
- B-8: `--check` exits 1 naming the hook when `settings.json` registers a hook that has neither a port-map event translation nor a per-hook override (a new hook cannot silently vanish from the port).
- B-9: `--check` exits 1 naming the file when a hand-authored file listed in the port map is absent; it never diffs hand-authored content.
- B-10: Running with no mode, both modes, or an unknown flag prints usage and exits 2 without touching any file.
- B-11: `--write` renders `codex/.gitignore` from the planned tree: a leading `*`, then one `!/<path>` per generated and hand-authored file plus one `!/<dir>/` per ancestor directory of each, sorted byte-wise. A skill or agent added on the `claude/` side therefore reaches the allowlist with no hand edit, and an allowlist that has fallen behind the tree is a stale file `--check` fails on. Added 2026-09-17, after a new skill was generated, ignored by git, and passed `--check`, which compares content and knows nothing about what git tracks.

## Invariants

- The translator never writes outside `codex/` (and never touches `codex/hooks/codex-hook-adapter.sh`, `codex/README.md`, or any other file the port map marks hand-authored). `codex/.gitignore` was hand-authored until 2026-09-17 and is now generated, because an allowlist that has to be exhaustive to be correct is the wrong shape for a hand-typed file (the same lesson `sync.sh` records about its retired exclude list).
- `--check` never mutates the tree (byte-identical before and after, verified over the whole `codex/` dir).
- `--write` leaves no residue of a deleted source: the orphaned file is unlinked and any directory the deletion empties is removed with it. An emptied directory is invisible to git (which stores no empty directories) and to `--check` (which compares files), so nothing else would ever surface it.
- Output is deterministic: two consecutive `--write` runs produce byte-identical trees (stable ordering, no timestamps).
- `claude/` sources are read-only to the translator.

## Failure modes

- Missing or unparseable source (`settings.json`, a frontmatter block, the port map): exit 2 naming the file and the parse error; no partial write (render everything in memory, write only after all renders succeed).
- A source agent/skill with no frontmatter `name`: exit 2 naming the file.
- Port map references a hook absent from `settings.json`: `--check` warning line, exit unchanged (a retired hook's stale map entry must not block).
- Concurrent second run: last write wins; acceptable for a manually invoked repo tool, stated here so the critic does not report it.

## State transitions

None; the tool is a pure function of the checked-in tree.

## Non-goals

- No cursor target this cycle; the codex module keeps target-specific logic behind one entry point so a `translate/cursor.mjs` can follow, but no shared-framework abstraction is built speculatively.
- No LLM or semantic translation: every transform is mechanical; prose that needs Codex-specific wording lives in template strings or the port map, both checked in.
- No sync-trigger change: `sync.sh` stays a plain copy; the translator is a separate, earlier step.
- No regeneration of `cursor/` content and no deletion of `cursor/`'s stale build artifacts (they stay under the existing ISSUES.md P2).
- No backfill audit of hand-port drift beyond what the first `--write` diff surfaces in review.

## Dependencies

- Node (already required by `enforce/`); no new npm packages: frontmatter parsing is a fenced-block split, TOML emission is template strings (R-331: nothing the existing tree cannot do).
- Reuses `claude/settings.json` as the hook registry (same source `enforce/tests/hook-latency.test.sh` reads).
- CI (`.github/workflows/enforce.yml`) and `claude/hooks/pre-push.sample` gain a `--check` step; `enforce/tests/translate-codex.test.sh` is the fixture.

## Observability

CLI tool, not a service: `--check` failures print one line per stale item (the only interface CI needs); `--write` prints a one-line summary of files written. No logger, no request IDs, no analytics (R-341/R-343 do not apply to a repo script; stated per template).

## Security

Runs locally on the checked-in tree only; no network, no secrets read. Generated output is published with the repo, so headers carry no local filesystem paths (R-106).

## Domain vocabulary

- translator - the `translate/codex.mjs` generator that renders `codex/` from `claude/` - chosen over: "builder" or "build.mjs" because the retired pipeline's name now means the dead artifacts, and over "mirror" because the monorepo spec uses mirror for the OUTPUT tree, not the tool.
- port map - `translate/codex-port-map.json`, the checked-in data naming each hook event's Codex equivalent and the hand-authored file list - chosen over: hardcoding in the translator because `--check`'s B-8 closure guarantee needs the mapping to be data.
- generated file - a `codex/` file the translator owns wholesale; hand edits to it are overwritten by the next `--write` - chosen over: "output" because PORT-STATUS and AGENTS.md are also repo-tracked sources for sync.sh.
- hand-authored file - a `codex/` file the port map exempts from generation (the adapter, the README, the two semantic-render skills); `--check` requires existence only - chosen over: "manual" to avoid colliding with the `[manual]` enforcer tier.
- allowlist - `codex/.gitignore`, which ignores everything under `codex/` and then names every tracked path back in - chosen over: "ignore file", which describes the mechanism and hides the fact that its content is the list of what git keeps, and over "manifest", which is `.claude-port.json`.
