#!/usr/bin/env bash
# The matching semantics of enforce/settings-permission-rules.sh, the helper
# the Codex and Cursor hook adapters source to evaluate the `Bash(...)` and
# `Read(...)` entries of settings.json. The two adapter contract fixtures prove
# the layer is wired up end to end; this one pins down what it actually
# matches, because a permission mirror that is wired up but matches the wrong
# set of commands is the same failure wearing a different hat.
#
# The cases are drawn from the rule shapes the real claude/settings.json uses:
# a trailing-wildcard prefix rule, an exact rule, a rule with a wildcard in the
# middle, a tilde-rooted path rule, and the `//**/` absolute-anywhere form of
# the Read rules.
#
# Hermetic: HOME and the settings file live under one mktemp sandbox removed on
# exit, and the helper is sourced into this shell, so nothing here reads the
# installed ~/.claude.
set -uo pipefail

REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
HELPER="$REPO_TOP/claude/enforce/settings-permission-rules.sh"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
not() { ! "$@"; }

[ -f "$HELPER" ] || { echo "FAIL: no permission helper at $HELPER, so this fixture proved nothing"; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/settings-permission-rules.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
export AGENT_AUDIT_DIR="$SANDBOX/audit"   # A-13: never the owner's real log
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

cat >"$SANDBOX/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(echo *)"],
    "deny": [
      "Bash(git push --mirror*)",
      "Bash(rm -rf /)",
      "Bash(git config --unset*core.hooksPath*)",
      "Bash(rm ~/.claude/hooks/*)",
      "Read(//**/.env)",
      "Read(~/.aws/**)",
      "Read(~/.netrc)"
    ],
    "ask": ["Bash(git push --force*)"]
  }
}
EOF
export CLAUDE_SETTINGS_FILE="$SANDBOX/settings.json"

# shellcheck source=../settings-permission-rules.sh
source "$HELPER"

# --- assertions, each a wrapper so no pipeline or redirect rides on check() ----

denies() { matching_bash_rule deny "$1" >/dev/null; }
asks() { matching_bash_rule ask "$1" >/dev/null; }
matched_rule_is() { [ "$(matching_bash_rule deny "$2" 2>/dev/null)" = "$1" ]; }
read_denied() { read_is_denied "$1"; }

# The undecidable cases point the helper at a settings file that is not there.
# The assignment is saved and restored by hand rather than written as a command
# prefix, because a prefix assignment on a bash function call outlives the call.
cannot_tell() {
  local saved="$CLAUDE_SETTINGS_FILE" status
  CLAUDE_SETTINGS_FILE="$SANDBOX/absent.json"
  matching_bash_rule deny "$1" >/dev/null 2>&1
  status=$?
  CLAUDE_SETTINGS_FILE="$saved"
  [ "$status" -eq 2 ]
}

read_cannot_tell() {
  local saved="$CLAUDE_SETTINGS_FILE" status
  CLAUDE_SETTINGS_FILE="$SANDBOX/absent.json"
  read_is_denied "$1" >/dev/null 2>&1
  status=$?
  CLAUDE_SETTINGS_FILE="$saved"
  [ "$status" -eq 2 ]
}

# --- Bash rules ---------------------------------------------------------------

check "a trailing-wildcard rule matches the command it prefixes" denies 'git push --mirror origin'
check "a trailing-wildcard rule does not match an unrelated command" not denies 'git push origin main'
check "an exact rule matches only the exact command" denies 'rm -rf /'
check "an exact rule does not match a longer command" not denies 'rm -rf /tmp/scratch'
check "a wildcard in the middle of a rule still matches" denies 'git config --unset --local core.hooksPath'
check "a tilde in a rule matches the expanded home path" denies "rm $HOME/.claude/hooks/secret-scan.sh"
check "a tilde in a rule also matches the literal tilde form" denies 'rm ~/.claude/hooks/secret-scan.sh'
check "the matched rule text is printed for the caller to quote" matched_rule_is 'rm -rf /' 'rm -rf /'
check "a command hidden behind && is still matched" denies 'echo staging && rm -rf /'
check "a command matching nothing is not denied" not denies 'ls -la'
check "the ask tier is read separately from the deny tier" asks 'git push --force origin main'
check "an ask rule does not leak into the deny tier" not denies 'git push --force origin main'
check "an unreadable settings file is reported as undecidable, not as allowed" cannot_tell 'ls -la'

