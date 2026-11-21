#!/usr/bin/env bash
# Covers: enforce/style-check.sh
# Watches: .github/workflows/enforce.yml README.md
# style-check.test.sh: verifies the PR-scoped shell style check.
#
#   style-check.sh [--base <ref>] [--repo <dir>]
#
# Defaults: base origin/main, repo the current directory. The script reads
# `git diff --unified=0 <base>...HEAD` in the repo and checks only the lines
# the change adds, in every *.sh file except paths with a tests/ directory
# segment and anything under node_modules/. Checks:
#   1. width: `<file>:<line>:line is <n> columns (max 100)` for n > 100
#   2. comment block: `<file>:<line>:function <name> has no comment block above it`
#      when the line above an added function definition is not a comment
#   3. shellcheck -S warning -x -f gcc findings on added lines, keeping the
#      SC code; when shellcheck is missing, stderr gets
#      `style-check: warning: shellcheck not installed, skipped` and the
#      other checks still run
# Stdout is one violation per line, sorted by file then line, then
# `style-check: <n> violation(s)`; a clean run prints only `style-check: ok`.
# Exit 0 clean, 1 violations, 2 usage error.
#
# Method: every case builds its own throwaway git repository under $WORK with
# a base commit on `main` and the change committed on a `feature` branch, and
# runs the script with --repo and --base main from $WORK. HOME and the git
# global config point into $WORK, so no user config, hook or .shellcheckrc
# is read and the real repository is never touched.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/style-check.sh"
REPO_ROOT=$(cd -P "$CLAUDE_HARNESS_ROOT/.." && pwd -P)
WORKFLOW="$REPO_ROOT/.github/workflows/enforce.yml"
README="$CLAUDE_HARNESS_ROOT/enforce/README.md"

# A hook or caller may export GIT_DIR and friends; they must not leak into the
# fixture repositories (global memory: lesson_strip_git_env_in_hook_tests).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX

# Prints the failure and stops the run.
failCase() {
  echo "FAIL: $1"
  exit 1
}

[ -f "$SCRIPT" ] || failCase "the style-check script does not exist at $SCRIPT (not implemented yet)"

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
: >"$WORK/gitconfig"
export HOME="$WORK/home"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="style-check test" GIT_AUTHOR_EMAIL="style-check@example.invalid"
export GIT_COMMITTER_NAME="style-check test" GIT_COMMITTER_EMAIL="style-check@example.invalid"

HAVE_SHELLCHECK=0
command -v shellcheck >/dev/null 2>&1 && HAVE_SHELLCHECK=1

# makeLine <n>: prints a shell comment line exactly n columns wide.
makeLine() {
  local fill
  fill=$(printf '%*s' "$(($1 - 2))" '' | tr ' ' x)
  printf '# %s' "$fill"
}

# newRepo <name>: creates an empty repository on branch main at $WORK/<name>
# and sets REPO to it.
newRepo() {
  REPO="$WORK/$1"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
}

# writeFile <path> <line>...: writes the lines to <path> under $REPO,
# creating parent directories.
writeFile() {
  local file_path="$REPO/$1"
  shift
  mkdir -p "$(dirname "$file_path")"
  printf '%s\n' "$@" >"$file_path"
}

# commitAll <message>: stages everything in $REPO and commits it.
commitAll() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q --no-verify -m "$1"
}

# startFeature: commits the base on main, then moves to a feature branch.
startFeature() {
  commitAll base
  git -C "$REPO" checkout -q -b feature
}

# runCheck <args...>: runs the script from $WORK with a 60 s alarm; sets RC,
# OUT (stdout) and ERR (stderr).
runCheck() {
  RC=0
  (cd "$WORK" && perl -e 'alarm 60; exec @ARGV' bash "$SCRIPT" "$@") \
    >"$WORK/out" 2>"$WORK/err" || RC=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
  [ "$RC" -ne 142 ] || failCase "style-check $* did not finish within 60 s"
}

# checkRepo: runs the script on $REPO against main.
checkRepo() {
  runCheck --repo "$REPO" --base main
}

# expectClean <what>: the last run exited 0 and printed exactly style-check: ok.
expectClean() {
  [ "$RC" -eq 0 ] || failCase "$1: want exit 0, got $RC (stdout: '$OUT', stderr: '$ERR')"
  [ "$OUT" = "style-check: ok" ] || failCase "$1: stdout must be exactly 'style-check: ok' (got '$OUT')"
}

