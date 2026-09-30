#!/usr/bin/env bash
# Shard: slow
# Covers: ci:security-workflow
# Verifies the security CI Semgrep step, enforce/security-ci-semgrep.sh
# (IAN-381, spec Part 7 addendum, component 2, criteria B-20, B-21, B-24,
# B-26, B-27, and B-31 to B-33). The step runs with its working directory
# anywhere inside the repository to scan:
#
#   security-ci-semgrep.sh --mode pr --base <base-ref>
#   security-ci-semgrep.sh --mode full
#
# It takes its targets from the sibling lister enforce/security-ci-targets.sh
# (same arguments), resolves Semgrep through CLAUDE_SEMGREP_CMD, else `semgrep`
# on PATH, else `uvx semgrep`, and runs it with the harness rule pack
# (`--config <harness>/enforce/semgrep`) plus every config named in
# SECURITY_CI_REGISTRY_CONFIGS (space-separated, default "p/default"), with
# `--json --error --disable-nosem --no-git-ignore --metrics=off
# --max-target-bytes=0`, over a scratch export of the targets' HEAD content.
# The targets come after a literal `--` argument, so a file named like an
# option (`--severity=INFO`, `--exclude-rule=<id>`) is a file, never an option
# (B-24). Every `.semgrepignore` the PR supplies is removed from the scratch
# export and a `.gitignore` cannot hide a target (B-26). Every case here sets
# SECURITY_CI_REGISTRY_CONFIGS to the empty string or to a local rule file,
# so no network is needed.
#
# Exit codes: 0 on a clean scan or an empty target list; 1 when the report has
# results, printing one `::error file=<repo-relative path>,line=<start line>`
# workflow command per result on stdout, escaped the GitHub way (data escapes
# % CR LF as %25 %0D %0A; property values also escape : and , as %3A %2C);
# 2, failing closed with a message on stderr, when the lister exits non-zero,
# no Semgrep resolves, Semgrep exits other than 0 or 1, its stdout is not
# JSON, `.errors[]` holds an entry whose `.level` is "error", `.paths.skipped`
# holds any entry at all (B-26), or a code target (.py .ts .tsx .mts .cts .js
# .jsx .mjs .cjs .go .rb) is missing from `.paths.scanned`. Every value from
# Semgrep's report that reaches stdout or stderr, diagnostics included, is
# escaped for GitHub's workflow-command parser (B-27), so no line the step
# prints can start a workflow command Semgrep's report smuggled in.
#
# Semgrep's own stderr is captured and, on any non-clean exit, relayed line
# by line under the fixed prefix `security-ci-semgrep: semgrep stderr: `,
# escaped as workflow-command data (B-32). The step works from any
# subdirectory of the repository and hands Semgrep the same
# repository-relative targets as from the root (B-33).
#
# Each target is exported as its exact committed blob, so no `.gitattributes`
# entry (export-ignore, export-subst, eol conversion) changes or drops what is
# scanned, and a target that is a symlink or a submodule fails the step
# closed, named on stderr, before Semgrep runs (B-37). When Semgrep exits 2 or
# above, the step prints each entry of the report's `.errors[]`, escaped, so a
# crash names its cause (B-38).
#
# Cases 1 to 9, 12, 13 to 16, 21, 22, 24 to 27, and 29 drive the step through
# Semgrep stand-ins wired in with CLAUDE_SEMGREP_CMD. Cases 10, 11, 17 to 20,
# 23, and 28 run the real Semgrep (`semgrep` on PATH, else `uvx semgrep`)
# against the #27-shaped CORS sample, and the fixture fails rather than skips
# when neither resolves. Case 23 puts the sample under tests/, vendor/, and
# node_modules/, which Semgrep ignores by default (B-31).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
export CLAUDE_HARNESS_ROOT
STEP="$CLAUDE_HARNESS_ROOT/enforce/security-ci-semgrep.sh"
RULES_DIR="$CLAUDE_HARNESS_ROOT/enforce/semgrep"
SAMPLES_DIR="$CLAUDE_HARNESS_ROOT/enforce/tests/testdata/semgrep"
BAD_SAMPLE="$SAMPLES_DIR/cors-unvalidated-setting_bad.py.sample"
BASH_BIN=$(command -v bash)
unset CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
STUB_ARGV_FILE="$WORK/stub-argv.txt"
STUB_CAPTURE_DIR="$WORK/stub-capture"

# run_git_isolated <args...>: runs git with every GIT_* location variable
# stripped, so a fixture run from inside a hook or a worktree never touches the
# outer repo.
run_git_isolated() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR git "$@"
}