# --- Read rules ---------------------------------------------------------------

ENV_FILE="$SANDBOX/project/.$(printf 'env')"
mkdir -p "$SANDBOX/project"
check "an absolute-anywhere Read rule matches the file it names" read_denied "$ENV_FILE"
check "an absolute-anywhere Read rule does not match a similar name" not read_denied "${ENV_FILE}rc"
check "a tilde-rooted Read rule matches a file under that directory" read_denied "$HOME/.$(printf 'aws')/credentials"
check "an exact tilde Read rule matches that one file" read_denied "$HOME/.$(printf 'netrc')"
check "a file no Read rule covers is not denied" not read_denied "$SANDBOX/project/README.md"
check "an unreadable settings file makes a read undecidable, not allowed" read_cannot_tell "$SANDBOX/project/README.md"

# The owner removed non-destructive asks on 2026-10-04: opening a PR and
# re-running CI change nothing that cannot be undone. Merging is not asked
# either (owner, 2026-10-04, #201); git-workflow-guard still gates it.
REAL_SETTINGS="$(dirname "${BASH_SOURCE[0]}")/../../settings.json"
not_asked() { ! jq -e --arg r "$1" '.permissions.ask | index($r) != null' "$REAL_SETTINGS" >/dev/null; }
asked() { jq -e --arg r "$1" '.permissions.ask | index($r) != null' "$REAL_SETTINGS" >/dev/null; }
check "opening a PR is not asked" not_asked 'Bash(gh pr create*)'
check "re-running CI is not asked" not_asked 'Bash(gh run rerun*)'
check "dispatching a workflow is not asked" not_asked 'Bash(gh workflow run*)'
check "merging a PR is not asked" not_asked 'Bash(gh pr merge*)'

# Owner, 2026-10-04: optimize for allowing non-destructive commands. Read,
# build, test, and lint tools are allowed outright, so auto mode never stops to
# classify them; ask rules and the guard hooks still take precedence over allow.
allowed() { jq -e --arg r "$1" '.permissions.allow | index($r) != null' "$REAL_SETTINGS" >/dev/null; }
for rule in 'Bash(pytest *)' 'Bash(ruff *)' 'Bash(make test)' 'Bash(go test *)' 'Bash(cargo test*)' \
  'Bash(docker ps*)' 'Bash(docker logs *)' 'Bash(sort *)' 'Bash(pwd)' 'Bash(readlink *)'; do
  check "non-destructive $rule is allowed" allowed "$rule"
done
# PR 199 review: interpreters that run arbitrary code stay with the classifier,
# make takes exact targets only, and a docker build that pushes still asks.
not_allowed() { ! jq -e --arg r "$1" '.permissions.allow | index($r) != null' "$REAL_SETTINGS" >/dev/null; }
for rule in 'Bash(node *)' 'Bash(python3 *)' 'Bash(uv run *)' 'Bash(make build*)' 'Bash(tree*)' 'Bash(pytest*)' 'Bash(uname*)'; do
  check "$rule is not allowed" not_allowed "$rule"
done
check "docker build --push is asked" asked 'Bash(docker build *--push*)'
# The shell-wrapper asks stay: inside bash -c, a prefix-only ask such as
# git reset --hard or npm publish is invisible to every guard.
check "bash -c is still asked" asked 'Bash(bash -c *)'

[ "$fail" -eq 0 ] && echo "settings-permission-rules.test.sh PASS"
exit "$fail"
