# Shard the fixture suites and run only affected fixtures at turn end

## Summary

The R-509 Stop gate ran both fixture suites in full, one fixture after another, at the end of every turn that left the tree dirty or carried unpushed commits, and the pre-push hook ran them again. Timed one at a time, the 101 fixtures take 276 seconds. Five of them account for 107 of those seconds, and 85 take under five seconds each. This PR adds one shared runner that runs a fixture tree in parallel and, in its affected mode, chooses which fixtures a turn's changes need. The Stop gate uses the affected mode; pre-push and CI keep the full suite, now in parallel. R-509 and the stack convention files now say that sharded runs are the default everywhere, and that the full suite belongs to the push boundary.

The decisions behind the design were the maintainer's, taken one at a time:
- The full suite runs at pre-push and in CI, where it is already the required check before merging to `main`.
- A change the selector cannot place runs the full suite rather than nothing.
- Branch-level merges (such as `main` into a feature branch) run only the affected tests.
- Every turn runs the fast tier in full, and slow fixtures only when a change names them.

## What changed

- `claude/enforce/run-fixture-shards.sh` (new):
  - `--all` runs every fixture in a tree through `xargs -P`, capped at `min(CPU count, 8)` jobs. It then waits a 5-second settle pause and runs each `# Shard: serial` fixture alone.
  - `--affected` always runs the fast tier. It adds a `# Shard: slow` fixture when that fixture's text names a changed file (the path under `claude/`, or the basename), or when the fixture itself changed. It runs everything when a changed file is named by no fixture in either tree, or is one of the runner's shared files.
  - Changed files come from `git`: the working tree plus the commits since the upstream, since the merge base with `origin/main`, or since the root commit, whichever applies first.
  - The pass verdict is the old runners' (exit 0, a PASS line, no FAIL line), and output is printed in name order.
- `claude/enforce/tests/run-tests.sh` and `claude/hooks/tests/run-tests.sh` delegate to the runner. With no argument they run everything, which is how pre-push, CI, and `doctor.sh` call them; `--affected` passes through.
- `claude/hooks/verification-gate.sh` calls both suites with `--affected` in this repo.
- Headers: 16 fixtures that took over five seconds carry `# Shard: slow`, and `hook-latency.test.sh` carries `# Shard: serial`.
- Tests:
  - `claude/enforce/tests/run-fixture-shards.test.sh` (new) covers full mode, serial ordering, the settle pause, affected selection, both fallbacks, changed files derived from git, the three verdict rules, and real concurrency, with a single-job control run.
  - `verification-gate.test.sh` gains a case requiring `--affected` on both suites.
  - `enforce-deps-guard.test.sh` copies the runner into its sandbox, because `run-tests.sh` now needs it.
- R-509's norm line in `claude/CLAUDE.md` and its Spec in `claude/rulebook/reference.md` state the default-to-parallel, affected-below-the-push-boundary rule, and the numbers for this repo.
- The stack convention files carry the per-stack commands:
  - `CLAUDE-BACKEND.md`: Vitest `--changed`, `vitest related`, and `--shard` with the blob reporter.
  - `CLAUDE-FRONTEND.md`: Playwright `fullyParallel`, `--only-changed`, and `--shard`.
  - `CLAUDE-PYTHON.md`: `pytest -n auto` with `--dist loadfile`, and `pytest-testmon`.
  - `CLAUDE-GO.md`: `t.Parallel()` and changed-package selection through `go list`.
  - `CLAUDE-RUBY.md`: `parallel_tests`.

  Each flag was checked against the current documentation rather than written from memory.
- Both READMEs, the regenerated Codex and Cursor ports, and the hash manifest.

## Architectural decisions