# expectViolations <what>: the last run exited 1.
expectViolations() {
  [ "$RC" -eq 1 ] || failCase "$1: want exit 1, got $RC (stdout: '$OUT', stderr: '$ERR')"
}

# outHasLine <line> <what>: stdout of the last run has that exact line.
outHasLine() {
  printf '%s\n' "$OUT" | grep -qxF -- "$1" || failCase "$2: stdout must have the line '$1' (got '$OUT')"
}

# outLacks <text> <what>: stdout of the last run does not contain text.
outLacks() {
  if printf '%s\n' "$OUT" | grep -qF -- "$1"; then
    failCase "$2: stdout must not mention '$1' (got '$OUT')"
  fi
}

# expectUsage <what>: the last run exited 2 with a message on stderr.
expectUsage() {
  [ "$RC" -eq 2 ] || failCase "$1: want exit 2, got $RC (stdout: '$OUT', stderr: '$ERR')"
  [ -n "$ERR" ] || failCase "$1: a usage error must explain itself on stderr"
}

# --- a. A clean change: a short line and a documented function. ---
newRepo a-clean
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base' 'echo added' \
  '# Says hello.' 'sayHello() {' '  echo hi' '}' 'sayHello'
commitAll change
checkRepo
expectClean "a. clean change"

# --- b. Width: 101 columns fails with the right line, 100 passes. ---
newRepo b-wide
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo one' 'echo two'
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo one' 'echo two' "$(makeLine 101)"
commitAll change
checkRepo
expectViolations "b. 101-column line"
outHasLine "lib/a.sh:4:line is 101 columns (max 100)" "b. 101-column line"
outHasLine "style-check: 1 violation(s)" "b. 101-column line"

newRepo b-edge
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo one'
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo one' "$(makeLine 100)"
commitAll change
checkRepo
expectClean "b. 100-column line"

# --- c. Ratchet: old debt is not flagged; an edited debt line is. ---
newRepo c-ratchet
writeFile lib/a.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'echo before' 'noDoc() {' '  echo old' '}' 'noDoc'
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'echo before' 'noDoc() {' '  echo old' '}' 'noDoc' 'echo new'
commitAll change
checkRepo
expectClean "c. untouched 150-column line and undocumented function"

newRepo c-edited
writeFile lib/a.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'echo before' 'noDoc() {' '  echo old' '}' 'noDoc'
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' "$(makeLine 150 | sed 's/x$/y/')" 'echo before' 'noDoc() {' '  echo old' '}' 'noDoc'
commitAll change
checkRepo
expectViolations "c. edited 150-column line"
outHasLine "lib/a.sh:2:line is 150 columns (max 100)" "c. edited 150-column line"
outLacks "noDoc" "c. edited 150-column line (the function line is untouched)"

# --- d. Function comment blocks. ---
newRepo d-missing
writeFile lib/f.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/f.sh '#!/usr/bin/env bash' 'echo base' \
  '' \
  'blankAbove() {' '  echo b' '}' \
  'echo between' \
  'codeAbove() {' '  echo c' '}' \
  '# Outer is documented.' \
  'outerFn() {' '  innerFn() {' '    echo in' '  }' '  innerFn' '}' \
  'echo kw' \
  'function keywordFn {' '  echo k' '}' \
  'echo kwp' \
  'function keywordParen() {' '  echo p' '}' \
  'blankAbove' 'codeAbove' 'outerFn' 'keywordFn' 'keywordParen'
commitAll change
checkRepo
expectViolations "d. functions without a comment block"
outHasLine "lib/f.sh:4:function blankAbove has no comment block above it" "d. blank line above"
outHasLine "lib/f.sh:8:function codeAbove has no comment block above it" "d. code line above"
outHasLine "lib/f.sh:13:function innerFn has no comment block above it" "d. indented nested function"
outHasLine "lib/f.sh:19:function keywordFn has no comment block above it" "d. function name { form"
outHasLine "lib/f.sh:23:function keywordParen has no comment block above it" "d. function name() { form"
outLacks "outerFn" "d. a function with a comment line directly above"

