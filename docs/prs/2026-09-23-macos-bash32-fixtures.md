# The fixture suites run on the macOS bash 3.2 floor

Ticket: IAN-307. Branch: `chore/macos-bash32-fixtures`. PR: #115.

## Summary

`.github/workflows/enforce.yml` ran the fixture suites only on `ubuntu-latest`, where `/usr/bin/env bash` is bash 5. Every hook in this repository carries a `#!/usr/bin/env bash` shebang, and on the machine where those hooks actually fire that resolves to `/bin/bash`, which is GNU bash 3.2.57. CI therefore exercised the guards under a shell nobody runs them under, and could not see a bash 4 construct at all, because on bash 5 the construct simply works.

That gap shipped a real failure on 2026-09-20 (IAN-267). PR #96 introduced `mapfile`, a bash 4 builtin, into `scope-widening-gate.sh` and `commit-message-guard.sh`. Under bash 3.2 both hooks aborted at that line and emitted nothing, and a `PreToolUse` hook that emits nothing is an ALLOW, so R-212's scope gate and R-214's out-of-scope commit gate enforced nothing for two and a half hours while every CI check stayed green. Nothing surfaced it, because a guard that fails open produces no error anyone sees.

This adds a second job, `fixtures (macOS, bash 3.2)`, which runs the same suites on `macos-latest` and asserts that the shell really is the floor.

## What changed

- `.github/workflows/enforce.yml`: one new job, `fixtures-macos`, named `fixtures (macOS, bash 3.2)` and running `macos-latest`. It repeats the ubuntu job's dependency installs (the locked `npm ci` with the same retry posture, and the same pinned ruff 0.16.6 and pytest 9.1.1) and then runs the enforcement fixtures, the hook fixtures, and the sync fixture. The file's own header now explains that the two jobs differ only in the shell that runs them.
- The job's first real step, `Assert the runner shell is the bash 3.2 floor`, prints every `bash` on PATH in resolution order and fails unless both the step's own `BASH_VERSINFO[0]` and `/usr/bin/env bash`'s major version are 3.

No fixture, hook, or enforcement script changed. Nothing under `claude/` is touched at all, so `hook-hashes.txt` is unchanged and its closure fixture stays green.

## Architectural decisions

- **Chosen: run the image's own `/bin/bash` and assert it is version 3.** **Alternative:** install a known bash through Homebrew so the job is reproducible against a pinned shell. **Why not:** installing any newer bash recreates the exact gap the job exists to close, and pinning bash 3.2 through a package manager is not possible in a way that also matches what a Mac ships. The assertion is the substitute for a pin: if a future runner image puts bash 4 or 5 ahead of `/bin/bash` on PATH, the job goes red and names the reason, rather than passing quietly while covering a shell nobody runs.
- **Chosen: assert both the step shell and `/usr/bin/env bash`.** **Alternative:** assert only `BASH_VERSINFO[0]` in the step. **Why not:** the two resolutions are different questions and both are load-bearing. GitHub runs each `run:` block through `bash` found on PATH, while every fixture and hook below re-resolves `bash` through its own shebang. A change that affected only one of the two would leave half the job covering the wrong shell.
- **Chosen: repeat only the shell-dependent work.** **Alternative:** mirror the ubuntu job step for step. **Why not:** `shellcheck`, the translator port checks, and the ratchet are a static analyzer and two Node programs reading tracked trees. Their answers cannot differ by platform, and a macOS runner minute bills at ten times an ubuntu one, so repeating them would buy nothing for a real cost. What is repeated is exactly the work whose result depends on the shell and on the userland the shell calls.
- **Chosen: leave `hook-latency.test.sh` in the run.** **Alternative:** exclude it from the macOS job on the assumption that a slower runner cannot meet its budget. **Why not:** the assumption turned out to be wrong, and excluding it would have been a skip added on a guess. Its budget is normalized against a same-environment bare-spawn control rather than an absolute wall-clock, which is what lets it travel to a slower machine. It passed on the first macOS run and is reported below; if it ever does become unreliable there, R-204 says the answer is to leave the job non-required rather than widen the budget.

## Testing

Everything below is observed output, not inference.

