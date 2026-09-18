# Task Wall Time Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the process wait around each task. The LLM rule judge and the full suite move off the local push path into CI, the turn-end gate runs only related tests, and trivial-tier PRs skip the ticket, the PR doc and the Copilot review.

**Architecture:** A new sourced helper, `claude/enforce/related-tests.sh`, turns the branch's changed files into related-test commands for each stack. `verification-gate.sh` consults it before falling back to the full suite. The judge's diff-and-verdict core moves out of the PreToolUse hook into `claude/enforce/judge-diff.sh`, which a new `rule-judge.yml` workflow calls on each pull request. The rule text, the skills and the generated Cursor and Codex ports are then updated to match.

**Tech Stack:** Bash 3.2-compatible shell (macOS default), jq, GitHub Actions, Node for the `translate/` port generators.

**Spec:** `claude/docs/superpowers/specs/2026-09-18-task-wall-time-design.md` (IAN-98)

## Global Constraints

- The shell must run under bash 3.2. There is no `mapfile`, and an empty array is never expanded under `set -u` without a length guard first.
- Never use U+2014 (the em dash) anywhere, including comments and commit messages (R-207).
- Every new source file gets a header comment (R-320), and every function gets a comment block (R-333).
- Function names are verb plus noun (R-316). Match the casing of the file being edited: `verification-gate.sh` uses snake_case, and `enforce/*.sh` helpers use camelCase (for example `listPortChecks`).
- Every commit carries `Refs: IAN-98` and the `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` trailer.
- Every task runs through `enforce/tdd.sh` slices: open, failing fixture, `red`, implement, `green`, close (R-412).
- After any change under `claude/hooks/` or `claude/enforce/`, regenerate the integrity manifest with `CLAUDE_INTEGRITY_ROOT="$PWD/claude" bash claude/hooks/hook-integrity-check.sh --update` from the worktree root.
- After any change to `claude/settings.json`, `claude/CLAUDE.md`, `claude/rulebook/`, or `claude/skills/`, regenerate the ports with `node translate/cursor.mjs --write && node translate/codex.mjs --write`, then confirm that `--check` passes for both.

## Deviations from the spec, for approval with this plan

1. **The Node stacks pass when no test is related.** `vitest related` and `jest --findRelatedTests` compute the related set from the import graph at run time, so the helper cannot know in advance that the set is empty. The plan passes `--passWithNoTests`, and CI's full suite catches whatever that misses. The spec's rule to "fall back when the set is empty" still holds for the governance, pytest and Go mappings.
2. **The list of harness files is wider than the spec's.** Besides `run-tests.sh`, the vitest and jest configs, and `conftest.py`, the full-suite fallback also triggers on package manifests and lockfiles, `tsconfig*.json`, `pytest.ini`, `setup.cfg`, `go.mod`, `go.sum`, and `harness-root.sh`. A change to any of these can alter the outcome of any test.
3. **Pre-push keeps the port checks.** These are the `node translate/*.mjs --check` runs. They take seconds, and a stale port is the one failure that the fixture-free push path would otherwise let through.
4. **One PR carries all three fixes.** The spec and the plan are single documents, and splitting the work would mean three CI and review cycles for one feature.

## File map

| File | Change | Responsibility |
|---|---|---|
| `claude/enforce/tests/run-tests.sh` | modify | Accepts optional fixture names and runs only those. |
| `claude/hooks/tests/run-tests.sh` | modify | Same change as above. |
| `claude/enforce/related-tests.sh` | create | The test mapping: changed files to related-test commands, per stack. |
| `claude/enforce/tests/related-tests.test.sh` | create | Fixtures for each stack row, each fallback trigger, and the hostile filename. |
| `claude/hooks/verification-gate.sh` | modify | Uses the mapping through `add_test_check`, falling back to the full suite. |
| `claude/enforce/tests/verification-gate.test.sh` | modify | Adds invariants 13 to 15 for targeted runs. |
| `claude/enforce/judge-diff.sh` | create | The judge core, called as `judge-diff.sh <base> <head>`. |
| `claude/hooks/llm-rule-judge.sh` | delete | Replaced by the CI judge. |
| `claude/enforce/tests/llm-rule-judge.test.sh` | rename to `judge-diff.test.sh` | Same cases, asserting exit codes and stdout. |
| `.github/workflows/rule-judge.yml` | create | The CI judge on `pull_request`, also callable as a reusable workflow. |
| `claude/settings.json` | modify | Unregisters the judge from PreToolUse `Bash`. |
| `claude/enforce/manifest.json` | modify | Changes the five judge rules' enforcer to `ci:llm-rule-judge`. |
| `claude/hooks/pre-push.sample` | modify | Drops the fixture suites and keeps the port checks. |
| `claude/CLAUDE.md`, `claude/rulebook/reference.md` | modify | The R-509 text, the R-514 trivial path, and the meaning of `[judge]`. |
| `claude/skills/task-start/SKILL.md`, `claude/skills/task-cleanup/SKILL.md` | modify | The trivial fast path. |
| `claude/enforce/tests/wall-time-rule-text.test.sh` | create | Asserts the new rule wording in the source files and the generated ports. |
| `claude/README.md` | modify | Enforcement section: the judge now runs in CI, and the gate runs related tests (R-508). |

---

### Task 1: Suite runners accept fixture names

