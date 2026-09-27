#!/usr/bin/env bash
# Covers: ci:security-workflow
# Verifies the security CI Semgrep step, enforce/security-ci-semgrep.sh
# (IAN-381, spec Part 7 addendum, component 2, criteria B-20 and B-21). The
# step runs with its working directory inside the repository to scan:
#
#   security-ci-semgrep.sh --mode pr --base <base-ref>
#   security-ci-semgrep.sh --mode full
#
# It takes its targets from the sibling lister enforce/security-ci-targets.sh
# (same arguments), resolves Semgrep through CLAUDE_SEMGREP_CMD, else `semgrep`
# on PATH, else `uvx semgrep`, and runs it with the harness rule pack
# (`--config <harness>/enforce/semgrep`) plus every config named in
# SECURITY_CI_REGISTRY_CONFIGS (space-separated, default "p/default"), with
# `--json --error --disable-nosem --metrics=off --max-target-bytes=0`, over a
# scratch export of the targets' HEAD content. Every case here sets
# SECURITY_CI_REGISTRY_CONFIGS to the empty string so no network is needed.
#
# Exit codes: 0 on a clean scan or an empty target list; 1 when the report has
# results, printing one `::error file=<repo-relative path>,line=<start line>`
# workflow command per result on stdout, escaped the GitHub way (data escapes
# % CR LF as %25 %0D %0A; property values also escape : and , as %3A %2C);
# 2, failing closed with a message on stderr, when the lister exits non-zero,
# no Semgrep resolves, Semgrep exits other than 0 or 1, its stdout is not
# JSON, `.errors[]` holds an entry whose `.level` is "error", or a code target
# (.py .ts .tsx .mts .cts .js .jsx .mjs .cjs .go .rb) is missing from
# `.paths.scanned`.
#
# Cases 1 to 9 and 12 drive the step through Semgrep stand-ins wired in with
# CLAUDE_SEMGREP_CMD. Cases 10 and 11 run the real Semgrep (`semgrep` on PATH,
# else `uvx semgrep`) against the #27-shaped CORS sample, and the fixture fails
# rather than skips when neither resolves.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
export CLAUDE_HARNESS_ROOT
STEP="$CLAUDE_HARNESS_ROOT/enforce/security-ci-semgrep.sh"
SAMPLES_DIR="$CLAUDE_HARNESS_ROOT/enforce/tests/testdata/semgrep"
BASH_BIN=$(command -v bash)
unset CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# git_clean <args...>: runs git with every GIT_* location variable stripped, so
# a fixture run from inside a hook or a worktree never touches the outer repo.
git_clean() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR git "$@"
}

# new_repo <name>: creates a throwaway repository on branch main and prints
# its path.
new_repo() {
  local repo="$WORK/$1"
  mkdir -p "$repo"
  git_clean -C "$repo" init -q --initial-branch=main
  git_clean -C "$repo" config user.email t@t
  git_clean -C "$repo" config user.name t
  git_clean -C "$repo" config commit.gpgsign false
  printf '%s' "$repo"
}

# write_file <repo> <relative path> <content>: writes the file, creating its
# directories.
write_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
}

# commit_all <repo> <message>: commits every change in the repository.
commit_all() {
  git_clean -C "$1" add -A
  git_clean -C "$1" commit -q --allow-empty -m "$2"
}

# make_stub <mode>: writes a Semgrep stand-in for the mode and prints its path.
# The stand-in reads the targets it was given (everything after `--`, or every
# non-option argument that is not an option's value), expands a directory
# target into its files the way Semgrep reports them, and prints a report:
#   crash       garbage on stdout, exit 99, before looking at any target
#   clean       no results, no errors, every target scanned, exit 0
#   warnonly    as clean, plus one warn-level error, exit 0
#   result      one result at line 7 of the first scanned .py file, exit 1
#   inject      as result, with a message carrying a newline and a workflow
#               command, exit 1
#   nonjson     text that is not JSON, exit 0
#   exit7       a clean report, exit 7
#   errorlevel  no results, one error-level error, exit 0
#   omitpy      no results, every target scanned except the .py files, exit 0
make_stub() {
  local mode="$1" stub_path="$WORK/semgrep-stub-$1"
  {
    printf '#!/usr/bin/env bash\nSTUB_MODE=%s\n' "$mode"
    cat <<'STUB'
if [ "$STUB_MODE" = crash ]; then
  echo "garbage {{{ not json"
  echo "stub: internal error" >&2
  exit 99
fi
if [ "$STUB_MODE" = nonjson ]; then
  echo "this is not json {{{"
  exit 0
fi
targets=()
skip_value=0
after_dashes=0
for arg in "$@"; do
  if [ "$after_dashes" = 1 ]; then targets+=("$arg"); continue; fi
  if [ "$skip_value" = 1 ]; then skip_value=0; continue; fi
  case "$arg" in
    --) after_dashes=1 ;;
    --config|-c|--output|-o|--timeout|--jobs|-j|--include|--exclude) skip_value=1 ;;
    -*) ;;
    scan) ;;
    *) targets+=("$arg") ;;
  esac