newRepo d-documented
writeFile lib/f.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/f.sh '#!/usr/bin/env bash' 'echo base' \
  '# Plain form.' 'plainFn() {' '  echo b' '}' \
  '# Outer.' 'outerFn() {' '  # Inner, indented comment.' '  innerFn() {' '    echo in' '  }' '  innerFn' '}' \
  '# Keyword form.' 'function keywordFn {' '  echo k' '}' \
  '# Keyword form with parentheses.' 'function keywordParen() {' '  echo p' '}' \
  'plainFn' 'outerFn' 'keywordFn' 'keywordParen'
commitAll change
checkRepo
expectClean "d. every function form with a comment line directly above"

# --- e. shellcheck findings on added lines only. ---
if [ "$HAVE_SHELLCHECK" = 1 ]; then
  newRepo e-shellcheck
  writeFile lib/s.sh '#!/usr/bin/env bash' 'echo base' 'echo more'
  startFeature
  writeFile lib/s.sh '#!/usr/bin/env bash' 'echo base' 'echo more' 'echo next' 'cd /tmp' 'echo done'
  commitAll change
  checkRepo
  expectViolations "e. added cd without || exit (SC2164)"
  printf '%s\n' "$OUT" | grep -q '^lib/s\.sh:5:.*SC2164' \
    || failCase "e. stdout must report lib/s.sh:5 with SC2164 (got '$OUT')"

  newRepo e-ratchet
  writeFile lib/s.sh '#!/usr/bin/env bash' 'cd /tmp' 'echo base'
  startFeature
  writeFile lib/s.sh '#!/usr/bin/env bash' 'cd /tmp' 'echo base' 'echo new'
  commitAll change
  checkRepo
  expectClean "e. SC2164 on an untouched line"
else
  echo "SKIP: e. shellcheck cases (shellcheck not installed)"
fi

# --- e2. shellcheck missing: warn on stderr, other checks still run. ---
# A PATH of links to every tool on the real PATH except shellcheck.
NOSC="$WORK/path-without-shellcheck"
mkdir -p "$NOSC"
OLD_IFS=$IFS
IFS=:
for path_dir in $PATH; do
  [ -d "$path_dir" ] || continue
  for tool in "$path_dir"/*; do
    name=${tool##*/}
    [ "$name" = shellcheck ] && continue
    [ -e "$NOSC/$name" ] || [ ! -x "$tool" ] || ln -s "$tool" "$NOSC/$name"
  done
done
IFS=$OLD_IFS
# runWithoutShellcheck <args...>: runCheck with shellcheck off the PATH.
runWithoutShellcheck() {
  RC=0
  (cd "$WORK" && PATH="$NOSC" perl -e 'alarm 60; exec @ARGV' bash "$SCRIPT" "$@") \
    >"$WORK/out" 2>"$WORK/err" || RC=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
  [ "$RC" -ne 142 ] || failCase "style-check $* did not finish within 60 s"
}
WARN_LINE="style-check: warning: shellcheck not installed, skipped"

newRepo e2-missing
writeFile lib/s.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/s.sh '#!/usr/bin/env bash' 'echo base' 'cd /tmp' "$(makeLine 101)"
commitAll change
runWithoutShellcheck --repo "$REPO" --base main
expectViolations "e2. shellcheck missing, width still checked"
printf '%s\n' "$ERR" | grep -qxF -- "$WARN_LINE" \
  || failCase "e2. stderr must have the line '$WARN_LINE' (got '$ERR')"
outHasLine "lib/s.sh:4:line is 101 columns (max 100)" "e2. shellcheck missing"
outHasLine "style-check: 1 violation(s)" "e2. shellcheck missing (no shellcheck finding counted)"

newRepo e2-only-shellcheck
writeFile lib/s.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/s.sh '#!/usr/bin/env bash' 'echo base' 'cd /tmp'
commitAll change
runWithoutShellcheck --repo "$REPO" --base main
expectClean "e2. shellcheck missing, the skipped check does not fail the run"
printf '%s\n' "$ERR" | grep -qxF -- "$WARN_LINE" \
  || failCase "e2. stderr must have the line '$WARN_LINE' (got '$ERR')"

# --- f. Out-of-scope files are ignored. ---
newRepo f-scope
writeFile README.md 'base'
startFeature
writeFile docs/notes.md "$(makeLine 150)"
writeFile tests/x.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'cd /tmp' 'noDocTest() {' '  echo t' '}'
writeFile pkg/tests/w.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'cd /tmp' 'noDocNested() {' '  echo t' '}'
writeFile node_modules/y.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'cd /tmp' 'noDocModule() {' '  echo t' '}'
writeFile pkg/node_modules/z.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'cd /tmp'
commitAll change
checkRepo
expectClean "f. .md, tests/ and node_modules/ files"

