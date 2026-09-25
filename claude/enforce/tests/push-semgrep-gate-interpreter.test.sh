#!/usr/bin/env bash
# Verifies the B-6d behavior of push-semgrep-gate.sh (IAN-381, R-517 re-review
# findings N1 and N2 on PR #141).
#
# N2: a partial scan that Semgrep itself reports must deny, independently of
# the gate's local parse pre-check. The case is a pushed .ts file (no local
# parser checks .ts) carrying `rejectUnauthorized: false` followed by a
# trailing TypeScript syntax error; Semgrep reports an .errors entry at level
# warn, and the gate must deny naming the file's path.
#
# N1: the Python parse check uses the repository's own interpreter when one
# exists, in this order: <repo>/.venv/bin/python3, then python3 on PATH. A stub
# python3 first on PATH exits 1 for any ast.parse invocation, standing in for
# an old host interpreter that cannot parse modern syntax. With a .venv whose
# python3 execs the real interpreter, a push of valid modern Python (a match
# statement) must be allowed; the same repository without .venv must deny as
# "does not parse", which proves the stub is what decides.
#
# Each case builds its own throwaway repository under one mktemp directory.
# The hook runs with HOME pointed at a scratch directory that holds no exempt
# list. The uv cache and Python install directories are passed through
# explicitly so `uvx semgrep` under the scratch HOME reuses the machine's
# existing install instead of downloading.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-semgrep-gate.sh"
RULES_DIR="$CLAUDE_HARNESS_ROOT/enforce/semgrep"
unset CLAUDE_ENFORCE_BASE CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }
report_ok() { echo "ok: $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

UV_CACHE_PASSTHROUGH="${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/uv}"
UV_PYTHON_PASSTHROUGH="${UV_PYTHON_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/python}"

# A scratch HOME with no exempt list, shared by every case.
PLAIN_HOME="$WORK/home-plain"
mkdir -p "$PLAIN_HOME"

# The real python3, resolved by absolute path before any case changes PATH.
REAL_PYTHON3="$(command -v python3 || true)"
if [ -z "$REAL_PYTHON3" ]; then
  report_failure "precondition: python3 does not resolve on PATH, so the interpreter cases cannot be built"
fi

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

# N2. A .ts file with the TLS-verification-disabled shape followed by a
# trailing syntax error. No local parser checks .ts, so only Semgrep's own
# report can reveal the partial scan, and the gate must deny naming the path.
TS_SOURCE="$WORK/agent.ts"
printf 'import https from "node:https";\n\nexport const providerAgent = new https.Agent({\n    keepAlive: true,\n    rejectUnauthorized: false,\n});\n\n\n\n\n\n\n\n\n\n\nexport function brokenHelper(: number {\n    return 1;\n' > "$TS_SOURCE"

# Precondition: Semgrep itself reports at least one error at level warn for
# this file, so the case exercises a Semgrep-reported partial scan.
if [ -n "$REAL_SEMGREP" ]; then
  PROBE_DIR="$WORK/semgrep-probe"
  mkdir -p "$PROBE_DIR/app"
  cp "$TS_SOURCE" "$PROBE_DIR/app/agent.ts"
  : > "$PROBE_DIR/.semgrepignore"
  # shellcheck disable=SC2086  # REAL_SEMGREP may be the two-word `uvx semgrep`
  PROBE_JSON=$(cd "$PROBE_DIR" && env HOME="$PLAIN_HOME" \
    UV_CACHE_DIR="$UV_CACHE_PASSTHROUGH" UV_PYTHON_INSTALL_DIR="$UV_PYTHON_PASSTHROUGH" \
    $REAL_SEMGREP --config "$RULES_DIR" --metrics=off --disable-version-check --disable-nosem \
    --json --quiet app/agent.ts 2>/dev/null)
  if ! printf '%s' "$PROBE_JSON" | jq -e '[(.errors // [])[] | select(.level == "warn")] | length > 0' >/dev/null 2>&1; then
    report_failure "precondition: Semgrep did not report an error at level warn for the broken .ts sample; errors: $(printf '%s' "$PROBE_JSON" | jq -c '.errors' 2>/dev/null)"
  fi
fi

REPO_TS="$WORK/repo-ts"
make_repo "$REPO_TS" main
commit_file "$REPO_TS" app/agent.ts "$TS_SOURCE"
OUT_TS=$(run_hook "$REPO_TS" main)
expect_deny "N2 Semgrep-reported partial scan of a .ts file denies" "$OUT_TS" "app/agent.ts"

# N1. Valid modern Python (a match statement) with no rule-pack finding.
MODERN_SOURCE="$WORK/models.py"
printf 'def describe_status(status_code):\n    match status_code:\n        case 200:\n            return "ok"\n        case 404:\n            return "missing"\n        case _:\n            return "other"\n' > "$MODERN_SOURCE"
if [ -n "$REAL_PYTHON3" ] && ! "$REAL_PYTHON3" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$MODERN_SOURCE" >/dev/null 2>&1; then
  report_failure "precondition: the real python3 ($REAL_PYTHON3) does not parse the match-statement sample"
fi

# A stub python3 that stands in for an old host interpreter: it exits 1 for
# any ast.parse invocation and delegates everything else to the real python3.
STUB_DIR="$WORK/old-python-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/python3" <<EOF
#!/bin/sh
case "\$*" in
  *ast.parse*) exit 1 ;;
esac
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$STUB_DIR/python3"
STUB_PATH="$STUB_DIR:$PATH"

# N1 allow: the repository carries .venv/bin/python3, a wrapper that execs the
# real python3 by absolute path, and its origin is listed in the scratch home's
# gate-trusted-repos.txt, because the gate runs a repository's own interpreter
# only for a trusted repository (IAN-381 B-6f, owner decision). The gate must
# parse with it and allow.
REPO_VENV="$WORK/repo-venv"
make_repo "$REPO_VENV" main
commit_file "$REPO_VENV" app/models.py "$MODERN_SOURCE"
git -C "$REPO_VENV" remote add origin "https://example.invalid/repo-venv.git"
TRUSTED_HOME="$WORK/home-trusted"
mkdir -p "$TRUSTED_HOME/.claude/enforce"
printf '%s\n' "https://example.invalid/repo-venv.git" > "$TRUSTED_HOME/.claude/enforce/gate-trusted-repos.txt"
mkdir -p "$REPO_VENV/.venv/bin"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PYTHON3" > "$REPO_VENV/.venv/bin/python3"
chmod +x "$REPO_VENV/.venv/bin/python3"
OUT_VENV=$(run_hook "$REPO_VENV" main PATH="$STUB_PATH" HOME="$TRUSTED_HOME")
expect_silent "N1 repository .venv python3 parses modern syntax, push allowed" "$OUT_VENV"

# N1 control: the same content without .venv falls back to python3 on PATH,
# which is the stub, so the gate must deny the file as not parsing.
REPO_NOVENV="$WORK/repo-novenv"
make_repo "$REPO_NOVENV" main
commit_file "$REPO_NOVENV" app/models.py "$MODERN_SOURCE"
OUT_NOVENV=$(run_hook "$REPO_NOVENV" main PATH="$STUB_PATH")
expect_deny "N1 control: no .venv, PATH python3 stub decides" "$OUT_NOVENV" \
  "app/models.py" "does not parse"

if [ "$failures" -gt 0 ]; then
  echo "push-semgrep-gate-interpreter.test.sh FAIL ($failures)"
  exit 1
fi
echo "push-semgrep-gate-interpreter.test.sh PASS"