- **A `# Shard:` header per fixture, not a timing file.** Measured times drift with load, and a header is deterministic, reviewable, and sits beside the fixture it describes.
- **Name matching plus an always-run fast tier, rather than name matching alone.** About ten fixtures scan whole trees without naming the files they check, so name matching alone would have let their failures surface only at pre-push. Those scanners are almost all fast, so running the fast tier every turn covers them for about 25 seconds.
- **The mapping corpus spans both trees.** Otherwise a change to a hook fixture would read as unmapped to the enforce tree and trigger a full enforce run.
- **A settle pause before serial fixtures, not a wider latency budget.** Straight after the parallel batch, `hook-latency.test.sh` failed by 2ms on its PreToolUse:Write chain, while run alone it passed three times out of three with 12 to 15 percent headroom. The pause moves the measurement back to the quiet machine the budget assumes, and the budget itself is unchanged.
- **The gate passes `--affected` to `run-tests.sh` rather than calling the runner directly,** so discovery, the node_modules guard, and the existing gate fixtures all stay as they were.

## Testing

- `run-fixture-shards.test.sh` failed in all 20 of its cases before the runner existed. The settle-pause case failed before the pause was added, and both now pass.
- The new `verification-gate.test.sh` case failed before the gate change and passes after it.
- Full sharded runs of both suites, with stdin closed and `CLAUDE_PROJECT_DIR` set as the Stop gate sets it: two consecutive green runs at 88 and 85 seconds, against 276 seconds sequentially.
- Affected runs for a one-hook edit: 30 seconds for `hooks/session-start.sh` and 37 seconds for `hooks/secret-scan.sh`.
- A parallel prototype ran all 100 non-timing fixtures green twice at 8 jobs before any code was written, which settled that the fixtures isolate well enough to shard. Wall time was 105 seconds at 4 jobs, 62 at 8, and 65 at 12, which set the cap at 8.

## Reflection

- The first estimate for an affected turn was about 20 seconds. The measured figure is 30 to 37, because the fast tier is 64 fixtures rather than a handful; the gate's comment carries the measured number.
- Two of this fixture's case names contained the failure marker in capitals, which the verdict rule reads as a failure. The fixture failed its own run while every case passed, and the case names were changed.
- Ticket IAN-94 was opened 43 minutes after the request, after the timing runs and design questions had already happened; its `started_at` is the request time from the session transcript.

## Review round 1 (Copilot)

- **False green in `git-env-isolation.test.sh`.** Its sandbox copied `run-tests.sh` alone, which now needs its sibling runner, so both suites exited before reaching the synthetic fixture. The decoy checks still passed without testing anything. The fixture now asserts that each sandboxed suite exits 0 and reaches its fixture. Both new checks failed against the old sandbox, and after the sandbox was rebuilt in the checkout's `claude/<tree>/tests` layout with the runner beside it, all eight checks pass.
- **Serial-only tree.** An empty parallel batch still piped into `xargs`, and GNU `xargs` starts its command once on empty input, here with no fixture argument. The batch call is now skipped when empty. The new case passed on macOS before the fix, because BSD `xargs` skips empty input, so the Linux CI runner is where it would have failed.
- **`--affected` outside a repository.** With no injected change list and no repository, the runner ran only the fast tier. It now runs everything and says so. The new case failed before the fix and passes after it.
- **An unfinished sentence** in the Go guidance ("so they can.") now reads "so they can run in parallel."
- `main` gained #40, which rewrote `CLAUDE-PYTHON.md`. The merge keeps that rewrite and re-adds the R-509 bullet in its new Testing section, reworded for its bullet style and its single-Postgres fixture model (one database per xdist worker).

## Review round 2 (Copilot)

- **Whole-tree scanners in the slow tier.** Name matching could not reach fixtures that read files they never name. `credential-shape-scan.test.sh` scans every tracked file, and `hook-latency.test.sh` times every registered hook and reads `settings.json`. A slow or serial fixture now declares what it reads on a `# Watches:` line of globs, and a change matching one selects it. Headers:
  - `hook-latency.test.sh`: `hooks/*.sh settings.json`.
  - `convention-track-invariants.test.sh`: the `CLAUDE-*.md` and `rules/` files.
  - `fixture-implementation-root.test.sh`: both fixture trees, the hooks, and `harness-root.sh`.
  - `translate-cursor.test.sh`: `translate/` and `cursor/`.

  The last two were not flagged but have the same shape. `credential-shape-scan.test.sh` left the slow tier instead of watching `*`, because a catch-all glob would count every file as mapped and silence the unmapped-change fallback. It runs every turn, in parallel with the rest.