# --- g. Usage errors. ---
newRepo g-usage
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base' "$(makeLine 120)"
commitAll change

runCheck --repo "$REPO" --base no-such-ref
expectUsage "g. --base no-such-ref"
[ -z "$OUT" ] || failCase "g. --base no-such-ref: stdout must be empty (got '$OUT')"

runCheck --repo "$REPO" --base "main:lib/a.sh"
expectUsage "g. --base naming a blob, not a commit"
[ -z "$OUT" ] || failCase "g. --base naming a blob: stdout must be empty (got '$OUT')"

runCheck --repo "$REPO" --base main --bogus
expectUsage "g. unknown flag"

runCheck --repo "$REPO" --base
expectUsage "g. --base with no value"

mkdir -p "$WORK/not-a-repo"
runCheck --repo "$WORK/not-a-repo" --base main
expectUsage "g. --repo that is not a git repository"

runCheck --repo "$WORK/no-such-dir" --base main
expectUsage "g. --repo that does not exist"

# Defaults: the current directory and origin/main.
git -C "$REPO" update-ref refs/remotes/origin/main main
RC=0
(cd "$REPO" && perl -e 'alarm 60; exec @ARGV' bash "$SCRIPT") >"$WORK/out" 2>"$WORK/err" || RC=$?
OUT=$(cat "$WORK/out")
ERR=$(cat "$WORK/err")
expectViolations "g. defaults (repo = cwd, base = origin/main)"
outHasLine "lib/a.sh:3:line is 120 columns (max 100)" "g. defaults"

# --- h. Every violation reported, sorted by file then line, counted. ---
newRepo h-many
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo one' 'echo two'
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' "$(makeLine 120)" 'echo two' \
  'late() {' '  echo l' '}' 'late' 'echo pad' "$(makeLine 105)" "$(makeLine 106)"
writeFile lib/b.sh '#!/usr/bin/env bash' "$(makeLine 101)"
commitAll change
checkRepo
expectViolations "h. several violations"
EXPECTED="lib/a.sh:2:line is 120 columns (max 100)
lib/a.sh:4:function late has no comment block above it
lib/a.sh:9:line is 105 columns (max 100)
lib/a.sh:10:line is 106 columns (max 100)
lib/b.sh:2:line is 101 columns (max 100)
style-check: 5 violation(s)"
[ "$OUT" = "$EXPECTED" ] || failCase "h. stdout must be exactly:
$EXPECTED
got:
$OUT"

# --- i. Deletions and a pure rename add nothing to check. ---
newRepo i-delete
writeFile lib/a.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'echo keep' 'cd /tmp' 'noDoc() {' '  echo x' '}'
writeFile lib/gone.sh '#!/usr/bin/env bash' "$(makeLine 150)"
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo keep'
git -C "$REPO" rm -q lib/gone.sh
commitAll change
checkRepo
expectClean "i. deleted lines and a deleted file"

newRepo i-rename
writeFile lib/old.sh '#!/usr/bin/env bash' "$(makeLine 150)" 'echo body' 'noDoc() {' '  echo x' '}' 'noDoc'
startFeature
git -C "$REPO" mv lib/old.sh lib/new.sh
commitAll change
checkRepo
expectClean "i. a renamed file with no content change (its old debt is not added lines)"

# --- j. CI runs the check on pull requests. ---
[ -f "$WORKFLOW" ] || failCase "j. the workflow $WORKFLOW must exist"
grep -qF 'style-check.sh' "$WORKFLOW" || failCase "j. enforce.yml must run style-check.sh"
grep 'style-check.sh' "$WORKFLOW" | grep -F -- '--base' | grep -qF 'origin/${{ github.base_ref }}' \
  || failCase "j. enforce.yml must pass --base origin/\${{ github.base_ref }} to style-check.sh on the same line"