done
scanned_list=""
for target in "${targets[@]}"; do
  if [ -d "$target" ]; then
    scanned_list="$scanned_list$(find "$target" -type f ! -name .semgrepignore | sed 's#^\./##')"$'\n'
  else
    scanned_list="$scanned_list$target"$'\n'
  fi
done
if [ "$STUB_MODE" = omitpy ]; then
  scanned_list=$(printf '%s' "$scanned_list" | grep -v '\.py$')
fi
scanned_json=$(printf '%s\n' "$scanned_list" | sed '/^$/d' | jq -R . | jq -s .)
finding_path=$(printf '%s\n' "$scanned_list" | grep '\.py$' | head -n 1)
[ -n "$finding_path" ] || finding_path=app.py
finding_message="stub finding"
[ "$STUB_MODE" = inject ] && finding_message=$'stub finding\n::add-mask::x'
case "$STUB_MODE" in
  clean|exit7|omitpy)
    jq -n --argjson scanned "$scanned_json" '{results: [], errors: [], paths: {scanned: $scanned}}' ;;
  warnonly)
    jq -n --argjson scanned "$scanned_json" \
      '{results: [], errors: [{level: "warn", type: "PartialParsing", message: "stub warning"}], paths: {scanned: $scanned}}' ;;
  errorlevel)
    jq -n --argjson scanned "$scanned_json" \
      '{results: [], errors: [{level: "error", message: "x"}], paths: {scanned: $scanned}}' ;;
  result|inject)
    jq -n --argjson scanned "$scanned_json" --arg path "$finding_path" --arg message "$finding_message" \
      '{results: [{check_id: "stub.rule", path: $path, start: {line: 7, col: 1, offset: 0}, end: {line: 7, col: 5, offset: 4}, extra: {message: $message, severity: "ERROR", lines: "x"}}], errors: [], paths: {scanned: $scanned}}' ;;
esac
case "$STUB_MODE" in
  result|inject) exit 1 ;;
  exit7) exit 7 ;;
  *) exit 0 ;;
esac
STUB
  } > "$stub_path"
  chmod +x "$stub_path"
  printf '%s' "$stub_path"
}

# run_step <repo> <semgrep command, empty to leave CLAUDE_SEMGREP_CMD unset>
# <args...>: runs the step from inside the repository with the GIT_* variables
# stripped, SECURITY_CI_REGISTRY_CONFIGS empty, and PATH set to STEP_PATH.
# Sets STEP_STDOUT, STEP_STDERR, and STEP_STATUS.
STEP_PATH="$PATH"
run_step() {
  local repo="$1" semgrep_command="$2"
  shift 2
  local out_file="$WORK/step.out" err_file="$WORK/step.err"
  (
    cd "$repo" || exit 96
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR CLAUDE_SEMGREP_CMD
    if [ -n "$semgrep_command" ]; then export CLAUDE_SEMGREP_CMD="$semgrep_command"; fi
    export SECURITY_CI_REGISTRY_CONFIGS=""
    PATH="$STEP_PATH" "$BASH_BIN" "$STEP" "$@"
  ) > "$out_file" 2> "$err_file"
  STEP_STATUS=$?
  STEP_STDOUT=$(cat "$out_file")
  STEP_STDERR=$(cat "$err_file")
}

# expect_status <label> <status>: the last run must exit exactly with status.
expect_status() {
  [ "$STEP_STATUS" -eq "$2" ] \
    || report_failure "$1: step must exit $2; got $STEP_STATUS (stdout: ${STEP_STDOUT:-<none>}; stderr: ${STEP_STDERR:-<none>})"
}