# create_repo <name>: creates a throwaway repository on branch main and prints
# its path.
create_repo() {
  local repo="$WORK/$1"
  mkdir -p "$repo"
  run_git_isolated -C "$repo" init -q --initial-branch=main
  run_git_isolated -C "$repo" config user.email t@t
  run_git_isolated -C "$repo" config user.name t
  run_git_isolated -C "$repo" config commit.gpgsign false
  printf '%s' "$repo"
}

# write_file <repo> <relative path> <content>: writes the file, creating its
# directories.
write_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
}

# commit_all_changes <repo> <message>: commits every change in the repository.
commit_all_changes() {
  run_git_isolated -C "$1" add -A
  run_git_isolated -C "$1" commit -q --allow-empty -m "$2"
}

# create_feature_repo <name>: creates a repository whose main holds README.md
# and checks out a new branch `feature`, then prints its path.
create_feature_repo() {
  local repo
  repo=$(create_repo "$1")
  write_file "$repo" README.md $'# Base\n'
  commit_all_changes "$repo" "base"
  run_git_isolated -C "$repo" checkout -q -b feature
  printf '%s' "$repo"
}

# make_stub <mode>: writes a Semgrep stand-in for the mode and prints its path.
# The stand-in reads the targets it was given (everything after `--`, or every
# non-option argument that is not an option's value), expands a directory
# target into its files the way Semgrep reports them, and prints a report:
#   crash         garbage on stdout, exit 99, before looking at any target
#   clean         no results, no errors, every target scanned, exit 0
#   record        as clean, and writes its argv, one argument per line, to
#                 STUB_ARGV_FILE first
#   warnonly      as clean, plus one warn-level error, exit 0
#   result        one result at line 7 of the first scanned .py file, exit 1
#   inject        as result, with a message carrying a newline and a workflow
#                 command, exit 1
#   nonjson       text that is not JSON, exit 0
#   exit7         a clean report, exit 7
#   errorlevel    no results, one error-level error, exit 0
#   errorinject   no results, one error-level error whose message carries a
#                 newline and a workflow command, exit 0
#   omitpy        no results, every target scanned except the .py files, exit 0
#   skipnoncode   no results, every target scanned, plus one `paths.skipped`
#                 entry for the non-code target Dockerfile, exit 0
#   stderrinject  before looking at any target, writes three lines to stderr
#                 (`::add-mask::x`, `::error::fake stub diagnostic`, `100%`),
#                 prints text that is not JSON on stdout, and exits 7
#   capture       as clean, and first copies the bytes of every target after
#                 `--` (read from its working directory, the scratch export)
#                 to the same relative path under STUB_CAPTURE_DIR
#   crashreport   before looking at any target, prints a valid JSON report
#                 with no results, one error-level SemgrepError whose message
#                 is "Invalid scanning root: x", a newline, and
#                 "::add-mask::y", and an empty scanned list, then exits 2
make_stub() {
  local mode="$1" stub_path="$WORK/semgrep-stub-$1"
  {
    printf '#!/usr/bin/env bash\nSTUB_MODE=%s\nSTUB_ARGV_FILE=%s\nSTUB_CAPTURE_DIR=%s\n' \
      "$mode" "$STUB_ARGV_FILE" "$STUB_CAPTURE_DIR"
    cat <<'STUB'
if [ "$STUB_MODE" = record ]; then
  printf '%s\n' "$@" > "$STUB_ARGV_FILE"
fi
if [ "$STUB_MODE" = crashreport ]; then
  jq -n --arg message $'Invalid scanning root: x\n::add-mask::y' \
    '{results: [], errors: [{level: "error", type: "SemgrepError", message: $message}], paths: {scanned: []}}'
  exit 2
fi
if [ "$STUB_MODE" = capture ]; then
  capture_after_dashes=0
  for arg in "$@"; do
    if [ "$capture_after_dashes" = 1 ]; then
      mkdir -p "$STUB_CAPTURE_DIR/$(dirname "$arg")"
      cat "$arg" > "$STUB_CAPTURE_DIR/$arg"
    fi
    [ "$arg" = -- ] && capture_after_dashes=1
  done
fi
if [ "$STUB_MODE" = stderrinject ]; then
  printf '%s\n' '::add-mask::x' '::error::fake stub diagnostic' '100%' >&2
  echo "stub stdout that is not json {{{"
  exit 7
fi
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
  clean|record|exit7|omitpy|capture)
    jq -n --argjson scanned "$scanned_json" '{results: [], errors: [], paths: {scanned: $scanned}}' ;;
  warnonly)
    jq -n --argjson scanned "$scanned_json" \
      '{results: [], errors: [{level: "warn", type: "PartialParsing", message: "stub warning"}], paths: {scanned: $scanned}}' ;;
  errorlevel)
    jq -n --argjson scanned "$scanned_json" \
      '{results: [], errors: [{level: "error", message: "x"}], paths: {scanned: $scanned}}' ;;
  errorinject)
    jq -n --argjson scanned "$scanned_json" --arg message $'stub error\n::add-mask::x' \
      '{results: [], errors: [{level: "error", type: "StubError", message: $message}], paths: {scanned: $scanned}}' ;;
  skipnoncode)
    jq -n --argjson scanned "$scanned_json" \
      '{results: [], errors: [], paths: {scanned: $scanned, skipped: [{path: "Dockerfile", reason: "too_big"}]}}' ;;
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
# stripped, SECURITY_CI_REGISTRY_CONFIGS set to STEP_REGISTRY_CONFIGS (empty
# unless a case sets it), and PATH set to STEP_PATH. Sets STEP_STDOUT,
# STEP_STDERR, and STEP_STATUS.
STEP_PATH="$PATH"
STEP_REGISTRY_CONFIGS=""
run_step() {
  local repo="$1" semgrep_command="$2"
  shift 2
  local out_file="$WORK/step.out" err_file="$WORK/step.err"
  (
    cd "$repo" || exit 96
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR CLAUDE_SEMGREP_CMD
    if [ -n "$semgrep_command" ]; then export CLAUDE_SEMGREP_CMD="$semgrep_command"; fi
    export SECURITY_CI_REGISTRY_CONFIGS="$STEP_REGISTRY_CONFIGS"
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

# expect_closed_failure <label>: the last run must exit 2 and explain itself
# on stderr.
expect_closed_failure() {
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
REPO=$(create_feature_repo pr-range)
write_file "$REPO" app.py "$APP_SOURCE"
write_file "$REPO" notes.md $'# Notes\n'
commit_all_changes "$REPO" "head"

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
EMPTY_REPO=$(create_repo empty-range)
write_file "$EMPTY_REPO" app.py "$APP_SOURCE"
commit_all_changes "$EMPTY_REPO" "base"
run_step "$EMPTY_REPO" "$(make_stub crash)" --mode pr --base main
expect_status "empty target list" 0

# --- 4. Unreadable JSON -> exit 2 (B-20) -------------------------------------
run_step "$REPO" "$(make_stub nonjson)" --mode pr --base main
expect_closed_failure "non-JSON report"

# --- 5. Semgrep crashes (exit 7) -> exit 2 (B-20) ----------------------------
run_step "$REPO" "$(make_stub exit7)" --mode pr --base main
expect_closed_failure "Semgrep exit 7"

# --- 6. An error-level error -> exit 2 (B-20) --------------------------------
run_step "$REPO" "$(make_stub errorlevel)" --mode pr --base main
expect_closed_failure "error-level error"

# --- 7. A code target left unscanned -> exit 2 (B-20) ------------------------
run_step "$REPO" "$(make_stub omitpy)" --mode pr --base main
expect_closed_failure "unscanned .py target"

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
expect_closed_failure "Semgrep missing"

# --- 9. The lister fails (bad base) -> exit 2 even with a clean stub (B-20) -
run_step "$REPO" "$(make_stub clean)" --mode pr --base no-such-branch-anywhere
expect_closed_failure "lister failure"

# --- 12. Annotation escaping: a hostile path and message (B-20) -------------
# The result's path must be escaped as a property value and its message as
# data, so a newline in the message cannot start a second workflow command.
HOSTILE_REPO=$(create_feature_repo hostile-path)
write_file "$HOSTILE_REPO" "a,b:c%d.py" "$APP_SOURCE"
commit_all_changes "$HOSTILE_REPO" "hostile name"
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

# --- 13. A skipped non-code target -> exit 2 (B-26) --------------------------
# Any entry in `paths.skipped` fails the step closed, not only a code target's:
# here the stand-in scans every target but reports the Dockerfile skipped as
# too big, with no results.
SKIP_REPO=$(create_feature_repo skipped-noncode)
write_file "$SKIP_REPO" Dockerfile $'FROM scratch\n'
write_file "$SKIP_REPO" app.py "$APP_SOURCE"
commit_all_changes "$SKIP_REPO" "add a Dockerfile and app.py"
run_step "$SKIP_REPO" "$(make_stub skipnoncode)" --mode pr --base main
expect_closed_failure "skipped non-code target"

# --- 14. An error message carrying a workflow command is escaped (B-27) -----
# The error-level error fails the step closed, and the diagnostic that names
# it escapes the message's newline as %0A, so no line of stdout or stderr can
# start `::add-mask`.
run_step "$REPO" "$(make_stub errorinject)" --mode pr --base main
expect_closed_failure "error message carrying a workflow command"
grep -qF -- '%0A::add-mask::x' <<< "$STEP_STDERR" \
  || report_failure "error message carrying a workflow command: stderr must carry the message newline escaped as '%0A::add-mask::x'; got: ${STEP_STDERR:-<none>}"
if printf '%s\n%s\n' "$STEP_STDOUT" "$STEP_STDERR" | grep -q '^::add-mask'; then
  report_failure "error message carrying a workflow command: no stdout or stderr line may start '::add-mask'; got stdout: ${STEP_STDOUT:-<none>}; stderr: ${STEP_STDERR:-<none>}"
fi

# --- 15. Full mode passes every tracked file after `--` (B-19, B-24) --------
FULL_REPO=$(create_repo full-mode)
write_file "$FULL_REPO" alpha.py "$APP_SOURCE"
write_file "$FULL_REPO" beta.md $'# Beta\n'
commit_all_changes "$FULL_REPO" "two tracked files"
rm -f "$STUB_ARGV_FILE"
run_step "$FULL_REPO" "$(make_stub record)" --mode full
expect_status "full mode, clean" 0
if [ -f "$STUB_ARGV_FILE" ]; then
  ARGV_AFTER_DASHES=$(awk 'seen_dashes { print } $0 == "--" { seen_dashes = 1 }' "$STUB_ARGV_FILE")
  grep -qFx -- '--' "$STUB_ARGV_FILE" \
    || report_failure "full mode, clean: Semgrep's argv must hold a literal '--'; got: $(tr '\n' ' ' < "$STUB_ARGV_FILE")"
  for tracked_file in alpha.py beta.md; do
    grep -qE -- "(^|/)$tracked_file\$" <<< "$ARGV_AFTER_DASHES" \
      || report_failure "full mode, clean: '$tracked_file' must be a Semgrep target after '--'; got after '--': [$(printf '%s' "$ARGV_AFTER_DASHES" | tr '\n' '|')]"
  done
else
  report_failure "full mode, clean: the Semgrep stand-in must have run and recorded its argv"
fi

# --- 21. Semgrep's own stderr never reaches the runner raw (B-32) -----------
# The stand-in writes two workflow commands and a bare `%` to stderr, prints
# text that is not JSON, and exits 7. The step fails closed, no line it prints
# on stdout or stderr starts either workflow command, and it relays each of
# Semgrep's stderr lines under the fixed prefix `security-ci-semgrep: semgrep
# stderr: `, escaped as workflow-command data (`%` as `%25`).
# Failure messages flatten the captured output onto one line joined by `|`,
# so the fixture's own report never starts a line with a workflow command.
STDERR_PREFIX="security-ci-semgrep: semgrep stderr: "
run_step "$REPO" "$(make_stub stderrinject)" --mode pr --base main
FLAT_STDOUT=$(printf '%s' "$STEP_STDOUT" | tr '\n' '|')
FLAT_STDERR=$(printf '%s' "$STEP_STDERR" | tr '\n' '|')
[ "$STEP_STATUS" -eq 2 ] \
  || report_failure "Semgrep stderr carrying workflow commands: step must exit 2; got $STEP_STATUS (stdout: [$FLAT_STDOUT]; stderr: [$FLAT_STDERR])"
if printf '%s\n%s\n' "$STEP_STDOUT" "$STEP_STDERR" | grep -qE '^(::add-mask|::error::fake)'; then
  report_failure "Semgrep stderr carrying workflow commands: no stdout or stderr line may start '::add-mask' or '::error::fake'; got stdout: [$FLAT_STDOUT]; stderr: [$FLAT_STDERR]"
fi
for relayed_line in '::add-mask::x' '::error::fake stub diagnostic' '100%25'; do
  [ -n "$(printf '%s\n' "$STEP_STDERR" | awk -v p="$STDERR_PREFIX$relayed_line" 'index($0, p) == 1')" ] \
    || report_failure "Semgrep stderr carrying workflow commands: stderr must hold a line starting '$STDERR_PREFIX$relayed_line'; got: [$FLAT_STDERR]"
done

# --- 22. Run from a subdirectory: the same repository-relative targets (B-33)
# The step runs once from the repository root and once from its app/
# directory; both runs must exit 0 and hand Semgrep exactly the targets
# app/x.py and lib.py after `--`.
NESTED_REPO=$(create_feature_repo nested-cwd)
write_file "$NESTED_REPO" app/x.py "$APP_SOURCE"
write_file "$NESTED_REPO" lib.py "$APP_SOURCE"
commit_all_changes "$NESTED_REPO" "add app/x.py and lib.py"
NESTED_EXPECTED=$(printf '%s\n' app/x.py lib.py | LC_ALL=C sort)
for nested_cwd in "$NESTED_REPO" "$NESTED_REPO/app"; do
  rm -f "$STUB_ARGV_FILE"
  run_step "$nested_cwd" "$(make_stub record)" --mode pr --base main
  expect_status "run from $nested_cwd" 0
  if [ -f "$STUB_ARGV_FILE" ]; then
    NESTED_TARGETS=$(awk 'seen_dashes { print } $0 == "--" { seen_dashes = 1 }' "$STUB_ARGV_FILE" | LC_ALL=C sort)
    [ "$NESTED_TARGETS" = "$NESTED_EXPECTED" ] \
      || report_failure "run from $nested_cwd: Semgrep's targets after '--' must be exactly [$(printf '%s' "$NESTED_EXPECTED" | tr '\n' '|')]; got [$(printf '%s' "$NESTED_TARGETS" | tr '\n' '|')]"
  else
    report_failure "run from $nested_cwd: the Semgrep stand-in must have run and recorded its argv"
  fi
done

# expect_captured_blob <label> <repo> <path>: the bytes the capture stand-in
# received for <path> must be identical to the committed blob HEAD:<path>.
expect_captured_blob() {
  local label="$1" repo="$2" blob_path="$3" expected_file="$WORK/expected-blob"
  run_git_isolated -C "$repo" cat-file blob "HEAD:$blob_path" > "$expected_file"
  if [ ! -f "$STUB_CAPTURE_DIR/$blob_path" ]; then
    report_failure "$label: the Semgrep stand-in must have received '$blob_path' as a target file"
  elif ! cmp -s "$expected_file" "$STUB_CAPTURE_DIR/$blob_path"; then
    report_failure "$label: the scanned bytes of '$blob_path' must equal 'git cat-file blob HEAD:$blob_path'; expected [$(od -c < "$expected_file" | tr '\n' '|')], got [$(od -c < "$STUB_CAPTURE_DIR/$blob_path" | tr '\n' '|')]"
  fi
}

# --- 24. `export-subst` in the PR's .gitattributes cannot rewrite a target (B-37)
# The PR adds `* export-subst` and a sub.py holding a `$Format:%H$`
# placeholder. The scanned bytes must be the committed blob, placeholder
# intact, not the commit hash an attribute-honoring export substitutes.
SUBST_REPO=$(create_feature_repo export-subst)
write_file "$SUBST_REPO" .gitattributes $'* export-subst\n'
write_file "$SUBST_REPO" sub.py $'x = "$Format:%H$"\n'
commit_all_changes "$SUBST_REPO" "export-subst attribute and a placeholder"
[ "$(run_git_isolated -C "$SUBST_REPO" cat-file blob HEAD:sub.py)" = 'x = "$Format:%H$"' ] \
  || report_failure "precondition: the committed sub.py must hold the \$Format:%H\$ placeholder"
rm -rf "$STUB_CAPTURE_DIR"
run_step "$SUBST_REPO" "$(make_stub capture)" --mode pr --base main
expect_status "export-subst attribute" 0
expect_captured_blob "export-subst attribute" "$SUBST_REPO" sub.py

# --- 25. An eol=crlf attribute cannot rewrite a target's line endings (B-37)
# The PR adds `*.py text eol=crlf` and an LF-only lines.py. The scanned bytes
# must be the committed LF-only blob, with no carriage return added.
CRLF_REPO=$(create_feature_repo eol-crlf)
write_file "$CRLF_REPO" .gitattributes $'*.py text eol=crlf\n'
write_file "$CRLF_REPO" lines.py $'FIRST = 1\nSECOND = 2\nTHIRD = 3\n'
commit_all_changes "$CRLF_REPO" "eol=crlf attribute and an LF-only file"
if run_git_isolated -C "$CRLF_REPO" cat-file blob HEAD:lines.py | LC_ALL=C grep -q $'\r'; then
  report_failure "precondition: the committed lines.py must hold no carriage return"
fi
rm -rf "$STUB_CAPTURE_DIR"
run_step "$CRLF_REPO" "$(make_stub capture)" --mode pr --base main
expect_status "eol=crlf attribute" 0
expect_captured_blob "eol=crlf attribute" "$CRLF_REPO" lines.py
if [ -f "$STUB_CAPTURE_DIR/lines.py" ] && LC_ALL=C grep -q $'\r' "$STUB_CAPTURE_DIR/lines.py"; then
  report_failure "eol=crlf attribute: the scanned lines.py must hold no carriage return"
fi

# --- 26. A symlink target fails the step closed and is named (B-37) ---------
# The PR adds real.py and a symlink link.py pointing at it. The stand-in is
# clean, so the only possible failure is the export refusing the symlink.
SYMLINK_REPO=$(create_feature_repo symlink-target)
write_file "$SYMLINK_REPO" real.py "$APP_SOURCE"
ln -s real.py "$SYMLINK_REPO/link.py"
commit_all_changes "$SYMLINK_REPO" "a real file and a symlink to it"
[ "$(run_git_isolated -C "$SYMLINK_REPO" ls-tree HEAD link.py | awk '{ print $1 }')" = 120000 ] \
  || report_failure "precondition: link.py must be committed as a symlink (mode 120000)"
run_step "$SYMLINK_REPO" "$(make_stub clean)" --mode pr --base main
expect_closed_failure "symlink target"
grep -qF -- 'link.py' <<< "$STEP_STDERR" \
  || report_failure "symlink target: stderr must name 'link.py'; got: ${STEP_STDERR:-<none>}"
grep -qi -- 'symlink' <<< "$STEP_STDERR" \
  || report_failure "symlink target: stderr must say 'symlink'; got: ${STEP_STDERR:-<none>}"

# --- 29. A submodule target fails the step closed and is named (B-37) -------
# The PR adds plain.py and a gitlink `vendored` (mode 160000) pointing at the
# base commit. The gitlink is staged with update-index and committed without
# `add -A`, which would drop it for want of a checkout. The stand-in records
# its argv and is otherwise clean, so the only possible failure is the export
# refusing the submodule; that refusal must come before Semgrep runs.
SUBMODULE_REPO=$(create_feature_repo submodule-target)
write_file "$SUBMODULE_REPO" plain.py "$APP_SOURCE"
run_git_isolated -C "$SUBMODULE_REPO" add plain.py
SUBMODULE_POINTER=$(run_git_isolated -C "$SUBMODULE_REPO" rev-parse HEAD)
run_git_isolated -C "$SUBMODULE_REPO" update-index --add --cacheinfo "160000,$SUBMODULE_POINTER,vendored"
run_git_isolated -C "$SUBMODULE_REPO" commit -q -m "a plain file and a submodule gitlink"
[ "$(run_git_isolated -C "$SUBMODULE_REPO" ls-tree HEAD vendored | awk '{ print $1 }')" = 160000 ] \
  || report_failure "precondition: vendored must be committed as a gitlink (mode 160000)"
rm -f "$STUB_ARGV_FILE"
run_step "$SUBMODULE_REPO" "$(make_stub record)" --mode pr --base main
expect_closed_failure "submodule target"
grep -qF -- 'vendored' <<< "$STEP_STDERR" \
  || report_failure "submodule target: stderr must name 'vendored'; got: ${STEP_STDERR:-<none>}"
grep -qi -- 'submodule' <<< "$STEP_STDERR" \
  || report_failure "submodule target: stderr must say 'submodule'; got: ${STEP_STDERR:-<none>}"
if [ -s "$STUB_ARGV_FILE" ]; then
  report_failure "submodule target: Semgrep must not run once the export refuses a submodule; it ran with: $(tr '\n' ' ' < "$STUB_ARGV_FILE")"
fi

# --- 27. A Semgrep crash names its cause from the report's errors (B-38) ----
# The stand-in exits 2 with a valid report whose one error-level error says
# "Invalid scanning root: x" and smuggles a workflow command after a newline.
# The step fails closed, prints the error's message on stderr escaped for the
# workflow-command parser, and no line it prints starts `::add-mask`.
run_step "$REPO" "$(make_stub crashreport)" --mode pr --base main
CRASH_FLAT_STDOUT=$(printf '%s' "$STEP_STDOUT" | tr '\n' '|')
CRASH_FLAT_STDERR=$(printf '%s' "$STEP_STDERR" | tr '\n' '|')
[ "$STEP_STATUS" -eq 2 ] \
  || report_failure "Semgrep crash report: step must exit 2; got $STEP_STATUS (stdout: [$CRASH_FLAT_STDOUT]; stderr: [$CRASH_FLAT_STDERR])"
grep -qF -- 'Invalid scanning root: x' <<< "$STEP_STDERR" \
  || report_failure "Semgrep crash report: stderr must carry the error message 'Invalid scanning root: x'; got: [$CRASH_FLAT_STDERR]"
grep -qF -- '%0A::add-mask::y' <<< "$STEP_STDERR" \
  || report_failure "Semgrep crash report: stderr must carry the message newline escaped as '%0A::add-mask::y'; got: [$CRASH_FLAT_STDERR]"
if printf '%s\n%s\n' "$STEP_STDOUT" "$STEP_STDERR" | grep -q '^::add-mask'; then
  report_failure "Semgrep crash report: no stdout or stderr line may start '::add-mask'; got stdout: [$CRASH_FLAT_STDOUT]; stderr: [$CRASH_FLAT_STDERR]"
fi

# --- 10, 11, 17 to 20, 23. The real Semgrep against the #27 shape ---------------
REAL_SEMGREP=""
if command -v semgrep >/dev/null 2>&1; then
  REAL_SEMGREP=semgrep
elif command -v uvx >/dev/null 2>&1; then
  REAL_SEMGREP="uvx semgrep"
fi
if [ -z "$REAL_SEMGREP" ]; then
  report_failure "precondition: neither semgrep nor uvx is on PATH; B-21 needs a real Semgrep run"
else
  REAL_REPO=$(create_feature_repo real-semgrep)
  mkdir -p "$REAL_REPO/app"

  # 10. The bad sample -> exit 1 with an annotation naming the file (B-21).
  cp "$BAD_SAMPLE" "$REAL_REPO/app/settings_cors.py"
  commit_all_changes "$REAL_REPO" "bad cors setting"
  run_step "$REAL_REPO" "" --mode pr --base main
  expect_status "real Semgrep, #27 shape" 1
  expect_annotation "real Semgrep, #27 shape" "::error file=app/settings_cors.py,line=16"

  # 10b. The same file with `# nosemgrep` on every line -> still exit 1.
  sed 's/$/  # nosemgrep/' "$BAD_SAMPLE" > "$REAL_REPO/app/settings_cors.py"
  commit_all_changes "$REAL_REPO" "bad cors setting with nosemgrep"
  run_step "$REAL_REPO" "" --mode pr --base main
  expect_status "real Semgrep, #27 shape under nosemgrep" 1
  expect_annotation "real Semgrep, #27 shape under nosemgrep" "::error file=app/settings_cors.py,line=16"

  # 11. The good sample in its place -> exit 0.
  cp "$SAMPLES_DIR/cors-unvalidated-setting_good.py.sample" "$REAL_REPO/app/settings_cors.py"
  commit_all_changes "$REAL_REPO" "validated cors setting"
  run_step "$REAL_REPO" "" --mode pr --base main
  expect_status "real Semgrep, #45 shape" 0

  # 17. A file named `--severity=INFO` beside the #27 sample (B-24). Were the
  # name read as an option, Semgrep would run only INFO rules; the local
  # INFO-only rule file keeps that run from failing for want of rules.
  INFO_RULE_FILE="$(mktemp "$WORK/info-rule.XXXXXX")"
  mv "$INFO_RULE_FILE" "$INFO_RULE_FILE.yml"
  INFO_RULE_FILE="$INFO_RULE_FILE.yml"
  printf '%s\n' 'rules:' '  - id: fixture-info-only' '    languages: [python]' '    severity: INFO' \
    '    message: fixture rule that never matches' \
    '    pattern: fixture_function_that_appears_nowhere(...)' > "$INFO_RULE_FILE"
  SEVERITY_REPO=$(create_feature_repo severity-option-name)
  write_file "$SEVERITY_REPO" --severity=INFO $'x = 1\n'
  mkdir -p "$SEVERITY_REPO/app"
  cp "$BAD_SAMPLE" "$SEVERITY_REPO/app/settings_cors.py"
  commit_all_changes "$SEVERITY_REPO" "bad cors setting beside an option-shaped name"
  [ -f "$SEVERITY_REPO/--severity=INFO" ] || report_failure "precondition: the file '--severity=INFO' must exist"
  STEP_REGISTRY_CONFIGS="$INFO_RULE_FILE"
  run_step "$SEVERITY_REPO" "" --mode pr --base main
  STEP_REGISTRY_CONFIGS=""
  expect_status "real Semgrep, file named --severity=INFO" 1
  expect_annotation "real Semgrep, file named --severity=INFO" "::error file=app/settings_cors.py,line=16"

  # 18. A file named `--exclude-rule=<id>` naming the rule that flags line 16
  # of the #27 sample (B-24). The id is derived from a real Semgrep run over
  # the sample from a fresh scratch directory, the way the step runs it, so
  # it is the id Semgrep would honor.
  DERIVE_DIR=$(mktemp -d)
  cp "$BAD_SAMPLE" "$DERIVE_DIR/settings_cors.py"
  CORS_CHECK_ID=$(cd "$DERIVE_DIR" && $REAL_SEMGREP --config "$RULES_DIR" --json --metrics=off \
    --disable-version-check --quiet "settings_cors.py" \
    | jq -r 'first(.results[] | select(.start.line == 16) | .check_id) // empty')
  rm -rf "$DERIVE_DIR"
  case "$CORS_CHECK_ID" in
    *cors-unvalidated-setting*) ;;
    *) report_failure "precondition: could not derive the check_id flagging line 16 of the #27 sample; got '$CORS_CHECK_ID'" ;;
  esac
  EXCLUDE_REPO=$(create_feature_repo exclude-option-name)
  write_file "$EXCLUDE_REPO" "--exclude-rule=$CORS_CHECK_ID" $'x = 1\n'
  mkdir -p "$EXCLUDE_REPO/app"
  cp "$BAD_SAMPLE" "$EXCLUDE_REPO/app/settings_cors.py"
  commit_all_changes "$EXCLUDE_REPO" "bad cors setting beside an exclude-rule name"
  [ -f "$EXCLUDE_REPO/--exclude-rule=$CORS_CHECK_ID" ] \
    || report_failure "precondition: the file '--exclude-rule=$CORS_CHECK_ID' must exist"
  run_step "$EXCLUDE_REPO" "" --mode pr --base main
  expect_status "real Semgrep, file named --exclude-rule=<id>" 1
  expect_annotation "real Semgrep, file named --exclude-rule=<id>" "::error file=app/settings_cors.py,line=16"

  # 19. A nested .semgrepignore the PR supplies cannot hide the sample (B-26).
  IGNORE_REPO=$(create_feature_repo nested-semgrepignore)
  write_file "$IGNORE_REPO" app/sub/.semgrepignore $'*.py\n'
  cp "$BAD_SAMPLE" "$IGNORE_REPO/app/sub/cors.py"
  commit_all_changes "$IGNORE_REPO" "bad cors setting under a semgrepignore"
  run_step "$IGNORE_REPO" "" --mode pr --base main
  expect_status "real Semgrep, nested .semgrepignore" 1
  expect_annotation "real Semgrep, nested .semgrepignore" "::error file=app/sub/cors.py,line=16"

  # 20. A .gitignore the PR supplies cannot hide the sample (B-26). The sample
  # is force-added, since the .gitignore names it.
  GITIGNORE_REPO=$(create_feature_repo gitignore-hides)
  write_file "$GITIGNORE_REPO" .gitignore $'cors.py\n'
  cp "$BAD_SAMPLE" "$GITIGNORE_REPO/cors.py"
  run_git_isolated -C "$GITIGNORE_REPO" add -f cors.py
  commit_all_changes "$GITIGNORE_REPO" "bad cors setting under a gitignore"
  [ -n "$(run_git_isolated -C "$GITIGNORE_REPO" ls-files cors.py)" ] \
    || report_failure "precondition: cors.py must be tracked despite the .gitignore"
  run_step "$GITIGNORE_REPO" "" --mode pr --base main
  expect_status "real Semgrep, .gitignore names the sample" 1
  expect_annotation "real Semgrep, .gitignore names the sample" "::error file=cors.py,line=16"

  # 23. The sample under directories Semgrep ignores by default (B-31). The
  # copies are force-added so no global excludes file can keep them untracked.
  DEFAULT_IGNORED_REPO=$(create_feature_repo default-ignored-dirs)
  for ignored_path in tests/cors.py vendor/cors.py node_modules/pkg/cors.py; do
    mkdir -p "$(dirname "$DEFAULT_IGNORED_REPO/$ignored_path")"
    cp "$BAD_SAMPLE" "$DEFAULT_IGNORED_REPO/$ignored_path"
    run_git_isolated -C "$DEFAULT_IGNORED_REPO" add -f -- "$ignored_path"
    [ -n "$(run_git_isolated -C "$DEFAULT_IGNORED_REPO" ls-files -- "$ignored_path")" ] \
      || report_failure "precondition: $ignored_path must be tracked"
  done
  commit_all_changes "$DEFAULT_IGNORED_REPO" "bad cors setting under default-ignored directories"
  run_step "$DEFAULT_IGNORED_REPO" "" --mode pr --base main
  expect_status "real Semgrep, default-ignored directories" 1
  for ignored_path in tests/cors.py vendor/cors.py node_modules/pkg/cors.py; do
    expect_annotation "real Semgrep, $ignored_path" "::error file=$ignored_path,line=16"
  done

  # 28. An `export-ignore` attribute on the base cannot drop a target (B-37).
  # The base commit's .gitattributes says `app/ export-ignore`; the PR adds
  # the #27 sample under app/. An attribute-honoring export leaves app/ out
  # and Semgrep crashes on a missing scanning root; the step must scan the
  # committed bytes and report the finding.
  EXPORT_IGNORE_REPO=$(create_repo export-ignore-base)
  write_file "$EXPORT_IGNORE_REPO" .gitattributes $'app/ export-ignore\n'
  write_file "$EXPORT_IGNORE_REPO" README.md $'# Base\n'
  commit_all_changes "$EXPORT_IGNORE_REPO" "base with app/ export-ignore"
  run_git_isolated -C "$EXPORT_IGNORE_REPO" checkout -q -b feature
  mkdir -p "$EXPORT_IGNORE_REPO/app"
  cp "$BAD_SAMPLE" "$EXPORT_IGNORE_REPO/app/settings_cors.py"
  commit_all_changes "$EXPORT_IGNORE_REPO" "bad cors setting under an export-ignored directory"
  run_step "$EXPORT_IGNORE_REPO" "" --mode pr --base main
  expect_status "real Semgrep, app/ export-ignore on the base" 1
  expect_annotation "real Semgrep, app/ export-ignore on the base" "::error file=app/settings_cors.py,line=16"
fi

if [ "$failures" -gt 0 ]; then
  echo "security-ci-semgrep.test.sh FAIL ($failures)"
  exit 1
fi
echo "security-ci-semgrep.test.sh PASS"
