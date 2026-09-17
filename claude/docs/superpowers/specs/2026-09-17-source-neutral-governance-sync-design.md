# Source-neutral governance sync

## Goal

Replace the implicit "Claude is the eldest sibling" model with a source-neutral propagation system for the `agent-governance` monorepo. Any supported surface folder (`claude/`, `codex/`, or `cursor/`) can be the place where an operator makes an intentional edit. The propagation tool imports that edited surface into a neutral governance model, validates what was learned, and exports the result to every sibling surface that can represent it. The existing `translate/codex.mjs` proves the render/check pattern, but its one-way `claude/` to `codex/` source assumption becomes a migration target, not the long-term architecture.

## Inputs

- Surface folders: `claude/`, `codex/`, and `cursor/`.
- Current translator code under `translate/`, including `codex.mjs`, `parse-sources.mjs`, `render-codex-*.mjs`, `build-manifest.mjs`, and `codex-port-map.json`.
- Surface docs and drift records: `codex/README.md`, `cursor/README.md`, `codex/PORT-STATUS.md`, `cursor/PORT-STATUS.md`, `.claude-port.json` files, and generated headers.
- Global rule sources and conventions: `claude/CLAUDE.md`, `claude/rules/session-types.md`, `claude/rulebook/*.md`, stack convention files, `claude/agents/*.md`, and `claude/skills/*/SKILL.md`.
- Runtime install sync: `sync.sh`, which currently copies tracked files from each surface to `~/.claude`, `~/.codex`, and `~/.cursor`.
- CLI command shape for the new tool: `node translate/governance-sync.mjs --from <surface> --write|--check [--root <repo>]`.

## Outputs

- A neutral model directory under `translate/model/` or an equivalent checked-in schema module that describes the governance concepts independent of any one tool: rules, sessions, hooks, permissions, agents, skills, generated ownership, hand-authored files, and portability gaps.
- Per-surface adapters:
  - import adapters that read a surface folder into the neutral model.
  - export adapters that render the neutral model back into that surface folder.
- A source-neutral CLI, `translate/governance-sync.mjs`, that can import from `claude`, `codex`, or `cursor` when that surface has an importer, then export to every sibling with an exporter.
- Updated manifests for generated ownership and unrepresentable concepts, replacing `.claude-port.json`'s Claude-named vocabulary with source-neutral terms.
- Updated `README.md`, `claude/README.md`, `codex/README.md`, and `cursor/README.md` explaining that no folder is canonical by identity; the last intentional import surface is the input, and the neutral model is the exchange contract.

## Acceptance criteria

- B-1: `governance-sync.mjs --from claude --check` exits 0 on a tree where exporting from the neutral model would not change `codex/` or `cursor/`; it exits 1 naming each stale sibling file when either sibling is behind.
- B-2: `governance-sync.mjs --from claude --write` imports supported concepts from `claude/`, exports generated Codex files with byte-identical output to the existing `translate/codex.mjs --write` for the same inputs, and reports any Cursor concepts that still lack an exporter.
- B-3: `governance-sync.mjs --from codex --check` imports supported concepts from Codex-native files (`AGENTS.md`, agent TOMLs, generated skill copies, `hooks.json`, and `PORT-STATUS.md` where applicable) and exits 1 when exporting them would change `claude/` or `cursor/`.
- B-4: `governance-sync.mjs --from codex --write` can propagate an intentional edit made in a Codex-owned, importable file back to `claude/` and then forward to `cursor/`, without requiring a manual edit in `claude/` first.
- B-5: `governance-sync.mjs --from cursor --check` imports every Cursor concept that has a declared importer and reports unsupported Cursor-only or stale generated artifacts as named gaps, not as silent success.
- B-6: Generated files carry source-neutral headers naming the generating tool and the neutral concept they came from, not "generated from claude" unless the immediate source really was a Claude-only file.
- B-7: A generated file edited directly in any surface is refused unless the surface's import adapter declares that file importable; the refusal names the owning neutral concept and the correct edit surface or command.
- B-8: Hand-authored files remain editable in their owning surface and are copied to siblings only when a declared adapter maps that concept. Files with no mapping remain local and are listed in that surface's manifest as local-only.
- B-9: The source-neutral manifest records, for each surface file, one of: generated, importable, hand-authored local, hand-authored mapped, runtime-only ignored, or unsupported. `--check` fails when a tracked file lacks a classification.
- B-10: The tool detects conflicting sibling edits: if two surfaces changed the same neutral concept since the last successful propagation, `--write` refuses and prints both file paths plus the concept id.
- B-11: The tool is deterministic: two consecutive `--write` runs from the same surface produce no diff after the first run, and no output includes timestamps, hostnames, or absolute home paths.
- B-12: The old `translate/codex.mjs --check` either delegates to `governance-sync.mjs --from claude --check` or remains as a compatibility wrapper with a deprecation notice once source-neutral parity exists.
- B-13: CI and pre-push run the source-neutral check, not only the Claude-to-Codex check, once Codex parity is preserved and Cursor has at least a gap-reporting importer.
- B-14: The docs stop describing `claude/` as the source of truth for Codex or Cursor. They may still say Claude Code has the richest native runtime and therefore the most complete exporter until sibling parity catches up.

## Invariants

- No surface folder is canonical by identity. Canonicality belongs to the validated neutral model produced by the current import operation.
- The system never attempts lossy reverse translation silently. If a surface representation cannot reconstruct the neutral concept, the importer reports the gap and refuses to claim parity.
- A surface-specific runtime feature may remain local to that surface, but it must be marked local-only in the manifest and in generated port status.
- `sync.sh` remains an install step from repo folders to live config directories. It does not infer edits from `~/.claude`, `~/.codex`, or `~/.cursor`, and it does not become the propagation engine.
- Generated-file ownership is explicit per file and per neutral concept; no file is both freely hand-edited and silently overwritten.

