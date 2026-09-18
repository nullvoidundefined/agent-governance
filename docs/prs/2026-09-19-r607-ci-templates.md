# PR: repo-setup CI templates run the R-607 feature checklist

Ticket: IAN-117. Branch: `fix/r607-ci-templates`.

## Summary

The repo-setup skill copies `scripts/require-feature-checklist.sh` into every application repository so that the repository's own CI can run the R-607 product-docs check, but none of the four CI workflow templates it writes (`template-ci-node.yml`, `template-ci-python.yml`, `template-ci-go.yml`, `template-ci-ruby.yml`) actually ran that script. A repository set up from these templates therefore had the script on disk and never executed it. This PR adds one identical checklist step to all four templates, so a pull request that adds a user-facing route without the features list, a user story, and an e2e spec now fails the required `ci` check.

## What changed

- Each template's `actions/checkout@v4` step now sets `fetch-depth: 0`. The checklist diffs the branch against the merge base with the pull request's base branch, and the default shallow clone has neither the base branch ref nor the merge base, in which case the script exits 0 and checks nothing.
- Each template gains a step named `R-607 feature checklist`, right after checkout so it fails before any dependency install. It runs only on `pull_request` events and passes the base as `FEATURE_CHECKLIST_BASE: origin/${{ github.base_ref }}`, which the script already reads.
- The step runs `bash scripts/require-feature-checklist.sh` when the script exists. When it does not, the step passes only if `.enforce.json` sets `productDocs` to `false` (the opt-out `--no-product-docs` records, in which case repo-setup writes no script); otherwise it fails with a message naming the two ways to fix it.
- `claude/skills/repo-setup/SKILL.md` describes the new step in the `ci` item row.
- `claude/enforce/tests/repo-setup.test.sh` gains section 12, which checks each template for the step, the full-history checkout, the pull-request gate, and the base-ref variable, then extracts the step's `run` block and executes it in three sandbox repositories.
- The hash manifest and the Codex and Cursor ports are regenerated.

## Architectural decisions

- **The step runs only on pull requests.** The alternative was to run it on every event the workflow handles. On a push to `main` the script exits 0 by design, and on a push to `staging` it would diff `staging` against `main` and could fail a branch that was already reviewed through its own pull request. The pull request is where the branch-level question R-607 asks is meaningful.
- **The base ref is passed through the environment, not interpolated into the script.** Writing `${{ github.base_ref }}` inside `run:` would splice a branch name into shell source, which is the standard GitHub Actions script-injection shape. The script already honours `FEATURE_CHECKLIST_BASE`, so the environment variable carries the value as data.
- **A missing script fails closed unless the repository opted out.** The alternative, skipping whenever the script is absent, would let a repository silently lose the check by deleting one file. The opt-out is already recorded as data in `.enforce.json`, and the script itself reads the same key, so the step honours exactly the opt-out the script does and nothing else. `jq` is preinstalled on GitHub's Ubuntu runners.
- **The step is byte-identical across the four templates.** The checklist is stack-independent shell, so it needs no per-stack setup, and one shape lets the fixture extract and execute the same block from every template.

## Testing

- Red first: with the four templates unchanged, section 12 reported 28 failures, beginning with `FAIL: IAN-117 node template has the checklist step`, while the four opt-out cases passed trivially because an empty step exits 0. Every earlier case in the fixture still passed.
- Green after the change: `repo-setup.test.sh PASS`. The executed step fails a branch that adds `app/pages/trips.vue` with no docs (exit 1), passes an opted-out repository with no script (exit 0), and fails a repository whose script is missing without an opt-out (exit 1), for each of the four templates.
- All four templates parse as YAML. The full enforce suite and the full hooks suite pass, `shellcheck --severity=error` is clean, and both port `--check` runs are clean after `--write`.

## Reflection

The first version of the fix in my head was a single `run: bash scripts/require-feature-checklist.sh` line, and it would have passed a content check while doing nothing in real CI, because the script exits 0 when it cannot find a merge base and `actions/checkout` clones one commit by default. Executing the extracted step against real repositories in the fixture is what makes the test fail when the implementation is wrong, rather than when a string is missing. The fixture still cannot prove the GitHub-side behaviour (the `fetch-depth` and `github.base_ref` wiring); those are asserted as text, and the first product repository set up after this merge is where they get exercised for real.
