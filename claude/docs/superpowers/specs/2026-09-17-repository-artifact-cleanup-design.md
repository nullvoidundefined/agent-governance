# Repository artifact cleanup

## Goal

Audit the repository for superfluous, redundant, stale, generated, or local-session artifacts, then remove or ignore anything that should not ship as part of the public harness. Session handoffs, dated audit outputs, and active design specs should not remain permanent tracked product documentation unless a specific release decision says they are public artifacts.

## Inputs

- Root `.gitignore`.
- `docs/session-handoff/session-handoff.md`.
- `docs/audits/`.
- `claude/docs/superpowers/specs/`.
- `claude/ISSUES.md`, `claude/README.md`, root `README.md`, and any docs linking to those paths.
- Generated manifests such as `.claude-port.json`, `PORT-STATUS.md`, and generated headers under `codex/` and `cursor/`.

## Outputs

- A file-retention audit table classifying each docs and runtime artifact as tracked, ignored, generated, local-only, or delete.
- `.gitignore` updates for session handoffs, local planning specs, generated scratch artifacts, and runtime state that should not ship.
- Removal or relocation plan for stale specs and audit reports.
- README and setup-doc updates so ignored files are not presented as required public reading.
- A migration note for any file currently tracked that becomes ignored; tracked files require explicit `git rm --cached` in the implementation.

## Acceptance criteria

- B-1: The audit lists every file under `docs/`, `claude/docs/`, `codex/`, and `cursor/` that is generated, session-local, stale, or public-facing.
- B-2: `docs/session-handoff/session-handoff.md` becomes ignored after an implementation removes it from git tracking or moves it to a template path.
- B-3: `claude/docs/superpowers/specs/` is either ignored as active planning state or split into tracked design templates plus ignored active specs; the decision is documented.
- B-4: Dated audit reports are either preserved under a public `docs/audits/` policy or moved to ignored local state; the decision names who the reports are for.
- B-5: `.gitignore` distinguishes runtime state, generated outputs, local planning artifacts, and public docs with comments.
- B-6: No linked public README path points at an ignored or removed file unless it points at a template.
- B-7: Generated artifacts that remain tracked have a generator, a `--check` command, and a documented ownership rule.
- B-8: Stale generated artifacts without a live generator are either regenerated, converted to hand-authored files, or removed.
- B-9: The implementation preserves source files needed by hooks, enforcement tests, sync, and translators.
- B-10: The final cleanup commit leaves `git status --ignored --short` understandable: ignored planning/runtime files appear under documented patterns.

## Invariants

- Do not delete source files required by runtime hooks, settings, enforcement tests, sync, or translators.
- Do not remove audit evidence needed for currently open P0/P1 security issues without preserving the actionable issue entry.
- Do not rely on `.gitignore` alone for files already tracked; tracked files must be explicitly removed from the index.

## Failure modes

- A file appears redundant but is loaded by a hook or generated port: keep it and document why.
- A public doc links to an ignored planning file: replace the link with a stable recipe, setup doc, or template.
- A generated file has no generator: classify it as stale and choose regenerate, hand-author, or remove.

## State transitions

- Artifact lifecycle:
  - `public`: tracked and linked as stable documentation.
  - `source`: tracked input to hooks, skills, rules, translators, or tests.
  - `generated`: tracked only when a generator and check exist.
  - `local`: ignored runtime or planning state.
  - `retired`: removed from tracking.

## Non-goals

- No content rewrite beyond link and classification updates.
- No implementation of source-neutral sync.
- No deletion of currently active code, hooks, tests, skills, or rulebook files.
- No purge of git history.

## Dependencies

- Public documentation refresh should land before final link cleanup when possible.
- Source-neutral sync spec may change how generated port artifacts are classified.

## Observability

- The audit table is the primary review artifact.
- Cleanup commit reports removed, ignored, and retained counts.

## Security

- Treat every tracked artifact as public.
- Before removing security-related audit files, confirm their actionable items live in `ISSUES.md` or another retained issue tracker.

## Domain vocabulary

- public artifact - tracked file intended for external readers - chosen over: doc because code and generated manifests can also be public.
- local artifact - ignored file useful only for the operator's current machine or session - chosen over: scratch because some local artifacts are important but not publishable.
- generated artifact - file produced by a checked-in generator and verified by a check command - chosen over: build output because some generated files are source-adjacent configuration.
- retired artifact - file removed from tracking because it is stale, redundant, or no longer needed - chosen over: deleted file because the decision is lifecycle-based.
- retention audit - table classifying files by lifecycle and action - chosen over: cleanup list because each row needs evidence.