# expect_fail_closed <label>: the last run must exit 2 and explain itself on
# stderr.
expect_fail_closed() {
  expect_status "$1" 2
  [ -n "$STEP_STDERR" ] || report_failure "$1: step must print a message on stderr"
}

# expect_annotation <label> <line prefix>: stdout must hold a line starting
# with the prefix.
expect_annotation() {
  grep -qF -- "$2" <<< "$STEP_STDOUT" \
    && [ -n "$(printf '%s\n' "$STEP_STDOUT" | awk -v p="$2" 'index($0, p) == 1')" ] \
    || report_failure "$1: stdout must hold a line starting '$2'; got: ${STEP_STDOUT:-<none>}"
}

[ -f "$STEP" ] || report_failure "precondition: $STEP does not exist"

APP_SOURCE=$'"""A small module for the stub cases."""\n\nFIRST = 1\nSECOND = 2\nTHIRD = 3\n\n\ndef read_value():\n    """Return the first value."""\n    return FIRST\n'

# --- Shared repository: a PR adding app.py and notes.md ---------------------
REPO=$(new_repo pr-range)
write_file "$REPO" README.md $'# Base\n'
commit_all "$REPO" "base"
git_clean -C "$REPO" checkout -q -b feature
write_file "$REPO" app.py "$APP_SOURCE"
write_file "$REPO" notes.md $'# Notes\n'
commit_all "$REPO" "head"

# --- 1. A reported result -> exit 1 with an annotation (B-20) ---------------
run_step "$REPO" "$(make_stub result)" --mode pr --base main
expect_status "one result" 1
expect_annotation "one result" "::error file=app.py,line=7"

# --- 2. A clean report -> exit 0 (B-20) --------------------------------------
run_step "$REPO" "$(make_stub clean)" --mode pr --base main
expect_status "clean scan" 0

# --- 2b. A warn-level error only is not a failure (B-20: error-level only) --
run_step "$REPO" "$(make_stub warnonly)" --mode pr --base main
expect_status "warn-level error only" 0

# --- 3. An empty target list -> exit 0 without running Semgrep (B-20) -------
# head == base, so the PR changes nothing; the wired-in stand-in crashes, so
# running it would turn the exit non-zero.
EMPTY_REPO=$(new_repo empty-range)
write_file "$EMPTY_REPO" app.py "$APP_SOURCE"
commit_all "$EMPTY_REPO" "base"
run_step "$EMPTY_REPO" "$(make_stub crash)" --mode pr --base main
expect_status "empty target list" 0

# --- 4. Unreadable JSON -> exit 2 (B-20) -------------------------------------
run_step "$REPO" "$(make_stub nonjson)" --mode pr --base main
expect_fail_closed "non-JSON report"

# --- 5. Semgrep crashes (exit 7) -> exit 2 (B-20) ----------------------------
run_step "$REPO" "$(make_stub exit7)" --mode pr --base main
expect_fail_closed "Semgrep exit 7"

# --- 6. An error-level error -> exit 2 (B-20) --------------------------------
run_step "$REPO" "$(make_stub errorlevel)" --mode pr --base main
expect_fail_closed "error-level error"

# --- 7. A code target left unscanned -> exit 2 (B-20) ------------------------
run_step "$REPO" "$(make_stub omitpy)" --mode pr --base main
expect_fail_closed "unscanned .py target"

# --- 8. No Semgrep resolves -> exit 2 (B-20) ---------------------------------
# PATH carries only bash, git, and jq plus the system dirs, so neither
# semgrep nor uvx resolves whichever way a missing CLAUDE_SEMGREP_CMD is read.
TOOLS_DIR="$WORK/tools"
mkdir -p "$TOOLS_DIR"
ln -s "$(command -v bash)" "$TOOLS_DIR/bash"
ln -s "$(command -v git)" "$TOOLS_DIR/git"
ln -s "$(command -v jq)" "$TOOLS_DIR/jq"
BARE_PATH="$TOOLS_DIR:/usr/bin:/bin"
if PATH="$BARE_PATH" command -v semgrep >/dev/null 2>&1 || PATH="$BARE_PATH" command -v uvx >/dev/null 2>&1; then
  report_failure "precondition: semgrep or uvx still resolves on the stub PATH $BARE_PATH"
fi
STEP_PATH="$BARE_PATH"
run_step "$REPO" "$WORK/no-such-semgrep" --mode pr --base main
STEP_PATH="$PATH"
expect_fail_closed "Semgrep missing"