**Files:**
- Modify: `claude/enforce/tests/run-tests.sh` (the `for t in "$DIR"/*.test.sh` loop)
- Modify: `claude/hooks/tests/run-tests.sh` (the same loop)
- Test: `claude/enforce/tests/related-tests.test.sh` (the runner cases live here, because the runner's only new consumer is the mapping)

**Interfaces:**
- Produces: `bash claude/enforce/tests/run-tests.sh [fixture-name.test.sh ...]`. With no arguments it runs every fixture, as today. With arguments it runs only the named fixtures from its own directory. A name that contains `/`, or that does not exist, prints `FAIL <name> (no such fixture)` and makes the run exit 1.

- [ ] **Step 1: Write the failing test.** Create `claude/enforce/tests/related-tests.test.sh` with this header and the runner cases:

```bash
#!/usr/bin/env bash
# Covers: hook:verification-gate
# Verifies the R-509 test mapping (enforce/related-tests.sh) and the suite
# runners' fixture-name arguments it depends on.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
RUNNER="$CLAUDE_HARNESS_ROOT/enforce/tests/run-tests.sh"

# R1. A named fixture runs alone.
OUT=$(bash "$RUNNER" verification-gate.test.sh 2>&1)
printf '%s' "$OUT" | grep -q '^ok   verification-gate.test.sh$' || { echo "FAIL: named fixture did not run: $OUT"; exit 1; }
[ "$(printf '%s\n' "$OUT" | grep -c '^ok ')" -eq 1 ] || { echo "FAIL: more than the named fixture ran: $OUT"; exit 1; }

# R2. A path-shaped or missing name fails the run.
if bash "$RUNNER" ../escape.test.sh >/dev/null 2>&1; then echo "FAIL: a name with / must fail"; exit 1; fi
if bash "$RUNNER" no-such.test.sh >/dev/null 2>&1; then echo "FAIL: a missing fixture must fail"; exit 1; fi

echo "PASS"
```

- [ ] **Step 2: Run the test and confirm that it fails.** Run `bash claude/enforce/tests/related-tests.test.sh`. Expected: `FAIL: more than the named fixture ran`, because the runner ignores its arguments today and runs every fixture.

- [ ] **Step 3: Implement the change.** In both runners, replace the loop header:

```bash
fail=0
# Named fixtures (from the R-509 related-test mapping) run alone; no names
# runs the whole directory, as before.
if [ "$#" -gt 0 ]; then
  fixtures=()
  for name in "$@"; do
    case "$name" in
      */*|'') echo "FAIL $name (no such fixture)"; fail=1; continue ;;
    esac
    fixtures+=("$DIR/$name")
  done
else
  fixtures=("$DIR"/*.test.sh)
fi
for t in ${fixtures[@]+"${fixtures[@]}"}; do
  name=$(basename "$t")
  [ -f "$t" ] || { echo "FAIL $name (no such fixture)"; fail=1; continue; }
```

The rest of the loop body stays as it is. The `${fixtures[@]+...}` form is the bash 3.2-safe expansion of a possibly empty array.

- [ ] **Step 4: Run the test and confirm that it passes.** Run `bash claude/enforce/tests/related-tests.test.sh`. Expected: `PASS`.

- [ ] **Step 5: Commit.**

```bash
git add claude/enforce/tests/run-tests.sh claude/hooks/tests/run-tests.sh claude/enforce/tests/related-tests.test.sh
git commit -m "feat(enforce): suite runners accept fixture names" -m "Refs: IAN-98"
```

---

### Task 2: The test mapping helper

**Files:**
- Create: `claude/enforce/related-tests.sh`
- Test: `claude/enforce/tests/related-tests.test.sh` (append cases M1 to M10 before the final `echo "PASS"`)

**Interfaces:**
- Consumes: the runners' fixture-name arguments from Task 1.
- Produces: `buildRelatedTestCommands <stack>`, where the stack is `governance`, `vitest`, `jest`, `pytest`, or `go`. It is sourced, not executed. It must be called with the working directory at the repository root. It prints one shell command per line. Exit 0 with output means "run these". Exit 0 with no output means "no source file changed, so run nothing". Exit 1 means "full-suite fallback".

- [ ] **Step 1: Write the failing tests.** Append these cases:

```bash
MAPPING="$CLAUDE_HARNESS_ROOT/enforce/related-tests.sh"

# Creates a committed sandbox repository and prints its path.
new_sandbox() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  echo "$dir"
}

# Commits everything in the sandbox.
commit_sandbox() { git -C "$1" add -A && git -C "$1" commit -qm "chore: base"; }

# Runs the mapping for a stack inside a sandbox; prints output, then "exit=<n>".
map_in() {
  local dir="$1" stack="$2"
  ( cd "$dir" && . "$MAPPING" && { buildRelatedTestCommands "$stack"; echo "exit=$?"; } )
}

# A governance-shaped sandbox with one hook and one fixture naming it.
new_governance_sandbox() {
  local dir
  dir=$(new_sandbox)
  mkdir -p "$dir/claude/hooks/tests" "$dir/claude/enforce/tests" "$dir/docs"
  echo 'echo hi' > "$dir/claude/hooks/foo.sh"
  echo 'echo hi' > "$dir/claude/hooks/orphan.sh"
  printf '# exercises foo.sh\necho PASS\n' > "$dir/claude/enforce/tests/foo.test.sh"
  echo '# runner' > "$dir/claude/enforce/tests/run-tests.sh"
  echo '# runner' > "$dir/claude/hooks/tests/run-tests.sh"
  echo 'notes' > "$dir/docs/notes.md"
  commit_sandbox "$dir"
  echo "$dir"
}

# M1. A changed hook runs only the fixture that names it.
G=$(new_governance_sandbox); echo 'echo changed' >> "$G/claude/hooks/foo.sh"
OUT=$(map_in "$G" governance)
[ "$OUT" = "bash claude/enforce/tests/run-tests.sh foo.test.sh
exit=0" ] || { echo "FAIL M1: $OUT"; exit 1; }

# M2. A docs-only change runs nothing.
G=$(new_governance_sandbox); echo 'more' >> "$G/docs/notes.md"
OUT=$(map_in "$G" governance)
[ "$OUT" = "exit=0" ] || { echo "FAIL M2: $OUT"; exit 1; }

# M3. A changed file that no fixture names falls back.
G=$(new_governance_sandbox); echo 'echo changed' >> "$G/claude/hooks/orphan.sh"
OUT=$(map_in "$G" governance)
[ "$OUT" = "exit=1" ] || { echo "FAIL M3: $OUT"; exit 1; }

# M4. A changed harness file falls back.
G=$(new_governance_sandbox); echo '# edit' >> "$G/claude/enforce/tests/run-tests.sh"
OUT=$(map_in "$G" governance)
[ "$OUT" = "exit=1" ] || { echo "FAIL M4: $OUT"; exit 1; }

# M5. vitest: changed sources go to vitest related.
V=$(new_sandbox); mkdir -p "$V/src"
echo '{"devDependencies":{"vitest":"^3.0.0"}}' > "$V/package.json"
echo 'export const a = 1;' > "$V/src/a.ts"; commit_sandbox "$V"
echo 'export const b = 2;' >> "$V/src/a.ts"
OUT=$(map_in "$V" vitest)
[ "$OUT" = "npx --no-install vitest related --run --passWithNoTests src/a.ts
exit=0" ] || { echo "FAIL M5: $OUT"; exit 1; }

# M6. jest: changed sources go to --findRelatedTests, with pnpm's exec prefix.
J=$(new_sandbox); mkdir -p "$J/src"; touch "$J/pnpm-lock.yaml"
echo '{"devDependencies":{"jest":"^30.0.0"}}' > "$J/package.json"
echo 'module.exports = 1;' > "$J/src/b.js"; commit_sandbox "$J"
echo '// edit' >> "$J/src/b.js"
OUT=$(map_in "$J" jest)
[ "$OUT" = "pnpm exec jest --findRelatedTests --passWithNoTests src/b.js
exit=0" ] || { echo "FAIL M6: $OUT"; exit 1; }

# M7. pytest: a changed module runs its matching test file.
P=$(new_sandbox); mkdir -p "$P/pkg" "$P/tests"
echo 'X = 1' > "$P/pkg/mod.py"; echo 'def test_x(): pass' > "$P/tests/test_mod.py"
echo 'Y = 1' > "$P/pkg/lonely.py"; commit_sandbox "$P"
echo 'X = 2' >> "$P/pkg/mod.py"
OUT=$(map_in "$P" pytest)
[ "$OUT" = "pytest -q tests/test_mod.py
exit=0" ] || { echo "FAIL M7: $OUT"; exit 1; }

# M8. pytest: a changed module with no matching test falls back.
echo 'Y = 2' >> "$P/pkg/lonely.py"
OUT=$(map_in "$P" pytest)
[ "$OUT" = "exit=1" ] || { echo "FAIL M8: $OUT"; exit 1; }

# M9. go: changed files test and vet only their packages.
O=$(new_sandbox); mkdir -p "$O/pkg/x"
echo 'package x' > "$O/pkg/x/x.go"; commit_sandbox "$O"
echo '// edit' >> "$O/pkg/x/x.go"
OUT=$(map_in "$O" go)
[ "$OUT" = "go test ./pkg/x
go vet ./pkg/x
exit=0" ] || { echo "FAIL M9: $OUT"; exit 1; }

# M10. Negative input: a hostile filename is quoted, never executed.
H=$(new_sandbox); mkdir -p "$H/src"
echo '{"devDependencies":{"vitest":"^3.0.0"}}' > "$H/package.json"; commit_sandbox "$H"
HOSTILE='src/a b$(touch PWNED);x.ts'
echo 'export {}' > "$H/$HOSTILE"
CMD=$(cd "$H" && . "$MAPPING" && buildRelatedTestCommands vitest)
ECHOED=$(cd "$H" && bash -c "printf '%s\n' ${CMD#npx --no-install vitest related --run --passWithNoTests }")
[ "$ECHOED" = "$HOSTILE" ] || { echo "FAIL M10: filename not preserved: $ECHOED"; exit 1; }
[ ! -e "$H/PWNED" ] || { echo "FAIL M10: filename was executed"; exit 1; }
```

- [ ] **Step 2: Run the tests and confirm that they fail.** Run `bash claude/enforce/tests/related-tests.test.sh`. Expected: `FAIL M1` (the helper does not exist, so sourcing it fails).

- [ ] **Step 3: Implement the helper.** Create `claude/enforce/related-tests.sh`:

```bash
#!/usr/bin/env bash
# related-tests.sh: the test mapping behind the R-509 turn-end gate. Given a
# stack name, it prints the commands that run only the tests related to the
# files changed on this branch. Exit 0 with no output means no source file
# changed and nothing needs to run; exit 1 means the mapping cannot answer and
# the caller runs the full suite (the full-suite fallback). The full suite
# itself runs in CI as a required check. Sourced by verification-gate.sh with
# the working directory at the repository root; never executed directly.

# listChangedFiles
# Prints each existing file that differs from the branch's fork point
# (upstream, else origin/HEAD, else HEAD), committed or not, plus untracked
# files, one path per line relative to the repository root.
listChangedFiles() {
  local base
  base=$(git merge-base HEAD '@{u}' 2>/dev/null \
    || git merge-base HEAD origin/HEAD 2>/dev/null \
    || git rev-parse HEAD 2>/dev/null) || return 0
  { git diff --name-only -z "$base" -- 2>/dev/null; git ls-files -o -z --exclude-standard 2>/dev/null; } \
    | tr '\0' '\n' | sort -u | while IFS= read -r changed_file; do
      [ -f "$changed_file" ] && printf '%s\n' "$changed_file"
    done
}

# isHarnessFile <path>
# Succeeds when the path configures how tests run, so a change to it can alter
# any test's outcome and forces the full-suite fallback.
isHarnessFile() {
  case "$(basename "$1")" in
    run-tests.sh|harness-root.sh|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock) return 0 ;;
    vitest.config.*|vite.config.*|jest.config.*|tsconfig*.json) return 0 ;;
    conftest.py|pytest.ini|pyproject.toml|setup.cfg|go.mod|go.sum) return 0 ;;
  esac
  return 1
}

# printQuotedCommand <command words...> -- <arguments...>
# Prints the command words as given, then each argument shell-quoted, on one
# line, so a hostile filename can never execute when the line runs.
printQuotedCommand() {
  local word
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do printf '%s ' "$1"; shift; done
  shift
  printf '%q' "$1"; shift
  for word in "$@"; do printf ' %q' "$word"; done
  printf '\n'
}

# printSuiteRun <runner> <newline-separated fixture names>
# Prints one runner invocation over the unique fixture names, or nothing.
printSuiteRun() {
  local runner="$1" names name list=()
  names=$(printf '%s\n' "$2" | sed '/^$/d' | sort -u)
  [ -n "$names" ] || return 0
  while IFS= read -r name; do list+=("$name"); done <<< "$names"
  printQuotedCommand bash "$runner" -- "${list[@]}"
}

# buildGovernanceCommands <changed files...>
# A changed *.test.sh runs itself; any other changed file under claude/ runs
# every fixture that names its basename. docs/ changes need no fixture. A
# claude/ change that no fixture names returns 1 (fallback).
buildGovernanceCommands() {
  local changed_file base_name matched fixture enforce_names="" hook_names=""
  for changed_file in "$@"; do
    case "$changed_file" in docs/*|claude/docs/*) continue ;; claude/*) ;; *) continue ;; esac
    base_name=$(basename "$changed_file")
    case "$base_name" in
      *.test.sh) matched="$changed_file" ;;
      *) matched=$(grep -lF -- "$base_name" claude/enforce/tests/*.test.sh claude/hooks/tests/*.test.sh 2>/dev/null || true) ;;
    esac
    [ -n "$matched" ] || return 1
    while IFS= read -r fixture; do
      case "$fixture" in
        claude/enforce/tests/*) enforce_names="$enforce_names"$'\n'"$(basename "$fixture")" ;;
        claude/hooks/tests/*) hook_names="$hook_names"$'\n'"$(basename "$fixture")" ;;
      esac
    done <<< "$matched"
  done
  printSuiteRun claude/enforce/tests/run-tests.sh "$enforce_names"
  printSuiteRun claude/hooks/tests/run-tests.sh "$hook_names"
}

# printNodeExecPrefix
# Prints the command that runs a locally installed package binary for this
# repository's package manager, read from its lockfile.
printNodeExecPrefix() {
  if [ -f pnpm-lock.yaml ]; then echo "pnpm exec"
  elif [ -f yarn.lock ]; then echo "yarn"
  else echo "npx --no-install"
  fi
}

# buildNodeCommands <vitest|jest> <changed files...>
# Sends the changed script sources to the runner's own related-test mode. An
# empty related set passes (--passWithNoTests): the runner resolves the import
# graph at run time, so emptiness is not knowable here, and CI's full suite
# covers it.
buildNodeCommands() {
  local runner="$1" changed_file sources=() prefix
  shift
  for changed_file in "$@"; do
    case "$changed_file" in
      node_modules/*|*/node_modules/*|dist/*|*/dist/*) ;;
      *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.vue) sources+=("$changed_file") ;;
    esac
  done
  [ "${#sources[@]}" -gt 0 ] || return 0
  prefix=$(printNodeExecPrefix)
  if [ "$runner" = vitest ]; then
    printQuotedCommand $prefix vitest related --run --passWithNoTests -- "${sources[@]}"
  else
    printQuotedCommand $prefix jest --findRelatedTests --passWithNoTests -- "${sources[@]}"
  fi
}

# buildPytestCommands <changed files...>
# A changed test file runs itself; a changed module runs test_<module>.py or
# <module>_test.py wherever they live. A module with neither returns 1.
buildPytestCommands() {
  local changed_file module found test_files=""
  for changed_file in "$@"; do
    case "$changed_file" in *.py) ;; *) continue ;; esac
    module=$(basename "$changed_file" .py)
    case "$module" in
      test_*|*_test) found="$changed_file" ;;
      *) found=$(git ls-files -- ":(glob)**/test_${module}.py" ":(glob)**/${module}_test.py" 2>/dev/null) ;;
    esac
    [ -n "$found" ] || return 1
    test_files="$test_files"$'\n'"$found"
  done
  test_files=$(printf '%s\n' "$test_files" | sed '/^$/d' | sort -u)
  [ -n "$test_files" ] || return 0
  local list=() test_file
  while IFS= read -r test_file; do list+=("$test_file"); done <<< "$test_files"
  printQuotedCommand pytest -q -- "${list[@]}"
}

# buildGoCommands <changed files...>
# Tests and vets only the packages that contain a changed .go file.
buildGoCommands() {
  local changed_file packages="" package list=()
  for changed_file in "$@"; do
    case "$changed_file" in *.go) packages="$packages"$'\n'"./$(dirname "$changed_file")" ;; esac
  done
  packages=$(printf '%s\n' "$packages" | sed '/^$/d; s#^\./\.$#.#' | sort -u)
  [ -n "$packages" ] || return 0
  while IFS= read -r package; do list+=("$package"); done <<< "$packages"
  printQuotedCommand go test -- "${list[@]}"
  printQuotedCommand go vet -- "${list[@]}"
}

# buildRelatedTestCommands <governance|vitest|jest|pytest|go>
# Prints the related-test commands for the files changed on this branch.
# Exit 1 is the full-suite fallback: an unknown stack, a changed harness file,
# or a changed source file the mapping cannot place.
buildRelatedTestCommands() {
  local stack="$1" changed_file changed_files=()
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    isHarnessFile "$changed_file" && return 1
    changed_files+=("$changed_file")
  done < <(listChangedFiles)
  [ "${#changed_files[@]}" -gt 0 ] || return 0
  case "$stack" in
    governance) buildGovernanceCommands "${changed_files[@]}" ;;
    vitest|jest) buildNodeCommands "$stack" "${changed_files[@]}" ;;
    pytest) buildPytestCommands "${changed_files[@]}" ;;
    go) buildGoCommands "${changed_files[@]}" ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Run the tests and confirm that they pass.** Run `bash claude/enforce/tests/related-tests.test.sh`. Expected: `PASS`. If M10 fails on `printf %q` output differing between bash versions, keep the assertion on behavior (the round trip and no `PWNED` file) and do not assert the quoted spelling.

- [ ] **Step 5: Commit.**

```bash
git add claude/enforce/related-tests.sh claude/enforce/tests/related-tests.test.sh
git commit -m "feat(enforce): related-test mapping for the R-509 turn-end gate" -m "Refs: IAN-98"
```

---

### Task 3: The turn-end gate runs related tests

**Files:**
- Modify: `claude/hooks/verification-gate.sh` (the discovery block, and the `block` message in the check loop)
- Modify: `claude/enforce/tests/verification-gate.test.sh` (add invariants 13 to 15 to the header list and as cases)

**Interfaces:**
- Consumes: `buildRelatedTestCommands` from Task 2.
- Produces: gate block reasons that end with ` (related tests only; the full suite runs in CI)` when the failed check came from the mapping.

- [ ] **Step 1: Write the failing tests.** Add these lines to the header list:

```
#   13. In the governance layout, a changed hook runs only the fixtures naming it.
#   14. A changed harness file runs the full suites.
#   15. A docs-only change runs no fixture suite.
```

Then add these cases before the final PASS line. Each stub runner records its arguments:

```bash
# A governance-monorepo sandbox whose runners log their arguments to calls.log.
new_governance_repo() {
  local dir
  dir=$(new_repo)
  mkdir -p "$dir/claude/hooks/tests" "$dir/claude/enforce/tests" "$dir/docs"
  touch "$dir/claude/CLAUDE.md"
  echo 'echo hi' > "$dir/claude/hooks/foo.sh"
  printf '# exercises foo.sh\n' > "$dir/claude/hooks/tests/foo.test.sh"
  for suite in enforce hooks; do
    printf '#!/usr/bin/env bash\necho "%s:$*" >> "%s/calls.log"\n' "$suite" "$dir" > "$dir/claude/$suite/tests/run-tests.sh"
  done
  echo notes > "$dir/docs/notes.md"
  echo calls.log > "$dir/.gitignore"
  git -C "$dir" add -A && git -C "$dir" commit -qm "chore: governance layout"
  echo "$dir"
}

# 13. A changed hook runs only its fixture.
REPO=$(new_governance_repo); echo 'echo changed' >> "$REPO/claude/hooks/foo.sh"
GOT=$(gate "$REPO")
[ "$GOT" = "none" ] || { echo "FAIL: 13 expected silence, got: $GOT"; exit 1; }
[ "$(cat "$REPO/calls.log")" = "hooks:foo.test.sh" ] || { echo "FAIL: 13 expected only hooks:foo.test.sh, got: $(cat "$REPO/calls.log")"; exit 1; }

# 14. A changed runner is a harness file, so both full suites run with no arguments.
REPO=$(new_governance_repo); echo '# edit' >> "$REPO/claude/enforce/tests/run-tests.sh"
gate "$REPO" >/dev/null
[ "$(sort "$REPO/calls.log" | tr '\n' ' ')" = "enforce: hooks: " ] || { echo "FAIL: 14 expected both full suites, got: $(cat "$REPO/calls.log")"; exit 1; }

# 15. A docs-only change runs no suite.
REPO=$(new_governance_repo); echo more >> "$REPO/docs/notes.md"
gate "$REPO" >/dev/null
[ ! -s "$REPO/calls.log" ] || { echo "FAIL: 15 expected no suite, got: $(cat "$REPO/calls.log")"; exit 1; }
```

- [ ] **Step 2: Run the tests and confirm that they fail.** Run `bash claude/enforce/tests/verification-gate.test.sh`. Expected: `FAIL: 13 expected only hooks:foo.test.sh, got: enforce:` followed by `hooks:` (today's gate runs both full suites).

- [ ] **Step 3: Implement the change.** In `verification-gate.sh`, add this block directly after `add_check() { ... }`:

```bash
# The R-509 test mapping (enforce/related-tests.sh). Absent helper, or a
# mapping that falls back, means the full-suite commands run as before.
RELATED_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" 2>/dev/null && pwd)/related-tests.sh"
# shellcheck source=/dev/null
[ -f "$RELATED_HELPER" ] && . "$RELATED_HELPER"
RELATED_NOTE=""

# add_test_check <stack> <full-suite commands, one per line>
# Adds the related-test commands for the stack when the mapping answers, and
# the full-suite commands when it falls back or the helper is missing.
add_test_check() {
  local related line
  if type buildRelatedTestCommands >/dev/null 2>&1 && related=$(buildRelatedTestCommands "$1"); then
    RELATED_NOTE=" (related tests only; the full suite runs in CI)"
    while IFS= read -r line; do [ -n "$line" ] && add_check "$line"; done <<< "$related"
    return 0
  fi
  while IFS= read -r line; do [ -n "$line" ] && add_check "$line"; done <<< "$2"
}

# detect_node_test_runner
# Prints vitest or jest when package.json depends on one, else none.
detect_node_test_runner() {
  local runner
  for runner in vitest jest; do
    jq -e --arg r "$runner" '(.dependencies[$r] // .devDependencies[$r]) != null' package.json >/dev/null 2>&1 && { echo "$runner"; return; }
  done
  echo none
}
```

Then change the discovery branches:
- Monorepo branch: replace the two `add_check "bash claude/.../run-tests.sh"` lines with `add_test_check governance "bash claude/enforce/tests/run-tests.sh"$'\n'"bash claude/hooks/tests/run-tests.sh"`. The port-check lines that follow stay as they are.
- `package.json` branch: replace `has_npm_script test && add_check "$PM test"` with `has_npm_script test && add_test_check "$(detect_node_test_runner)" "$PM test"`.
- Python branch: replace `command -v pytest ... && add_check "pytest -q"` with `command -v pytest >/dev/null 2>&1 && add_test_check pytest "pytest -q"`.
- Go branch: replace the inner `add_check` pair with `add_test_check go "go test ./..."$'\n'"go vet ./..."`.
- The legacy top-level governance branch, the `.claude/verify.sh` branch, and the Ruby branch stay unchanged.

In the check loop's `block` call, append `${RELATED_NOTE}` directly after `${RETRY_NOTE}`. Update the file header's "Scope decisions" list with one entry: `Related tests only (2026-09-18, IAN-98): the mapping in enforce/related-tests.sh picks the tests for the changed files; the full suite runs in CI as the required fixtures check.`

- [ ] **Step 4: Run the tests and confirm that they pass.** Run `bash claude/enforce/tests/verification-gate.test.sh && bash claude/enforce/tests/related-tests.test.sh`. Expected: `PASS` from both. Invariants 1 to 12 must still pass unchanged: their `package.json` has no vitest or jest dependency, so it takes the full-suite fallback.

- [ ] **Step 5: Commit.**

```bash
git add claude/hooks/verification-gate.sh claude/enforce/tests/verification-gate.test.sh
git commit -m "feat(hooks): turn-end gate runs related tests, full suite in CI" -m "Refs: IAN-98"
```

---

### Task 4: The judge core becomes a CI script

**Files:**
- Create: `claude/enforce/judge-diff.sh`
- Delete: `claude/hooks/llm-rule-judge.sh`
- Rename and modify: `claude/enforce/tests/llm-rule-judge.test.sh` becomes `claude/enforce/tests/judge-diff.test.sh`
- Modify: `claude/settings.json` (remove the `llm-rule-judge.sh` entry from PreToolUse `Bash`)
- Modify: `claude/enforce/manifest.json` (every `"enforcer": "hook:llm-rule-judge"` becomes `"ci:llm-rule-judge"`)
- Modify: `claude/hooks/enforcement-guard-check.sh`, only if the suite shows that it rejects the `ci:` prefix
- Regenerate: `cursor/`, `codex/`, and `claude/enforce/hook-hashes.txt`

**Interfaces:**
- Produces: `bash claude/enforce/judge-diff.sh <base-ref> <head-ref>`, run with the working directory inside the target repository. It exits 1 when there is an error-severity finding with confidence of at least 0.8, printing one `<rule> [<file>]: <why>` line per finding on stdout. It exits 0 in every other case. Warn-severity findings go to stderr, and under `GITHUB_ACTIONS=true` they are prefixed `::warning::`. A missing key prints `::notice::` or a plain notice to stderr and exits 0. `CLAUDE_JUDGE_CMD` keeps working as the test stub.

- [ ] **Step 1: Write the failing test.** Run `git mv claude/enforce/tests/llm-rule-judge.test.sh claude/enforce/tests/judge-diff.test.sh`. Change its `# Covers:` line to `# Covers: ci:llm-rule-judge`, and change `HOOK=` to `JUDGE="$CLAUDE_HARNESS_ROOT/enforce/judge-diff.sh"`. Replace the payload-and-hook invocation with this helper:

```bash
# Runs the judge over HEAD~1..HEAD in the sandbox; prints stdout, then "exit=<n>".
judge() {
  local out status
  out=$(cd "$REPO" && bash "$JUDGE" HEAD~1 HEAD 2>/dev/null); status=$?
  printf '%s\nexit=%s' "$out" "$status"
}
```

Rewrite every case with this translation rule. An assertion on `permissionDecision":"ask"` becomes an assertion on `exit=1` plus the finding line on stdout. An assertion on silent or allow output becomes an assertion on `exit=0` with empty stdout. Stderr assertions (warn lines, the missing-key notice, truncation) stay on stderr. Every existing case keeps its number and intent, so none is dropped. Add one case:

```bash
# G1. Under GitHub Actions a warn finding is an annotation.
GH_ERR=$(cd "$REPO" && GITHUB_ACTIONS=true CLAUDE_JUDGE_CMD="$S4c" bash "$JUDGE" HEAD~1 HEAD 2>&1 >/dev/null)
printf '%s' "$GH_ERR" | grep -q '^::warning::' || { echo "FAIL G1: expected ::warning::, got: $GH_ERR"; exit 1; }
```

- [ ] **Step 2: Run the test and confirm that it fails.** Run `bash claude/enforce/tests/judge-diff.test.sh`. Expected: a failure because `judge-diff.sh` does not exist.

- [ ] **Step 3: Implement the change.** Create `claude/enforce/judge-diff.sh` with this preamble:

```bash
#!/usr/bin/env bash
# judge-diff.sh: the CI rule judge (R-315, R-316, R-317, R-325, R-334 and the
# other llm-judge tier rules in manifest.json). Asks a fast model to judge
# the diff between two refs against the semantic rules no linter can express.
# Exit 1 on an error-severity finding at or above the confidence threshold,
# one "<rule> [<file>]: <why>" line each on stdout; warn-severity findings go
# to stderr (as ::warning:: annotations under GitHub Actions). Fails open, exit
# 0 with a notice, when no API key is available or the model reply does not
# parse: the deterministic gates remain the hard guarantee. Moved off the
# local push path into .github/workflows/rule-judge.yml on 2026-09-18 (IAN-98):
# the push-time hook averaged 171 s per push. EGRESS: sends the diff to
# api.anthropic.com under ANTHROPIC_API_KEY.
set -uo pipefail
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$ENFORCE_DIR/.." && pwd)"
BASE="${1:-}"
HEAD_REF="${2:-HEAD}"
[ -n "$BASE" ] || { echo "usage: judge-diff.sh <base-ref> <head-ref>" >&2; exit 2; }

# run_git_on_target: kept so the moved vocabulary collector reads unchanged.
run_git_on_target() { git "$@"; }
```

After the preamble, move these parts of `llm-rule-judge.sh` over verbatim, in order:
1. The `collect_project_vocabulary` function.
2. Everything from the `DIFF=$(run_git_on_target diff ...` line through the `done < <(printf '%s' "$ALL_HITS" ...)` loop that builds `ASK_HITS`, with the comments included.

Apply these edits to the moved code:
- In the diff line, `"$BASE"..HEAD` becomes `"$BASE".."$HEAD_REF"`.
- `MANIFEST` defaults to `"${CLAUDE_MANIFEST_FILE:-$ENFORCE_DIR/manifest.json}"`, because CI has no `~/.claude`.
- The warn echo becomes `if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::warning::llm-rule-judge: $why" >&2; else echo "llm-rule-judge: $why" >&2; fi`.
- The missing-key message is printed with a `::notice::` prefix under `GITHUB_ACTIONS=true`.

End the file with this tail in place of the old `jq ... permissionDecision "ask"` tail:

```bash
COUNT=$(printf '%s' "$ASK_HITS" | jq 'length' 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -gt 0 ]; then
  printf '%s' "$ASK_HITS" | jq -r '.[] | "\(.rule) [\(.file)]: \(.why)"'
  exit 1
fi
exit 0
```

Next, make the remaining changes:
1. Delete `claude/hooks/llm-rule-judge.sh`.
2. Remove its object from the PreToolUse `Bash` hooks array in `claude/settings.json`.
3. Replace the enforcer everywhere in the manifest with `sed -i '' 's/"hook:llm-rule-judge"/"ci:llm-rule-judge"/' claude/enforce/manifest.json`.
4. Run `grep -rn "llm-rule-judge" translate claude/hooks claude/enforce --include='*.json' --include='*.sh' --include='*.mjs'`. For each hit that treats the judge as a registered hook (a port map entry, or a hash-closure list), remove the entry or rename it to `judge-diff.sh`.
5. Regenerate the ports and the hashes, following Global Constraints.

- [ ] **Step 4: Run the tests and confirm that they pass.** Run `bash claude/enforce/tests/run-tests.sh && bash claude/hooks/tests/run-tests.sh`. Expected: both report ALL ... PASS. This task changes `settings.json` and the manifest, and closure fixtures (`index-settings-sync`, `manifest-fixture-closure`, `hook-hashes-closure`, `enforcement-guard-check`) read both, so run the full suites here, not only the related ones. If `enforcement-guard-check` rejects `ci:`, extend its awk so that `/^ci:/` requires no hook file, and add one line to its fixture asserting that a `ci:` enforcer passes.

- [ ] **Step 5: Commit.**

```bash
git add -A claude/enforce claude/hooks claude/settings.json cursor codex translate
git commit -m "feat(enforce): rule judge moves from push hook to a CI script" -m "Refs: IAN-98"
```

---

### Task 5: CI judge workflow and a lighter pre-push

**Files:**
- Create: `.github/workflows/rule-judge.yml`
- Modify: `claude/hooks/pre-push.sample` (drop the suite loop, keep the port checks, update the header and the abort message)
- Modify: `claude/hooks/tests/install-git-hooks.test.sh`, only where it asserts that the pre-push runs suites

**Interfaces:**
- Consumes: `judge-diff.sh <base> <head>` from Task 4.
- Produces: a `rule-judge` check on every pull request, and a `workflow_call` entry point that other repositories can reuse.

- [ ] **Step 1: Write the failing test.** Add a case to `claude/hooks/tests/install-git-hooks.test.sh`. It asserts that the installed pre-push runs no fixture suite: stub `claude/enforce/tests/run-tests.sh` in the sandbox to `touch SUITE_RAN`, run the hook, and assert that `SUITE_RAN` is absent.

- [ ] **Step 2: Run the test and confirm that it fails.** Run `bash claude/hooks/tests/install-git-hooks.test.sh`. Expected: a failure because `SUITE_RAN` exists.

- [ ] **Step 3: Implement the change.** In `pre-push.sample`:
1. Delete the `for suite in enforce/tests/run-tests.sh ...` loop and the `SUITE_ROOT` resolution above it.
2. Change the abort message to `pre-push: port checks are red; push aborted.`
3. Replace the header's description with: `a stale Cursor or Codex port aborts the push. The fixture suites run in CI (the required "fixtures" check), not here: the local copy doubled every push's wait (IAN-98).`

Create `.github/workflows/rule-judge.yml`:

```yaml
# The CI rule judge (claude/enforce/judge-diff.sh): judges each pull request's
# diff against the llm-judge tier rules in claude/enforce/manifest.json. Moved
# here from a local push hook on 2026-09-18 (IAN-98). Other repositories reuse
# it through workflow_call; they get this repository's judge checked out
# beside their own code. Without ANTHROPIC_API_KEY the job passes with a notice.
name: rule-judge

on:
  pull_request:
  workflow_call:
    secrets:
      ANTHROPIC_API_KEY:
        required: false

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  judge:
    name: rule-judge
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0

      # A caller repository has no judge of its own; fetch this repository's.
      - uses: actions/checkout@v7
        if: hashFiles('claude/enforce/judge-diff.sh') == ''
        with:
          repository: nullvoidundefined/agent-governance
          path: .agent-governance

      - name: Judge the pull request diff
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          judge=claude/enforce/judge-diff.sh
          [ -f "$judge" ] || judge=.agent-governance/claude/enforce/judge-diff.sh
          bash "$judge" "$BASE_SHA" "$HEAD_SHA"
```

- [ ] **Step 4: Run the tests and confirm that they pass.** Run `bash claude/hooks/tests/install-git-hooks.test.sh`, then run `actionlint .github/workflows/rule-judge.yml` if `actionlint` is installed. If it is not installed, say so in the PR doc; do not install it. Expected: `PASS`.

- [ ] **Step 5: Commit.**

```bash
git add .github/workflows/rule-judge.yml claude/hooks/pre-push.sample claude/hooks/tests/install-git-hooks.test.sh claude/enforce/hook-hashes.txt
git commit -m "feat(ci): rule-judge workflow; pre-push keeps only port checks" -m "Refs: IAN-98"
```

---

### Task 6: Rule text, skills and the trivial fast path

**Files:**
- Modify: `claude/CLAUDE.md` (the R-509 norm line, and the header sentence defining `[judge]`)
- Modify: `claude/rulebook/reference.md` (lines 485, 581, and 586 for R-509; lines 603 to 605 for R-514)
- Modify: `claude/skills/task-start/SKILL.md` (the Trivial process block)
- Modify: `claude/skills/task-cleanup/SKILL.md` (the Trivial row near line 163)
- Modify: `claude/README.md` (the Enforcement section's judge and gate descriptions), plus `claude/CLAUDE-GO.md`, `claude/CLAUDE-RUBY.md`, and `claude/CLAUDE-PYTHON.md` wherever they call the judge a push hook
- Create: `claude/enforce/tests/wall-time-rule-text.test.sh`
- Regenerate: the ports and the hashes

- [ ] **Step 1: Write the failing test.** Create `claude/enforce/tests/wall-time-rule-text.test.sh`:

```bash
#!/usr/bin/env bash
# Covers: hook:verification-gate
# Asserts the IAN-98 rule wording (R-509 related tests with the full suite in
# CI; the R-514 trivial fast path; [judge] as the CI judge) is present in the
# source rule files and in the generated Cursor rules.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
R509='R-509: Run related tests at turn end and per commit; the full suite runs in CI as a required check; neither a turn nor a writing subagent ends on red related tests.'

grep -qF "$R509" "$ROOT/CLAUDE.md" || { echo "FAIL: CLAUDE.md lacks the new R-509"; exit 1; }
grep -qF "$R509" "$ROOT/rulebook/reference.md" || { echo "FAIL: reference.md lacks the new R-509"; exit 1; }
grep -qF 'full suite at pre-push' "$ROOT/CLAUDE.md" "$ROOT/rulebook/reference.md" && { echo "FAIL: stale pre-push wording remains"; exit 1; }
grep -qF 'trivial-tier PR' "$ROOT/rulebook/reference.md" || { echo "FAIL: R-514 lacks the trivial fast path"; exit 1; }
grep -qF 'no `docs/prs/` document' "$ROOT/skills/task-start/SKILL.md" || { echo "FAIL: task-start lacks the trivial fast path"; exit 1; }
grep -qF '`[judge]` is the CI rule judge' "$ROOT/CLAUDE.md" || { echo "FAIL: CLAUDE.md still calls [judge] a push-time judge"; exit 1; }
if [ -d "$REPO_ROOT/cursor/rules" ]; then
  grep -rqF "$R509" "$REPO_ROOT/cursor/rules" || { echo "FAIL: cursor rules not regenerated"; exit 1; }
fi
echo "PASS"
```

- [ ] **Step 2: Run the test and confirm that it fails.** Run `bash claude/enforce/tests/wall-time-rule-text.test.sh`. Expected: `FAIL: CLAUDE.md lacks the new R-509`.

- [ ] **Step 3: Implement the change.** Make these text edits:
- `claude/CLAUDE.md` R-509 line: replace it with `R-509: Run related tests at turn end and per commit; the full suite runs in CI as a required check; neither a turn nor a writing subagent ends on red related tests. [hook:verification-gate, ci:fixtures]`.
- `claude/CLAUDE.md` header: `` `[judge]` is the push-time LLM judge `` becomes `` `[judge]` is the CI rule judge (`rule-judge.yml`) ``.
- `reference.md:581`: the same R-509 sentence as in `CLAUDE.md`, without the enforcer bracket.
- `reference.md:485`: `Run verification per R-509 scope: related tests at commit, full suite in CI.`
- `reference.md:586`: `the CI full sweep (R-408, R-509)` in place of `the pre-push/CI full sweep`.
- `reference.md:604`: `Default path: (1) CI passes; (2) Copilot review passes, except for a trivial-tier PR, which merges on green CI with no Copilot request; (3) the user explicitly asks to merge after both are confirmed green. "Merge when ready" is not authorization.`
- `task-start` Trivial block: change the `Branch:` line to `Branch:         Yes, its own branch and PR; no ticket, no \`docs/prs/\` document, no Copilot review request; merge on green CI`. Change the sentence under the block to `Execute the change on a branch, open the PR, and merge once CI is green. Done.`
- `task-cleanup` Trivial row: `Commit, open the PR, merge on green CI. No ticket close, no PR doc, no Copilot wait.`
- README and the `CLAUDE-*.md` files: every sentence that describes the judge as running on `git push` now says it runs as the `rule-judge` CI check on pull requests. Every sentence saying the turn-end gate runs the full suite now says it runs related tests, with the full suite in CI.

Then regenerate the ports and the hashes.

- [ ] **Step 4: Run the tests and confirm that they pass.** Run `bash claude/enforce/tests/run-tests.sh && bash claude/hooks/tests/run-tests.sh`. Expected: both PASS, including the `dangling-refs`, `prose-flags`, and `no-em-dash` fixtures that read the edited text.

- [ ] **Step 5: Commit.**

```bash
git add -A claude cursor codex
git commit -m "docs(rules): R-509 related tests with CI full suite; R-514 trivial fast path" -m "Refs: IAN-98"
```

---

### Task 7: Changes outside the repository and in GitHub settings (each needs the user's approval)

- [ ] **Step 1:** Show the user the exact diff for `personal/.claude/CLAUDE.md`. The PR Workflow bullet "Every PR gets a document" gains ", except a trivial-tier PR". The "Merge on green" bullet gains "A trivial-tier PR skips the Copilot review." Apply the diff on approval.
- [ ] **Step 2:** Update the auto-memory file `claude-handles-merges.md`. Its "How to apply" line gains: `A trivial-tier PR skips the Copilot request and polling and merges on green CI (IAN-98, 2026-09-18).`
- [ ] **Step 3:** Ask the user to add the `ANTHROPIC_API_KEY` repository secret themselves (R-102: the value never passes through this session). The command they would run is `gh secret set ANTHROPIC_API_KEY --repo nullvoidundefined/agent-governance`.
- [ ] **Step 4:** Ask the user whether `rule-judge` should become a required status check. Adding it changes branch protection, so it needs an explicit yes. With a yes, run `gh api -X POST repos/nullvoidundefined/agent-governance/branches/main/protection/required_status_checks/contexts -f 'contexts[]=rule-judge'`.

---

### Task 8: Ship

- [ ] **Step 1:** Write `docs/prs/2026-09-18-cut-task-wall-time.md` with these sections: summary, what changed, the decisions with their alternatives, testing, and a reflection that includes the measured before numbers.
- [ ] **Step 2:** Run both full suites, then push the branch. The push itself is the first measurement: the expected wait is under 10 seconds, against the 171-second average.
- [ ] **Step 3:** Open the PR, request Copilot (this is a complex-tier PR, so the review step applies), and advance IAN-98 to `in-review`.
- [ ] **Step 4:** Merge on a clean review and green `fixtures` and `rule-judge` checks. Verify that the merge commit is on `origin/main`, then run `./sync.sh` from the primary checkout so that `~/.claude` picks up the change.
- [ ] **Step 5:** Run `task-cleanup`, and close IAN-98 with its actuals.
