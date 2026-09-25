#!/usr/bin/env bash
# Verifies the B-6b hardening of push-semgrep-gate.sh (IAN-381, R-517 review of
# PR #141). The gate must fail closed on a partial scan (any Semgrep error,
# PartialParsing included, or any skipped path), must ignore `# nosemgrep`
# suppressions, must judge the pushed HEAD content rather than the working
# tree, must deny when the outgoing base cannot be resolved (naming the
# CLAUDE_ENFORCE_BASE override), must scan .cjs, .jsx, .mts and .cts files, must
# keep honoring the exempt-repos list, and must run Semgrep with its version
# check and nosem handling disabled. Every deny reason starts with R-109.
#
# Each case builds its own throwaway repository under one mktemp directory.
# The hook runs with HOME pointed at a scratch directory that holds no exempt
# list, so a developer's real ~/.claude/enforce/exempt-repos.txt cannot change
# the outcome; only the exempt case writes one. The uv cache and Python
# install directories are passed through explicitly so `uvx semgrep` under the
# scratch HOME reuses the machine's existing install instead of downloading.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-semgrep-gate.sh"
SAMPLES_DIR="$CLAUDE_HARNESS_ROOT/enforce/tests/testdata/semgrep"
unset CLAUDE_ENFORCE_BASE CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }
report_ok() { echo "ok: $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

UV_CACHE_PASSTHROUGH="${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/uv}"
UV_PYTHON_PASSTHROUGH="${UV_PYTHON_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/python}"

# A scratch HOME with no exempt list, shared by every case but the exempt one.
PLAIN_HOME="$WORK/home-plain"
mkdir -p "$PLAIN_HOME"

# The real Semgrep, resolved at test time the way the hook resolves it.
if command -v semgrep >/dev/null 2>&1; then
  REAL_SEMGREP="$(command -v semgrep)"
elif command -v uvx >/dev/null 2>&1; then
  REAL_SEMGREP="$(command -v uvx) semgrep"
else
  REAL_SEMGREP=""
  report_failure "precondition: neither semgrep nor uvx resolves on PATH, so the rule pack cannot run"
fi

# make_repo <dir> <branch>: a fresh repository on <branch> with one empty
# commit, and origin/main pinned to that commit so the outgoing base resolves.
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
}

# commit_file <repo> <path> <source file>: copies <source file> to <path>
# inside <repo> and commits it.
commit_file() {
  local repo="$1" path="$2" source="$3"
  mkdir -p "$(dirname "$repo/$path")"
  cp "$source" "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -q -m "add $path"
}

push_payload() {
  jq -cn --arg cwd "$1" --arg cmd "git push origin $2" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}'
}