# The step holding style-check.sh: from its "- " list item to the next one.
STEP=$(awk '
  /^[[:space:]]*- / { if (found) exit; block = "" }
  { block = block $0 "\n" }
  /style-check\.sh/ { found = 1 }
  END { if (found) printf "%s", block }
' "$WORKFLOW")
printf '%s\n' "$STEP" | grep -qF "if: github.event_name == 'pull_request'" \
  || failCase "j. the style-check step must have if: github.event_name == 'pull_request' (step: $STEP)"
CHECKOUT=$(awk '
  /^[[:space:]]*- / { if (found) exit; block = "" }
  { block = block $0 "\n" }
  /uses: actions\/checkout/ { found = 1 }
  END { if (found) printf "%s", block }
' "$WORKFLOW")
printf '%s\n' "$CHECKOUT" | grep -qE 'fetch-depth:[[:space:]]*0([[:space:]]|$)' \
  || failCase "j. the checkout step must set fetch-depth: 0 (step: $CHECKOUT)"

# --- k. The README lists the script. ---
grep -qE '^- .*`style-check\.sh`' "$README" || failCase "k. claude/enforce/README.md must list \`style-check.sh\` in its file list"

# --- l. Fail closed when git cannot diff against the base. ---
# Two unrelated root commits: main and an orphan feature branch share no
# merge base, so `git diff main...HEAD` cannot run.
newRepo l-orphan
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base'
commitAll base
git -C "$REPO" checkout -q --orphan feature
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo other root' "$(makeLine 101)"
commitAll change
checkRepo
expectUsage "l. --base with no merge base (orphan feature branch)"
[ -z "$OUT" ] || failCase "l. no merge base: stdout must be empty (got '$OUT')"

# A shallow clone that holds only the two branch tips: the base commit is a
# commit, but no common ancestor is in the shallow history.
newRepo l-shallow-src
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base' "$(makeLine 101)"
commitAll change
git -C "$REPO" checkout -q main
writeFile lib/b.sh '#!/usr/bin/env bash' 'echo main moved on'
commitAll "main moves on"
git -C "$REPO" checkout -q feature
SHALLOW="$WORK/l-shallow"
git clone -q --depth 1 --no-single-branch "file://$REPO" "$SHALLOW"
git -C "$SHALLOW" rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null \
  || failCase "l. fixture: the shallow clone must have origin/main"
runCheck --repo "$SHALLOW" --base origin/main
expectUsage "l. --base with no common ancestor in a shallow clone"
[ -z "$OUT" ] || failCase "l. shallow clone: stdout must be empty (got '$OUT')"

# --- m. Diff parsing: content that looks like a header, unusual paths. ---
# Added lines `++ x` and `++ b/evil.sh` show in the diff as `+++ x` and
# `+++ b/evil.sh`; they are content, not file headers.
newRepo m-plus-content
writeFile lib/p.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/p.sh '#!/usr/bin/env bash' 'echo base' \
  "cat <<'EOF'" '++ x' '++ b/evil.sh' '+++ b/also.sh' 'EOF' \
  "$(makeLine 101)" 'echo spacer' \
  'noDocAfter() {' '  echo n' '}' 'noDocAfter'
commitAll change
checkRepo
expectViolations "m. content lines that look like +++ headers"
outHasLine "lib/p.sh:8:line is 101 columns (max 100)" "m. width after +++ content lines"
outHasLine "lib/p.sh:10:function noDocAfter has no comment block above it" \
  "m. function after +++ content lines"
outLacks "evil.sh" "m. a +++ b/ content line is not a file name"
outLacks "also.sh" "m. a ++++ b/ content line is not a file name"

# A path with a space: git ends the +++ header with a tab.
newRepo m-space-path
writeFile 'lib/my file.sh' '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile 'lib/my file.sh' '#!/usr/bin/env bash' 'echo base' "$(makeLine 101)" 'cd /tmp'
commitAll change
checkRepo
expectViolations "m. a path with a space"
outHasLine "lib/my file.sh:3:line is 101 columns (max 100)" "m. a path with a space"
if [ "$HAVE_SHELLCHECK" = 1 ]; then
  printf '%s\n' "$OUT" | grep -q '^lib/my file\.sh:4:.*SC2164' \
    || failCase "m. a path with a space: stdout must report lib/my file.sh:4 with SC2164 (got '$OUT')"
fi

# A path git quotes: report it with the real path, or refuse with exit 2;
# never skip it silently.
newRepo m-quoted-path
writeFile 'lib/q"x.sh' '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile 'lib/q"x.sh' '#!/usr/bin/env bash' 'echo base' "$(makeLine 101)"
commitAll change
checkRepo
case "$RC" in
  1) outHasLine 'lib/q"x.sh:3:line is 101 columns (max 100)' "m. a path git quotes" ;;
  2) [ -n "$ERR" ] || failCase "m. a path git quotes: exit 2 must explain itself on stderr" ;;
  *) failCase "m. a path git quotes: want exit 1 (reported) or 2 (refused), got $RC (stdout: '$OUT', stderr: '$ERR')" ;;