- **List-only selection** (`FIXTURE_SHARD_LIST_ONLY=1`) lets the runner fixture assert, against this checkout's real headers, that each of those scanners is selected by the change it guards. Three of the five real-tree cases failed before the headers were added.
- **A shell bug found on the way:** the watch globs were word-split with filename expansion on, so `hooks/*.sh` expanded against the working directory before matching. Filename expansion is now off while the globs are read.
- **The top-level README** line now describes the fast tier, the watch globs, and the serial fixtures accurately.

## CI failure after round 2

- The `fixtures` job failed on `hook-hashes-closure.test.sh`, which reported `enforce/tests/flat-directory-reminder.test.sh` absent from a manifest that lists it. The log carried `printf: write error: Broken pipe`. The check piped a ~10KB path list into `grep -qxF` under `pipefail`. When `grep` exits at its first match while `printf` is still writing, the pipeline takes `printf`'s failure, so a present path reads as absent. Whether that happens depends on timing, and the parallel load on the CI runner made it happen.
- The runner's own verdict had the same shape: each fixture's whole output was piped into `grep -q PASS`. A new case, a passing fixture whose output runs far past the 64KB pipe buffer, failed three runs out of three and now passes. The runner, `hook-hashes-closure.test.sh`, and `manifest-fixture-closure.test.sh` use here-strings now. The remaining uses of the pattern across the fixtures pipe inputs small enough to go in one write, and a sweep of them is filed as a follow-up.

## Review round 3 (Copilot)

- **Test inputs were environment variables.** `FIXTURE_CHANGED_FILES` and `FIXTURE_SHARD_LIST_ONLY` were honoured from any caller's environment, so an exported value could hide a real slow-fixture change, or turn a gate, pre-push, or CI run into a listing that ran nothing and reported a pass. They are now the arguments `--changed-from <file>` and `--list`, which `run-tests.sh` never forwards, and the runner refuses any argument it does not know. A case exports both old names around a real change and asserts the slow fixture still runs.
- **A failing git query read as no change.** The change list is now an error when `git status` or `git diff` fails, and affected mode then runs everything.
- **An empty tree passed.** The runner now fails when it finds no fixtures, as the sequential runners did.
- **The pipe-fed verdict** had already been fixed in the previous round's CI fix.
- Against the previous runner, the three new scenarios reproduced as false greens: the empty tree exited 0, and the inherited variables and the unreadable index each skipped the slow fixture.
- **The first test run for this round recursed.** The real-tree selection cases called a runner that did not yet parse `--list`, so each ran this checkout's real suite, this fixture included, until the run was killed. The fixture now proves on its sandbox tree that list mode runs nothing before any real-tree case, and exits otherwise.

## Review round 4 (Copilot)

- **Checkout paths containing spaces.** Fixture paths were carried as one space-separated string, so a checkout under a directory such as `Alice Smith` split each path into broken arguments and reported a green suite red. Paths now travel one per line through every loop and reach `xargs` NUL-delimited. A spaced sandbox checkout is exercised in full mode, including its serial fixture, and in affected mode.
- **Inherited git context.** The runner cleared `GIT_DIR` and its siblings only before running fixtures, after change detection had already used them, so a caller exporting `GIT_DIR` could make affected mode read another repository. They are now cleared at the top of `main`, and a case points `GIT_DIR` at a decoy repository around a real change and asserts the slow fixture still runs.
- All four new cases failed before the change and pass after it. `main` gained #43 meanwhile; only generated files conflicted, and they were regenerated.

Ticket: IAN-94.