**Before the change, on the floor itself.** The whole point of the job is that the local Mac already is the floor (`/usr/bin/env bash` is 3.2.57, with BSD `sed`, `grep`, `stat`, `date`, and `wc`). Running both suites there on `main` first, to separate pre-existing breakage from anything this change caused: 104 of 104 enforcement fixtures pass and 22 of 22 hook fixtures pass. **No fixture needed fixing.** The BSD-versus-GNU divergences the ticket anticipated do not exist in this suite, and the reason is visible in the git history: this harness is written and run on macOS every day, so the fixtures were already BSD-correct. Only CI was missing.

**The macOS job itself**, run 35833579908 on `chore/macos-bash32-fixtures`:

- `Assert the runner shell is the bash 3.2 floor`: passed. The runner's `/bin/bash` and `/usr/bin/env bash` are both major version 3.
- `Enforcement fixtures`: `all ran 104 of 104 fixtures with 1 jobs`, `ALL ENFORCEMENT TESTS PASS`.
- `Hook fixtures`: `all ran 22 of 22 fixtures with 2 jobs`, `ALL HOOK TESTS PASS`.
- `Sync fixture`: passed.
- `hook-latency.test.sh`: `ok`. It is viable on a macOS runner.
- Wall clock: 13 minutes against the ubuntu job's 4.5. The shard runner sized itself to 1 parallel job for the enforcement tree, because `macos-latest` has 3 CPUs and the job's own startup load ate two of them.

**Affected-suite gate** (R-509), on the local floor: `affected ran 87 of 104 fixtures`, exit status 0, captured directly rather than through a pipe.

**Reintroducing `mapfile` turns the macOS job red.** Verified rather than assumed, on the throwaway branch `probe/ian-307-mapfile`, which restores the IAN-267 defect verbatim: the `while IFS= read` loop that builds `SCOPE` in `scope-widening-gate.sh` becomes `mapfile -t SCOPE < <(read_declared_scope ...)`, with `hook-hashes.txt` regenerated so the integrity closure is not what fails.

On the floor, both layers fire, and the second is the one only a real bash 3.2 run can produce:

```
FAIL: no mapfile in any hook
INFO: this run used bash 3.2.57(1)-release
FAIL: the scope gate emits an ask on an out-of-scope write (empty output is the fail-open signature)
```

`scope-widening-gate.test.sh` reports 8 failures against the same hook. The grep layer in `bash32-builtin-floor.test.sh` is platform-independent and would have caught this particular construct on ubuntu too. What the macOS job adds is the layer that does not depend on somebody having listed the construct: the shell itself refuses it, the guard falls silent, and the behavioural fixtures see the silence.

## Reflection

**What I understand now.** The existing `bash32-builtin-floor.test.sh` is careful and honest, and its own header names the gap it cannot close: a bash 4 construct nobody thought to list. That gap is not small. `${arr[-1]}`, `declare -g`, and `${v@Q}` are all bash 4 constructs, all absent from the fixture's pattern list, and all abort a `set -u` hook into exactly the same silence `mapfile` did, which I confirmed by running each one under `/bin/bash` rather than by reading the manual. A list of forbidden constructs is a list of the mistakes somebody already made. Running on the floor covers the ones nobody has made yet, which is the only kind that can still surprise you.

**What I got wrong first.** I expected to spend most of this task fixing fixtures broken by BSD `sed` and `stat`, because the ticket said to expect them and because that is the usual shape of a first macOS CI run. I had it backwards. The development platform is macOS; ubuntu is the foreign one. Running both suites on the local floor before touching the workflow is what showed that, and it cost two commands. Had I skipped that step and gone straight to CI, I would have read any red as a platform divergence to fix rather than as something I had caused.

**On cost.** The macOS job takes 13 minutes and macOS minutes bill at ten times ubuntu's, so this job adds roughly 130 ubuntu-equivalent minutes to every pull request. That is a real number and it deserves a deliberate decision rather than a silent acceptance. The shard runner accepts a `--jobs` argument that `run-tests.sh` deliberately does not forward, so raising parallelism on the small runner is possible but is a change to the runner's contract and belongs in its own ticket. Restricting the job to `push: main` would halve the bill and lose most of the value, because the point is to catch the construct before it merges.
