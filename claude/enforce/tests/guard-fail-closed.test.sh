#!/usr/bin/env bash
# Covers: hook:destructive-command-guard
#
# The DYNAMIC half of the fail-closed convention (2026-09-17 audit P2-8 class,
# the open item the engineering audit left). deny-tier-set-convention.test.sh
# checks the static half: that a blocking guard does not run `set -e`, because
# under -e an internal error kills the hook before it decides and a PreToolUse
# hook that emits nothing is an allow. Nothing checked the behaviour, so a guard
# could satisfy the convention on paper and still die on input it did not
# expect. That is what P1-4 cost: two blocking guards sat outside the static
# check entirely and no dynamic check existed to notice.
#
# Every blocking guard is fed the input shapes a real session can produce but a
# hook author rarely tries: nothing at all, malformed JSON, valid JSON with the
# fields missing, and a tool name it does not handle. The guarantee asserted is
# the weakest honest one, and the only one that matters for failing closed:
#
#   exit status is 0             (a non-zero exit is a hook error, and Claude
#                                 Code treats an erroring PreToolUse hook as a
#                                 non-decision, so the call proceeds)
#   output is empty or valid JSON (a half-built decision blob is unparseable
#                                 and therefore also a non-decision)
#
# What this does NOT assert: that the guard reaches the right verdict on
# garbage. A guard that stays silent on malformed input is behaving correctly
# here; the point is that it stays silent deliberately rather than dying.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${CLAUDE_HOOKS_DIR:-$SCRIPT_DIR/../../hooks}"
MIN_GUARDS=10

fail=0
checked=0

# The blocking guards, found the same way the static convention finds them, so
# the two checks cannot cover different sets: a hook that emits either decision
# shape. Derived, not listed, because a hand-kept list of guards drifted from
# the registered set three audits running.
GUARDS=$(grep -lE 'permissionDecision|decision: "block"' "$HOOKS_DIR"/*.sh 2>/dev/null | sort)
[ -n "$GUARDS" ] || { echo "FAIL: no blocking guards found under $HOOKS_DIR, so this fixture proved nothing"; exit 1; }

# One case per input shape. Each is a real thing a hook can be handed.
probe() {
  local hook="$1" label="$2" payload="$3" name out status
  name=$(basename "$hook")
  out=$(printf '%s' "$payload" | bash "$hook" 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $name exited $status on $label; a hook that errors has not decided, so the call proceeds unguarded"
    fail=1
    return
  fi
  if [ -n "$out" ] && ! printf '%s' "$out" | jq empty >/dev/null 2>&1; then
    echo "FAIL: $name emitted unparseable output on $label, which is a non-decision: $out"
    fail=1
  fi
}

while IFS= read -r hook; do
  [ -n "$hook" ] || continue
  case "$(basename "$hook")" in install-git-hooks.sh|pre-push.sample) continue ;; esac
  checked=$((checked + 1))
  probe "$hook" "empty stdin" ""
  probe "$hook" "malformed JSON" '{"tool_name": "Bash", '
  probe "$hook" "JSON with no tool fields" '{}'
  probe "$hook" "a null tool_input" '{"tool_name":"Bash","tool_input":null}'
  probe "$hook" "an unhandled tool name" '{"tool_name":"NoSuchTool","tool_input":{"command":"ls"}}'
  probe "$hook" "a non-string command" '{"tool_name":"Bash","tool_input":{"command":{"nested":true}}}'
done <<< "$GUARDS"

# No HOME (program row 2a, IAN-436). Unattended and cloud sessions can start
# a hook with HOME unset, and under `set -u` a bare `$HOME`, even inside a
# `${VAR:-$HOME/...}` default, aborts the guard before it decides, which is
# an allow. The dynamic half feeds realistic payloads from a throwaway working
# directory; the static half covers the expansions those payloads cannot
# reach (a push gate's HOME line runs only deep inside a real push).
HOME_NORMALIZER=': "${HOME:=$(cd ~ 2>/dev/null && pwd)}"'
# The fill resolves the account's real home, so the probes read (never write)
# that home's config. It must resolve to an existing directory: a container
# with no account entry would leave HOME empty and every guard path at /.claude.
RESOLVED_HOME=$(env -u HOME bash -c ': "${HOME:=$(cd ~ 2>/dev/null && pwd)}"; printf "%s" "$HOME"')
[ -n "$RESOLVED_HOME" ] && [ -d "$RESOLVED_HOME" ] || { echo "FAIL: with HOME unset the account home did not resolve (got '$RESOLVED_HOME'), so the fill would leave every guard reading /.claude"; fail=1; }
NO_HOME_CWD=$(mktemp -d)
probe_without_home() {
  local hook="$1" label="$2" payload="$3" name out status
  name=$(basename "$hook")
  out=$(cd "$NO_HOME_CWD" && printf '%s' "$payload" | env -u HOME bash "$hook" 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $name exited $status on $label with HOME unset; it crashed before deciding, so the call proceeds unguarded"
    fail=1
    return
  fi
  if [ -n "$out" ] && ! printf '%s' "$out" | jq empty >/dev/null 2>&1; then
    echo "FAIL: $name emitted unparseable output on $label with HOME unset: $out"
    fail=1
  fi
}

while IFS= read -r hook; do
  [ -n "$hook" ] || continue
  case "$(basename "$hook")" in install-git-hooks.sh|pre-push.sample) continue ;; esac
  probe_without_home "$hook" "a git push" '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
  probe_without_home "$hook" "a gh pr create" '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title t --body b"}}'
  probe_without_home "$hook" "a source Write" '{"tool_name":"Write","tool_input":{"file_path":"'"$NO_HOME_CWD"'/src/probe.ts","content":"export const probe = 1;\n"}}'
  probe_without_home "$hook" "an MCP call" '{"tool_name":"mcp__linear__save_issue","tool_input":{"title":"t"}}'
  # ticket-at-start-gate alone takes an explicit degraded path instead (IAN-149's
  # test R-6, kept by owner decision): named, so no other guard can borrow it.
  if grep -qE '\$HOME|\$\{HOME' "$hook" && ! grep -qF -- "$HOME_NORMALIZER" "$hook" \
    && [ "$(basename "$hook")" != "ticket-at-start-gate.sh" ]; then
    echo "FAIL: $(basename "$hook") expands \$HOME without first filling it from the account entry ($HOME_NORMALIZER)"
    fail=1
  fi
done <<< "$GUARDS"
rm -rf "$NO_HOME_CWD"

if [ "$checked" -lt "$MIN_GUARDS" ]; then
  echo "FAIL: probed only $checked guards, expected at least $MIN_GUARDS; the hook tree is wrong or empty"
  fail=1
fi

[ "$fail" -eq 0 ] && echo "guard-fail-closed.test.sh PASS ($checked blocking guards, 6 input shapes each)"
exit "$fail"
