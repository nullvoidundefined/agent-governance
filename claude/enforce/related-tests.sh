#!/usr/bin/env bash
# related-tests.sh: the test mapping behind the R-509 turn-end gate. Given a
# stack name, it prints the commands that run only the tests related to the
# files changed on this branch. Exit 0 with no output means no source file
# changed and nothing needs to run; exit 1 means the mapping cannot answer and
# the caller runs the full suite (the full-suite fallback). The full suite
# itself runs in CI as a required check (IAN-98, 2026-09-18). The governance
# repo's own fixtures are not mapped here: run-tests.sh --affected selects them
# (IAN-94). Sourced by hooks/verification-gate.sh with the working directory at
# the repository root; never executed directly.

# listChangedFiles
# Prints each path that differs from the branch's fork point (upstream, else
# origin/HEAD, else HEAD), committed or not, plus untracked files, one path
# per line relative to the repository root. Deleted paths are included: the
# caller treats them as unmappable (PR #54 review). Returns 1 when there is no
# commit to diff against, because the change set is then unknowable.
listChangedFiles() {
  local base
  base=$(git merge-base HEAD '@{u}' 2>/dev/null \
    || git merge-base HEAD origin/HEAD 2>/dev/null \
    || git rev-parse --verify -q HEAD 2>/dev/null) || return 1
  { git diff --name-only -z "$base" -- 2>/dev/null; git ls-files -o -z --exclude-standard 2>/dev/null; } \
    | tr '\0' '\n' | sort -u
}

# isHarnessFile <path>
# Succeeds when the path configures how tests run, so a change to it can alter
# any test's outcome and forces the full-suite fallback.
isHarnessFile() {
  case "$(basename "$1")" in
    run-tests.sh|harness-root.sh|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock) return 0 ;;
    vitest.config.*|vite.config.*|jest.config.*|tsconfig*.json) return 0 ;;
    conftest.py|pytest.ini|pyproject.toml|setup.cfg|setup.py|tox.ini|go.mod|go.sum) return 0 ;;
    requirements*.txt|Pipfile|Pipfile.lock|poetry.lock|uv.lock) return 0 ;;
  esac
  return 1
}

# isInertFile <path>
# Succeeds when the path is prose or repository metadata that no test reads,
# so a change to it needs no test run: this is what lets a docs-only commit
# end its turn without a suite (IAN-98).
isInertFile() {
  case "$1" in
    docs/*|*/docs/*|*.md|*.mdx|*.rst|LICENSE*|CHANGELOG*|.gitignore|.github/*) return 0 ;;
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
  printf '%q' "$1"
  shift
  for word in "$@"; do printf ' %q' "$word"; done
  printf '\n'
}

# printNodeExecPrefix
# Prints the command that runs a locally installed package binary for this
# repository's package manager, read from its lockfile.
printNodeExecPrefix() {
  if [ -f pnpm-lock.yaml ]; then
    echo "pnpm exec"
  elif [ -f yarn.lock ]; then
    echo "yarn"
  else
    echo "npx --no-install"
  fi
}

# buildNodeCommands <vitest|jest> <changed files...>
# Sends every changed file to the runner's own related-test mode, stylesheets
# and assets included, so the runner's import graph decides what is related
# (PR #54 re-review: an unmapped non-script file must not pass untested). An
# empty related set passes (--passWithNoTests): the runner resolves the import
# graph at run time, so emptiness is not knowable here, and CI's full suite
# covers it.
buildNodeCommands() {
  local runner="$1" changed_file sources=() prefix
  shift
  for changed_file in "$@"; do
    case "$changed_file" in
      # Tracked build output or vendored code: no runner maps it, yet it can
      # change what a test loads, so it falls back (PR #58 review).
      node_modules/*|*/node_modules/*|dist/*|*/dist/*) return 1 ;;
      *) sources+=("$changed_file") ;;
    esac
  done
  [ "${#sources[@]}" -gt 0 ] || return 0
  prefix=$(printNodeExecPrefix)
  if [ "$runner" = vitest ]; then
    # shellcheck disable=SC2086
    printQuotedCommand $prefix vitest related --run --passWithNoTests -- "${sources[@]}"
  else
    # shellcheck disable=SC2086
    printQuotedCommand $prefix jest --findRelatedTests --passWithNoTests -- "${sources[@]}"
  fi
}

# buildPytestCommands <changed files...>
# A changed test file runs itself; a changed module runs test_<module>.py or
# <module>_test.py wherever they live. A module with neither, or a changed
# non-Python file (a template or data fixture a test may read), returns 1.
buildPytestCommands() {
  local changed_file module found test_files="" test_file list=()
  for changed_file in "$@"; do
    case "$changed_file" in *.py) ;; *) return 1 ;; esac
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
  while IFS= read -r test_file; do list+=("$test_file"); done <<< "$test_files"
  printQuotedCommand pytest -q -- "${list[@]}"
}

# buildGoCommands <changed files...>
# Tests and vets only the packages that contain a changed .go file. A changed
# non-Go file (an embedded asset, a .proto) returns 1.
buildGoCommands() {
  local changed_file packages="" package list=()
  for changed_file in "$@"; do
    case "$changed_file" in
      *.go) packages="$packages"$'\n'"./$(dirname "$changed_file")" ;;
      *) return 1 ;;
    esac
  done
  packages=$(printf '%s\n' "$packages" | sed '/^$/d; s#^\./\.$#.#' | sort -u)
  [ -n "$packages" ] || return 0
  while IFS= read -r package; do list+=("$package"); done <<< "$packages"
  printQuotedCommand go test -- "${list[@]}"
  printQuotedCommand go vet -- "${list[@]}"
}

# buildRelatedTestCommands <vitest|jest|pytest|go>
# Prints the related-test commands for the files changed on this branch.
# Exit 1 is the full-suite fallback: an unknown stack, a changed harness file,
# a deleted file (whose dependents no mapper can find), a change set that
# cannot be determined, or a changed file the mapping cannot place. Prose and
# repository metadata (isInertFile) are skipped, so a docs-only change runs
# nothing.
buildRelatedTestCommands() {
  local stack="$1" changed_file changed_listing changed_files=()
  changed_listing=$(listChangedFiles) || return 1
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    isHarnessFile "$changed_file" && return 1
    isInertFile "$changed_file" && continue
    [ -e "$changed_file" ] || return 1
    changed_files+=("$changed_file")
  done <<< "$changed_listing"
  [ "${#changed_files[@]}" -gt 0 ] || return 0
  case "$stack" in
    vitest|jest) buildNodeCommands "$stack" "${changed_files[@]}" ;;
    pytest) buildPytestCommands "${changed_files[@]}" ;;
    go) buildGoCommands "${changed_files[@]}" ;;
    *) return 1 ;;
  esac
}