# --- 9. The lister fails (bad base) -> exit 2 even with a clean stub (B-20) -
run_step "$REPO" "$(make_stub clean)" --mode pr --base no-such-branch-anywhere
expect_fail_closed "lister failure"

# --- 12. Annotation escaping: a hostile path and message (B-20) -------------
# The result's path must be escaped as a property value and its message as
# data, so a newline in the message cannot start a second workflow command.
HOSTILE_REPO=$(new_repo hostile-path)
write_file "$HOSTILE_REPO" README.md $'# Base\n'
commit_all "$HOSTILE_REPO" "base"
git_clean -C "$HOSTILE_REPO" checkout -q -b feature
write_file "$HOSTILE_REPO" "a,b:c%d.py" "$APP_SOURCE"
commit_all "$HOSTILE_REPO" "hostile name"
run_step "$HOSTILE_REPO" "$(make_stub inject)" --mode pr --base main
expect_status "hostile path and message" 1
HOSTILE_PREFIX="::error file=a%2Cb%3Ac%25d.py,line="
HOSTILE_LINES=$(printf '%s\n' "$STEP_STDOUT" | awk -v p="$HOSTILE_PREFIX" 'index($0, p) == 1')
HOSTILE_COUNT=$(printf '%s' "$HOSTILE_LINES" | grep -c '^' || true)
[ "$HOSTILE_COUNT" -eq 1 ] \
  || report_failure "hostile path and message: stdout must hold exactly one line starting '$HOSTILE_PREFIX'; got $HOSTILE_COUNT in: ${STEP_STDOUT:-<none>}"
grep -qF -- '%0A::add-mask::x' <<< "$HOSTILE_LINES" \
  || report_failure "hostile path and message: the annotation must carry the message newline as %0A; got: ${HOSTILE_LINES:-<none>}"
if printf '%s\n' "$STEP_STDOUT" | grep -q '^::add-mask'; then
  report_failure "hostile path and message: no stdout line may start '::add-mask'; got: $STEP_STDOUT"
fi

# --- 10 and 11. The real Semgrep against the #27 shape (B-21, B-20) ---------
REAL_SEMGREP=""
if command -v semgrep >/dev/null 2>&1; then
  REAL_SEMGREP=semgrep
elif command -v uvx >/dev/null 2>&1; then
  REAL_SEMGREP="uvx semgrep"
fi
if [ -z "$REAL_SEMGREP" ]; then
  report_failure "precondition: neither semgrep nor uvx is on PATH; B-21 needs a real Semgrep run"
else
  REAL_REPO=$(new_repo real-semgrep)
  write_file "$REAL_REPO" README.md $'# Base\n'
  commit_all "$REAL_REPO" "base"
  git_clean -C "$REAL_REPO" checkout -q -b feature
  mkdir -p "$REAL_REPO/app"

  # 10. The bad sample -> exit 1 with an annotation naming the file.
  cp "$SAMPLES_DIR/cors-unvalidated-setting_bad.py" "$REAL_REPO/app/settings_cors.py"
  commit_all "$REAL_REPO" "bad cors setting"
  run_step "$REAL_REPO" "" --mode pr --base main
  expect_status "real Semgrep, #27 shape" 1
  expect_annotation "real Semgrep, #27 shape" "::error file=app/settings_cors.py,line=16"

  # 10b. The same file with `# nosemgrep` on every line -> still exit 1.
  sed 's/$/  # nosemgrep/' "$SAMPLES_DIR/cors-unvalidated-setting_bad.py" > "$REAL_REPO/app/settings_cors.py"
  commit_all "$REAL_REPO" "bad cors setting with nosemgrep"
  run_step "$REAL_REPO" "" --mode pr --base main
  expect_status "real Semgrep, #27 shape under nosemgrep" 1
  expect_annotation "real Semgrep, #27 shape under nosemgrep" "::error file=app/settings_cors.py,line=16"

  # 11. The good sample in its place -> exit 0.
  cp "$SAMPLES_DIR/cors-unvalidated-setting_good.py" "$REAL_REPO/app/settings_cors.py"
  commit_all "$REAL_REPO" "validated cors setting"
  run_step "$REAL_REPO" "" --mode pr --base main
  expect_status "real Semgrep, #45 shape" 0
fi

if [ "$failures" -gt 0 ]; then
  echo "security-ci-semgrep.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-ci-semgrep.test.sh PASS"