## Failure modes

- Importer cannot parse a surface file: exit 2, name the file, leave every sibling untouched.
- Importer parses a file but cannot map it to a neutral concept: exit 1 in `--check`, refuse `--write`, and print the unsupported path plus the adapter that needs to be written.
- Two sibling surfaces changed the same neutral concept: exit 1, name both surfaces, both paths, and the last successful propagation manifest entry used for comparison.
- A sibling exporter cannot represent a neutral concept: complete no writes for that sibling, mark the concept as unrepresentable, and require an explicit manifest entry before `--check` can pass.
- A stale generated file exists whose source concept no longer exists: `--check` fails with `orphaned`, and `--write` removes it only when the manifest proves the file is generated and not hand-authored.
- Cursor's old `GENERATED by cursor/build.mjs` files remain before a Cursor exporter exists: classify them as stale legacy generated files and fail only the Cursor parity slice, not the Claude-to-Codex compatibility slice.

## State transitions

- Neutral concept lifecycle:
  - `unseen`: no manifest entry exists.
  - `imported`: an importer read the concept from one surface.
  - `validated`: the concept satisfies the neutral schema and conflict checks.
  - `exported`: every representable sibling received the rendered output.
  - `gapped`: at least one sibling cannot represent the concept and has a recorded gap.
  - `conflicted`: two or more surfaces changed the same concept since the last successful propagation.
- Surface parity lifecycle:
  - `legacy`: surface contains stale generated or hand-ported files from an old pipeline.
  - `import-only`: surface can be read into the neutral model but not rendered fully.
  - `export-only`: surface can be rendered from the neutral model but edits there do not round-trip.
  - `round-trip`: supported concepts can be edited there, imported, and re-exported to siblings.

## Non-goals

- No automatic import from live runtime directories. Operators edit the monorepo folders, not `~/.claude`, `~/.codex`, or `~/.cursor`.
- No semantic LLM translation of rules, hooks, or agent instructions. Every adapter is deterministic code plus explicit mapping data.
- No claim that every concept is equally representable in every tool. The matrix must preserve asymmetry honestly.
- No deletion of hand-authored sibling files unless their manifest classification says generated and the owning concept disappeared.
- No immediate removal of `translate/codex.mjs`; it stays until the source-neutral CLI proves byte-identical Codex output from a Claude import.
- No general-purpose config sync product. This is for the `agent-governance` surfaces and their known file formats.

## Dependencies

- Existing Codex translator behavior and tests become the compatibility baseline for the Claude-import to Codex-export path.
- New fixture tests under `claude/enforce/tests/` or `translate/tests/` must cover at least:
  - Claude import to Codex export byte parity.
  - Codex import back to Claude for one rule, one agent, one skill, and one hook mapping.
  - Cursor legacy gap reporting.
  - generated-file direct edit refusal.
  - sibling conflict detection.
  - manifest classification closure.
- No new npm package unless R-331 is satisfied. Prefer structured parsers already present or small local parsers for the known markdown, TOML, JSON, and MDC shapes.
- The public-hardening capability matrix spec may share vocabulary with this spec, but source-neutral sync owns file propagation and generated artifact classification.

## Observability

- `--check` prints one line per stale file, unsupported concept, conflict, orphan, missing manifest classification, or unrepresentable export.
- `--write` prints one summary line per sibling: imported concepts, written files, removed generated orphans, local-only concepts, and gaps.
- Port status files are generated from the same neutral manifest and no longer hand-type hook counts.
- The session handoff should mention the last successful source surface and command when this tool writes siblings.

## Security

- The propagation tool reads only tracked repo files under the chosen repo root and writes only under sibling surface folders. It never reads live credential files or runtime state.
- Generated output must not include local filesystem paths, usernames, hostnames, secret values, or client-identifying remote URLs.
- If a surface file contains a secret-shaped value, the importer refuses before writing any sibling and names only the path and redacted match category.
- The tool must not make destructive live-directory changes; `sync.sh` remains responsible for installing tracked repo content into live config directories.

## Domain vocabulary

- surface - one tool-specific folder in the monorepo, currently `claude/`, `codex/`, or `cursor/` - chosen over: "target" because the same folder can be the edit input or an export output.
- sibling - any other surface beside the imported surface - chosen over: "child" because no folder is eldest or subordinate.
- neutral model - the tool-agnostic representation of governance concepts produced by an importer and consumed by exporters - chosen over: "canonical source" because it is derived and validated, not hand-edited directly.
- importer - adapter code that reads one surface into the neutral model - chosen over: "parser" because it also classifies ownership and representability.
- exporter - adapter code that renders the neutral model into one surface - chosen over: "translator" because translation is no longer one source to one target.
- concept id - stable identifier for one governance object, such as a rule, hook registration, permission pattern, agent, skill, or convention file - chosen over: "file id" because one concept can render to multiple files.
- local-only - a concept or file intentionally owned by exactly one surface with no sibling representation - chosen over: "unsupported" because local-only can be deliberate and healthy.
- unrepresentable - a validated concept that a sibling surface cannot express with its current runtime or adapter - chosen over: "missing" because the absence may be a runtime limitation rather than unfinished work.
- propagation - import from one surface into the neutral model followed by export to siblings - chosen over: "sync" because `sync.sh` already means repo-to-live-directory copy.