esac

# --- n. Function definitions with the brace on the next line. ---
newRepo n-brace-next
writeFile lib/n.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/n.sh '#!/usr/bin/env bash' 'echo base' \
  'echo pad' 'nextLine()' '{' '  echo n' '}' \
  'echo pad2' 'function kwNext' '{' '  echo k' '}' \
  'nextLine' 'kwNext'
commitAll change
checkRepo
expectViolations "n. functions with { on the next line and no comment block"
outHasLine "lib/n.sh:4:function nextLine has no comment block above it" "n. name() then { on the next line"
outHasLine "lib/n.sh:9:function kwNext has no comment block above it" "n. function name then { on the next line"

newRepo n-brace-next-doc
writeFile lib/n.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/n.sh '#!/usr/bin/env bash' 'echo base' \
  '# Documented.' 'nextLine()' '{' '  echo n' '}' \
  '# Documented keyword form.' 'function kwNext' '{' '  echo k' '}' \
  'nextLine' 'kwNext'
commitAll change
checkRepo
expectClean "n. documented functions with { on the next line"

# --- o. Width counts leading tabs as characters. ---
TAB=$(printf '\t')
newRepo o-tab
writeFile lib/t.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/t.sh '#!/usr/bin/env bash' 'echo base' "${TAB}$(makeLine 100)"
commitAll change
checkRepo
expectViolations "o. a tab plus 100 characters"
outHasLine "lib/t.sh:3:line is 101 columns (max 100)" "o. a tab plus 100 characters"

newRepo o-tab-edge
writeFile lib/t.sh '#!/usr/bin/env bash' 'echo base'
startFeature
writeFile lib/t.sh '#!/usr/bin/env bash' 'echo base' "${TAB}$(makeLine 99)"
commitAll change
checkRepo
expectClean "o. a tab plus 99 characters"

# --- p. The checked scope is documented. ---
# The header: the leading block of comment lines.
HEADER=$(awk '/^#/ { print; next } { exit }' "$SCRIPT")
for want in '*.sh' 'tests/' 'node_modules/'; do
  printf '%s\n' "$HEADER" | grep -qF -- "$want" \
    || failCase "p. the header comment of style-check.sh must mention '$want' (header: $HEADER)"
done
grep -F '`style-check.sh`' "$README" | grep -qF '*.sh' \
  || failCase "p. the style-check.sh line in claude/enforce/README.md must mention '*.sh'"

# --- q. Repo git config must not change the diff the script parses. ---
# diff.noprefix, diff.mnemonicPrefix and diff.external alter `git diff`
# output; the script must report the same violations regardless (it must
# never fall back to `style-check: ok` because it could not read the headers).
Q_EXPECTED="lib/a.sh:3:line is 101 columns (max 100)
lib/a.sh:5:function noDoc has no comment block above it
style-check: 2 violation(s)"

# qRepo <name> [<key> <value>]...: builds a repo whose change adds a
# 101-column line (line 3) and an undocumented function (line 5) to lib/a.sh,
# sets each repo-local git config pair, runs the script and checks the output.
qRepo() {
  local name=$1
  shift
  newRepo "$name"
  writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base'
  startFeature
  writeFile lib/a.sh '#!/usr/bin/env bash' 'echo base' "$(makeLine 101)" 'echo pad' \
    'noDoc() {' '  echo n' '}' 'noDoc'
  commitAll change
  while [ $# -ge 2 ]; do
    git -C "$REPO" config "$1" "$2"
    shift 2
  done
  checkRepo
  expectViolations "q. $name"
  [ "$OUT" = "$Q_EXPECTED" ] || failCase "q. $name: stdout must be exactly:
$Q_EXPECTED
got:
$OUT"
}

qRepo q-control
qRepo q-noprefix diff.noprefix true
qRepo q-mnemonic diff.mnemonicPrefix true
qRepo q-external diff.external /bin/echo
qRepo q-all diff.noprefix true diff.mnemonicPrefix true diff.external /bin/echo

echo "PASS: style-check"
