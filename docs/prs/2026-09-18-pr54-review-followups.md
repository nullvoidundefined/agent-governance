# PR #54 review follow-ups: honest fallbacks, per-command notes, private-repo judge fetch

**Ticket:** IAN-98
**Branch:** `fix/pr54-review-followups`

## Summary

PR #54 merged before Copilot's second review (review 5250053833) was addressed. This PR fixes the seven comments from that review. Most of them close cases where the related-test mapping reported success without running any test.

## What changed

- `claude/enforce/related-tests.sh`:
  - A repository with no commit to diff against now takes the full-suite fallback. Before, it returned "nothing changed".
  - Prose and repository metadata (`*.md`, `docs/`, `LICENSE`, `CHANGELOG`, `.gitignore`, `.github/`) are skipped explicitly, so a docs-only change, a doc deletion included, still runs nothing.
  - Every other changed file must now be placed by the stack's mapper, or the mapping falls back:
    - vitest and jest receive every non-inert changed file, stylesheets and assets included, and their import graph decides what is related.
    - pytest falls back on a changed non-Python file, such as a template or data fixture.
    - Go falls back on a changed non-Go file, such as an embedded asset or a `.proto`.
- `claude/hooks/verification-gate.sh` records which commands came from the mapping. Only a failure of one of those commands is labelled "related tests only". A failing `typecheck` beside it is not.
- `.github/workflows/rule-judge.yml` keeps the read-only checkout credentials on the base checkout, so the PR-head fetch works in a private caller repository. The job still never executes code the pull request controls.
- The Go, Python, and Ruby convention files list the CI judge's rules as the manifest's five llm-judge IDs. R-318 and R-322 left that tier on 2026-09-04.

## Decisions

| Decision | Chosen | Alternative | Why |
|---|---|---|---|
| Unmapped non-source files | Fall back to the full suite, except prose and metadata | Fall back on every unmapped file | Falling back on prose too would make every docs-only commit run the full suite, which is the cost IAN-98 removed. No test reads Markdown. |
| Node non-script files | Hand them to `vitest related` or `jest --findRelatedTests` | Fall back | Both runners resolve stylesheets and assets through their own import graph, which is more precise than a full run. |

## Testing

- `related-tests.test.sh` gains M10 to M14: no base commit, an unmapped template, a docs-only change, a stylesheet in a vitest project, and a deleted doc.
- `verification-gate.test.sh` gains invariants 15 and 16. A failing typecheck carries no related-only note, and a failing related-test command does carry it.
- The affected fixtures ran 94 of 105 fixtures, and all passed.

## Reflection

What I understand now: every "success with no output" path in a test selector is a claim that nothing needed testing, and each of those paths has to be justified. Copilot found three unjustified ones (no base commit, unmapped files, deleted files) that my own fixtures did not probe, because I only tested the cases I had designed for.

What I got wrong first: I treated "not source code" as "not testable". A template or a stylesheet can break a test as easily as a module can.
