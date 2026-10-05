#!/usr/bin/env bash
# Covers: hook:credential-env-warning
# C-8: the SessionStart hook names each credential variable present in its
# environment and never its value; with only non-credential variables it
# prints nothing; settings.json registers it under SessionStart.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

HOOK="$CLAUDE_HARNESS_ROOT/hooks/credential-env-warning.sh"
SETTINGS="$CLAUDE_HARNESS_ROOT/settings.json"
fail=0
bad() { echo "FAIL: $*"; fail=1; }

[ -f "$HOOK" ] || bad "hook missing: $HOOK"

WORK=$(mktemp -d) || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
SENT="sentinel-$RANDOM-$RANDOM"
INPUT='{"hook_event_name":"SessionStart","source":"startup"}'

if [ -f "$HOOK" ]; then
  # Credential present: the name appears, the value never does.
  OUT=$(printf '%s' "$INPUT" | env -i PATH="$PATH" HOME="$WORK" EDITOR=vi STRIPE_SECRET_KEY="$SENT" bash "$HOOK" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || bad "hook exited $rc with a credential set"
  case "$OUT" in *STRIPE_SECRET_KEY*) ;; *) bad "output does not name STRIPE_SECRET_KEY: $OUT" ;; esac
  case "$OUT" in *"$SENT"*) bad "output contains the credential value" ;; esac
  case "$OUT" in *EDITOR*) bad "output names the non-credential EDITOR: $OUT" ;; esac

  # Two credentials: both named, still no value.
  OUT=$(printf '%s' "$INPUT" | env -i PATH="$PATH" HOME="$WORK" GH_TOKEN="$SENT" DATABASE_URL="$SENT" bash "$HOOK" 2>&1)
  case "$OUT" in *GH_TOKEN*DATABASE_URL*|*DATABASE_URL*GH_TOKEN*) ;; *) bad "output does not name both GH_TOKEN and DATABASE_URL: $OUT" ;; esac
  case "$OUT" in *"$SENT"*) bad "output contains the credential value (two set)" ;; esac

  # No credential: silent.
  OUT=$(printf '%s' "$INPUT" | env -i PATH="$PATH" HOME="$WORK" EDITOR=vi LANG=C bash "$HOOK" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || bad "hook exited $rc with no credential set"
  [ -z "$OUT" ] || bad "expected no output with only non-credential variables, got: $OUT"
fi

jq -e '[.hooks.SessionStart[].hooks[].command | select(endswith("credential-env-warning.sh"))] | length > 0' "$SETTINGS" >/dev/null 2>&1 \
  || bad "settings.json: credential-env-warning.sh is not registered under SessionStart"

[ "$fail" -eq 0 ] && echo "PASS: credential-env-warning"
exit "$fail"
