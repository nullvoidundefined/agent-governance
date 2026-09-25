#!/usr/bin/env bash
# Verifies the B-6f behavior of push-semgrep-gate.sh (IAN-381, R-517 review
# findings N6 and N7 on PR #141).
#
# N6, the trust boundary: the Python parse check may run the pushed
# repository's own <repo>/.venv/bin/python3 only when the repository's origin
# URL is listed in $HOME/.claude/enforce/gate-trusted-repos.txt, the same
# opt-in push-golangci-gate.sh uses. Otherwise it uses python3 on PATH, so a
# linter never executes a binary the target repository ships.
#   (a) Untrusted: the repository's .venv/bin/python3 is a stub that writes a
#       marker file and exits 0, and the pushed app/models.py has a syntax
#       error. The marker must not exist afterwards (the repository binary
#       never ran), and the push must deny as "does not parse".
#   (b) Trusted: the origin URL is listed, .venv/bin/python3 execs the real
#       python3, the pushed file is valid modern Python (a match statement),
#       and a stub python3 first on PATH fails any ast.parse. The push must be
#       allowed, which proves the trusted .venv interpreter decided.
#
# N7, each deny branch of the report parsing, pinned separately with a stub
# Semgrep (CLAUDE_SEMGREP_CMD) over a clean app/x.py:
#   (c) exit 0 with a result lacking check_id and start: the findings read
#       fails, and the gate must deny "could not read Semgrep's findings".
#   (d) exit 1 with an empty result list: the gate must deny "exited 1".
#
# Every case runs the hook with HOME at a scratch directory and gives each
# throwaway repository an origin URL. Every case uses a stub Semgrep, so no
# real Semgrep or network is involved. Everything lives under one mktemp dir.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-semgrep-gate.sh"
unset CLAUDE_ENFORCE_BASE CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }
report_ok() { echo "ok: $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A scratch HOME with no exempt list and no trusted list.
PLAIN_HOME="$WORK/home-plain"
mkdir -p "$PLAIN_HOME"

# The real python3, resolved by absolute path before any case changes PATH.
REAL_PYTHON3="$(command -v python3 || true)"
if [ -z "$REAL_PYTHON3" ]; then
  report_failure "precondition: python3 does not resolve on PATH, so the interpreter cases cannot be built"
fi

# write_semgrep_stub <path> <exit status> <json report>: a stub Semgrep that
# ignores its arguments, prints <json report>, and exits <exit status>.
write_semgrep_stub() {
  local stub_path="$1" exit_status="$2" json_report="$3"
  printf '%s' "$json_report" > "$stub_path.json"
  printf '#!/bin/sh\ncat "%s"\nexit %s\n' "$stub_path.json" "$exit_status" > "$stub_path"
  chmod +x "$stub_path"
}

STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
CLEAN_SEMGREP="$STUB_BIN/semgrep-clean"
write_semgrep_stub "$CLEAN_SEMGREP" 0 '{"results":[],"errors":[],"paths":{"scanned":[]}}'

# make_repo <dir> <branch> <origin url>: a fresh repository on <branch> with
# one empty commit, an origin remote at <origin url>, and origin/main pinned to
# that commit so the outgoing base resolves.
make_repo() {
  local dir="$1" branch="$2" origin_url="$3"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" remote add origin "$origin_url"
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
  (cd "$repo" && push_payload "$repo" "$branch" | env HOME="$PLAIN_HOME" "$@" "$HOOK" 2>/dev/null)
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

# (a) Untrusted repository: its .venv/bin/python3 must never run.
BROKEN_SOURCE="$WORK/broken_models.py"
printf 'def broken(:\n    return 1\n' > "$BROKEN_SOURCE"
REPO_UNTRUSTED="$WORK/repo-untrusted"
UNTRUSTED_MARKER="$WORK/untrusted-venv-python-ran"
make_repo "$REPO_UNTRUSTED" main "https://example.invalid/untrusted.git"
commit_file "$REPO_UNTRUSTED" app/models.py "$BROKEN_SOURCE"
mkdir -p "$REPO_UNTRUSTED/.venv/bin"
printf '#!/bin/sh\n: > "%s"\nexit 0\n' "$UNTRUSTED_MARKER" > "$REPO_UNTRUSTED/.venv/bin/python3"
chmod +x "$REPO_UNTRUSTED/.venv/bin/python3"
OUT_UNTRUSTED=$(run_hook "$REPO_UNTRUSTED" main CLAUDE_SEMGREP_CMD="$CLEAN_SEMGREP")
if [ -e "$UNTRUSTED_MARKER" ]; then
  report_failure "(a) untrusted repository: the gate executed the repository's .venv/bin/python3 (marker file exists), but the origin URL is not in gate-trusted-repos.txt"
else
  report_ok "(a) untrusted repository: the repository's .venv/bin/python3 never ran"
fi
expect_deny "(a) untrusted repository: PATH python3 parses and the syntax error denies" \
  "$OUT_UNTRUSTED" "does not parse"

# (b) Trusted repository: its .venv/bin/python3 decides the parse check.
MODERN_SOURCE="$WORK/modern_models.py"
printf 'def describe_status(status_code):\n    match status_code:\n        case 200:\n            return "ok"\n        case 404:\n            return "missing"\n        case _:\n            return "other"\n' > "$MODERN_SOURCE"
if [ -n "$REAL_PYTHON3" ] && ! "$REAL_PYTHON3" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$MODERN_SOURCE" >/dev/null 2>&1; then
  report_failure "precondition: the real python3 ($REAL_PYTHON3) does not parse the match-statement sample"
fi

# A stub python3 that stands in for an old host interpreter: it exits 1 for
# any ast.parse invocation and delegates everything else to the real python3.
OLD_PYTHON_DIR="$WORK/old-python-bin"
mkdir -p "$OLD_PYTHON_DIR"
cat > "$OLD_PYTHON_DIR/python3" <<EOF
#!/bin/sh
case "\$*" in
  *ast.parse*) exit 1 ;;
esac
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$OLD_PYTHON_DIR/python3"

TRUSTED_ORIGIN="https://example.invalid/trusted.git"
TRUSTED_HOME="$WORK/home-trusted"
mkdir -p "$TRUSTED_HOME/.claude/enforce"
printf '%s\n' "$TRUSTED_ORIGIN" > "$TRUSTED_HOME/.claude/enforce/gate-trusted-repos.txt"
REPO_TRUSTED="$WORK/repo-trusted"
make_repo "$REPO_TRUSTED" main "$TRUSTED_ORIGIN"
commit_file "$REPO_TRUSTED" app/models.py "$MODERN_SOURCE"
mkdir -p "$REPO_TRUSTED/.venv/bin"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$REPO_TRUSTED/.venv/bin/python3"
chmod +x "$REPO_TRUSTED/.venv/bin/python3"
OUT_TRUSTED=$(run_hook "$REPO_TRUSTED" main HOME="$TRUSTED_HOME" \
  PATH="$OLD_PYTHON_DIR:$PATH" CLAUDE_SEMGREP_CMD="$CLEAN_SEMGREP")
expect_silent "(b) trusted repository: its .venv python3 parses modern syntax, push allowed" "$OUT_TRUSTED"

# (c) and (d) push a clean app/x.py through a stub Semgrep.
CLEAN_SOURCE="$WORK/x.py"
printf 'def add_numbers(left, right):\n    return left + right\n' > "$CLEAN_SOURCE"

# (c) A result without check_id or start: the findings read fails.
UNREADABLE_SEMGREP="$STUB_BIN/semgrep-unreadable-finding"
write_semgrep_stub "$UNREADABLE_SEMGREP" 0 '{"results":[{"path":"app/x.py"}],"errors":[],"paths":{"scanned":["app/x.py"]}}'
REPO_UNREADABLE="$WORK/repo-unreadable"
make_repo "$REPO_UNREADABLE" main "https://example.invalid/unreadable.git"
commit_file "$REPO_UNREADABLE" app/x.py "$CLEAN_SOURCE"
OUT_UNREADABLE=$(run_hook "$REPO_UNREADABLE" main CLAUDE_SEMGREP_CMD="$UNREADABLE_SEMGREP")
expect_deny "(c) unreadable finding in an exit-0 report denies" "$OUT_UNREADABLE" \
  "could not read Semgrep's findings"

# (d) Exit 1 with no findings in the report.
EXIT_ONE_SEMGREP="$STUB_BIN/semgrep-exit-one-empty"
write_semgrep_stub "$EXIT_ONE_SEMGREP" 1 '{"results":[],"errors":[],"paths":{"scanned":["app/x.py"]}}'
REPO_EXIT_ONE="$WORK/repo-exit-one"
make_repo "$REPO_EXIT_ONE" main "https://example.invalid/exit-one.git"
commit_file "$REPO_EXIT_ONE" app/x.py "$CLEAN_SOURCE"
OUT_EXIT_ONE=$(run_hook "$REPO_EXIT_ONE" main CLAUDE_SEMGREP_CMD="$EXIT_ONE_SEMGREP")
expect_deny "(d) exit 1 with an empty findings list denies" "$OUT_EXIT_ONE" "exited 1"

if [ "$failures" -gt 0 ]; then
  echo "push-semgrep-gate-trust.test.sh FAIL ($failures)"
  exit 1
fi
echo "push-semgrep-gate-trust.test.sh PASS"