# run_hook <repo> <branch> [VAR=value ...]: runs the hook from inside <repo>
# on a push payload, with HOME at the plain scratch home unless an assignment
# overrides it, and prints its stdout.
run_hook() {
  local repo="$1" branch="$2"; shift 2
  (cd "$repo" && push_payload "$repo" "$branch" | env HOME="$PLAIN_HOME" \
    UV_CACHE_DIR="$UV_CACHE_PASSTHROUGH" UV_PYTHON_INSTALL_DIR="$UV_PYTHON_PASSTHROUGH" \
    "$@" "$HOOK" 2>/dev/null)
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

# expect_deny <label> <output> <needle>...: asserts a deny whose reason
# contains R-109 and every needle as a fixed substring.
expect_deny() {
  local label="$1" output="$2"; shift 2
  local reason needle before="$failures"
  if [ "$(decision_of "$output")" != "deny" ]; then
    report_failure "$label: expected permissionDecision deny; got: ${output:-<no output>}"
    return
  fi
  reason=$(reason_of "$output")
  grep -qF -- "R-109" <<< "$reason" \
    || report_failure "$label: the deny reason must contain R-109; got: $reason"
  for needle in "$@"; do
    grep -qF -- "$needle" <<< "$reason" \
      || report_failure "$label: the deny reason must contain '$needle'; got: $reason"
  done
  [ "$failures" -eq "$before" ] && report_ok "$label"
}

expect_silent() {
  local label="$1" output="$2"
  if [ -n "$output" ]; then
    report_failure "$label: expected no output (allow); got: $output"
  else
    report_ok "$label"
  fi
}

# 1. Partial scan: the literal-wildcard bad shape followed, about twelve lines
# later, by a Python syntax error. Semgrep reports an error (PartialParsing or
# a syntax error) instead of a clean result set, and the gate must deny naming
# the path rather than read the empty results as clean.
PARTIAL_SOURCE="$WORK/partial.py"
cat "$SAMPLES_DIR/cors-literal-wildcard_bad.py" > "$PARTIAL_SOURCE"
printf '\n\n\n\n\n\n\n\n\n\n\ndef broken(:\n    pass\n' >> "$PARTIAL_SOURCE"
REPO_PARTIAL="$WORK/repo-partial"
make_repo "$REPO_PARTIAL" main
commit_file "$REPO_PARTIAL" app/partial.py "$PARTIAL_SOURCE"
OUT_PARTIAL=$(run_hook "$REPO_PARTIAL" main)
expect_deny "1 partial scan (Semgrep error or skipped path)" "$OUT_PARTIAL" "app/partial.py"

# 2. A `# nosemgrep` comment on the add_middleware( line must not hide the
# finding: the gate passes --disable-nosem.
NOSEM_SOURCE="$WORK/nosem.py"
sed 's/^app\.add_middleware($/app.add_middleware(  # nosemgrep/' \
  "$SAMPLES_DIR/cors-literal-wildcard_bad.py" > "$NOSEM_SOURCE"
if ! grep -qF 'app.add_middleware(  # nosemgrep' "$NOSEM_SOURCE"; then
  report_failure "precondition: the nosemgrep sample did not receive its comment"
fi
REPO_NOSEM="$WORK/repo-nosem"
make_repo "$REPO_NOSEM" main
commit_file "$REPO_NOSEM" app/main.py "$NOSEM_SOURCE"
OUT_NOSEM=$(run_hook "$REPO_NOSEM" main)
expect_deny "2 nosemgrep suppression ignored" "$OUT_NOSEM" "app/main.py" "cors-literal-wildcard"

# 3a. HEAD carries the #27 shape and the working tree holds an uncommitted
# fix. The push ships HEAD, so it must be denied.
REPO_DIRTY="$WORK/repo-dirty"
make_repo "$REPO_DIRTY" main
commit_file "$REPO_DIRTY" app/core/settings.py "$SAMPLES_DIR/cors-unvalidated-setting_bad.py"
cp "$SAMPLES_DIR/cors-unvalidated-setting_good.py" "$REPO_DIRTY/app/core/settings.py"
OUT_DIRTY=$(run_hook "$REPO_DIRTY" main)
expect_deny "3a HEAD scanned, not the uncommitted fix" "$OUT_DIRTY" \
  "app/core/settings.py:16" "cors-unvalidated-setting"

# 3b. A file changed in the range is deleted from the working tree but not
# from HEAD. The push is judged on HEAD's content, which carries a finding,
# so the reason names that finding, not a Semgrep crash.
REPO_DELETED="$WORK/repo-deleted"
make_repo "$REPO_DELETED" main
commit_file "$REPO_DELETED" app/removed.py "$SAMPLES_DIR/cors-literal-wildcard_bad.py"
rm "$REPO_DELETED/app/removed.py"
OUT_DELETED=$(run_hook "$REPO_DELETED" main)
expect_deny "3b file deleted from the working tree, present in HEAD" "$OUT_DELETED" \
  "app/removed.py" "cors-literal-wildcard"
if grep -qiF "crash" <<< "$(reason_of "$OUT_DELETED")"; then
  report_failure "3b: the reason must name the rule finding, not a Semgrep crash; got: $(reason_of "$OUT_DELETED")"
fi

# 4. No resolvable outgoing base: no origin/* refs, no main or master, no
# upstream, and no CLAUDE_ENFORCE_BASE. The gate must deny and name the
# override instead of passing silently.
REPO_NOBASE="$WORK/repo-nobase"
mkdir -p "$REPO_NOBASE"
git -C "$REPO_NOBASE" init -q
git -C "$REPO_NOBASE" symbolic-ref HEAD refs/heads/feature
git -C "$REPO_NOBASE" config user.email t@t
git -C "$REPO_NOBASE" config user.name t
commit_file "$REPO_NOBASE" app/main.py "$SAMPLES_DIR/cors-literal-wildcard_bad.py"
if [ -n "$(git -C "$REPO_NOBASE" for-each-ref refs/remotes refs/heads/main refs/heads/master)" ]; then
  report_failure "precondition: the no-base repository still carries a remote, main, or master ref"
fi
OUT_NOBASE=$(run_hook "$REPO_NOBASE" feature)
expect_deny "4 unresolvable outgoing base" "$OUT_NOBASE" "CLAUDE_ENFORCE_BASE"

# 5. A CommonJS server file carrying the literal-wildcard CORS shape. The
# gate must scan .cjs (and .jsx, .mts, .cts), so the push is denied.
CJS_SOURCE="$WORK/server.cjs"
printf 'const cors = require("cors");\nconst express = require("express");\n\nconst app = express();\n\napp.use(cors({ origin: "*", credentials: true }));\n\nmodule.exports = app;\n' > "$CJS_SOURCE"
REPO_CJS="$WORK/repo-cjs"
make_repo "$REPO_CJS" main
commit_file "$REPO_CJS" server.cjs "$CJS_SOURCE"
OUT_CJS=$(run_hook "$REPO_CJS" main)
expect_deny "5 .cjs file scanned" "$OUT_CJS" "server.cjs" "cors-literal-wildcard"

# 6. Exempt list regression pin: a repository whose origin URL is listed in
# the scratch HOME's exempt-repos.txt pushes silently even with a finding in
# range. The control run with the plain HOME must deny, so the silence comes
# from the exemption, not from a clean scan.
EXEMPT_ORIGIN="https://example.invalid/acme/exempt-probe.git"
REPO_EXEMPT="$WORK/repo-exempt"
make_repo "$REPO_EXEMPT" main
git -C "$REPO_EXEMPT" remote add origin "$EXEMPT_ORIGIN"
commit_file "$REPO_EXEMPT" app/main.py "$SAMPLES_DIR/cors-literal-wildcard_bad.py"
EXEMPT_HOME="$WORK/home-exempt"
mkdir -p "$EXEMPT_HOME/.claude/enforce"
printf '%s\n' "$EXEMPT_ORIGIN" > "$EXEMPT_HOME/.claude/enforce/exempt-repos.txt"
OUT_EXEMPT_CONTROL=$(run_hook "$REPO_EXEMPT" main)
expect_deny "6 control: the same repository without the exempt list" "$OUT_EXEMPT_CONTROL" "cors-literal-wildcard"
OUT_EXEMPT=$(run_hook "$REPO_EXEMPT" main HOME="$EXEMPT_HOME")
expect_silent "6 exempt repository" "$OUT_EXEMPT"

# 7. Semgrep runs with --disable-version-check and --disable-nosem. A stub
# records its argv, one argument per line, then delegates to the real Semgrep.
ARGV_FILE="$WORK/semgrep-argv.txt"
RECORDING_STUB="$WORK/recording-semgrep"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s"\nexec %s "$@"\n' "$ARGV_FILE" "$REAL_SEMGREP" > "$RECORDING_STUB"
chmod +x "$RECORDING_STUB"
REPO_ARGV="$WORK/repo-argv"
make_repo "$REPO_ARGV" main
commit_file "$REPO_ARGV" app/main.py "$SAMPLES_DIR/cors-literal-wildcard_bad.py"
: > "$ARGV_FILE"
run_hook "$REPO_ARGV" main CLAUDE_SEMGREP_CMD="$RECORDING_STUB" >/dev/null
if [ ! -s "$ARGV_FILE" ]; then
  report_failure "7: the Semgrep stub was never invoked, so no argv was recorded"
else
  argv_before="$failures"
  for flag in --disable-version-check --disable-nosem; do
    grep -qxF -- "$flag" "$ARGV_FILE" \
      || report_failure "7: Semgrep must be run with $flag; recorded argv: $(tr '\n' ' ' < "$ARGV_FILE")"
  done
  [ "$failures" -eq "$argv_before" ] && report_ok "7 Semgrep argv carries --disable-version-check and --disable-nosem"
fi

if [ "$failures" -gt 0 ]; then
  echo "push-semgrep-gate-hardening.test.sh FAIL ($failures)"
  exit 1
fi
echo "push-semgrep-gate-hardening.test.sh PASS"
