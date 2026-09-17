#!/usr/bin/env bash
# doctor.sh: verifies an installed harness end to end and reports one line
# per check (pass|warn|fail|skipped <name>: <detail>). Exit 0 when nothing
# failed, 1 on any fail, 2 on usage error. --full adds the fixture suites;
# --release adds the publish gate (hardening spec B-1, B-4, B-6).
set -uo pipefail

PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
MODE_FULL=0; MODE_RELEASE=0
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

usage() { echo "usage: doctor.sh [--root <repo-dir>] [--full] [--release]"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root) shift; [ -n "${1:-}" ] || { usage >&2; exit 2; }; ROOT_DIR="$1" ;;
    --full) MODE_FULL=1 ;;
    --release) MODE_RELEASE=1; MODE_FULL=1 ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

report() { # verdict, check-name, detail...
  local verdict="$1" name="$2"; shift 2
  case "$verdict" in
    pass) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    warn) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    fail) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    skipped) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    *) FAIL_COUNT=$((FAIL_COUNT + 1)); echo "fail $name: internal error, unknown verdict '$verdict' ($*)"; return ;;
  esac
  echo "$verdict $name: $*"
}

finish_doctor() {
  echo "doctor: $PASS_COUNT pass, $WARN_COUNT warn, $FAIL_COUNT fail, $SKIP_COUNT skipped"
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
  exit 0
}

# Task 2: settings parse and schema-key checks (B-1).
SETTINGS_FILE="$ROOT_DIR/claude/settings.json"
SCHEMA_FILE="$ROOT_DIR/claude/enforce/claude-code-settings.schema.json"
[ -f "$SCHEMA_FILE" ] || SCHEMA_FILE="$(dirname "${BASH_SOURCE[0]}")/claude-code-settings.schema.json"
ACCEPTED_FILE="$ROOT_DIR/claude/enforce/doctor-accepted-keys.txt"
[ -f "$ACCEPTED_FILE" ] || ACCEPTED_FILE="$(dirname "${BASH_SOURCE[0]}")/doctor-accepted-keys.txt"

if [ ! -f "$SETTINGS_FILE" ]; then
  report fail settings-parse "${SETTINGS_FILE/#$HOME/~} is missing"
elif jq empty "$SETTINGS_FILE" >/dev/null 2>&1; then
  report pass settings-parse "$SETTINGS_FILE parses"
  KNOWN_KEYS=$(jq -r '.properties | keys[]' "$SCHEMA_FILE" 2>/dev/null)
  if [ -z "$KNOWN_KEYS" ]; then
    report skipped settings-schema-keys "vendored schema missing or unreadable at $SCHEMA_FILE"
  else
    UNKNOWN=""; ACCEPTED=""
    while IFS= read -r key; do
      [ "$key" = '$schema' ] && continue
      if ! grep -qxF "$key" <<<"$KNOWN_KEYS"; then
        if [ -f "$ACCEPTED_FILE" ] && grep -qxF "$key" "$ACCEPTED_FILE"; then ACCEPTED="$ACCEPTED $key"; else UNKNOWN="$UNKNOWN $key"; fi
      fi
    done < <(jq -r 'keys[]' "$SETTINGS_FILE")
    if [ -n "$UNKNOWN" ]; then report fail settings-schema-keys "unknown key(s):$UNKNOWN (accept in doctor-accepted-keys.txt if deliberate)"
    elif [ -n "$ACCEPTED" ]; then report warn settings-schema-keys "accepted-unknown key(s):$ACCEPTED"
    else report pass settings-schema-keys "every key known to the vendored schema"; fi
  fi
else
  report fail settings-parse "$SETTINGS_FILE is not valid JSON"
fi

# Task 3: hook wiring and executability checks (B-6). Both live verifiers
# always exit 0, even when they have a finding: the finding travels as
# hookSpecificOutput.additionalContext JSON on stdout (a plain-text verifier
# is also tolerated). Branch on OUTPUT content, not exit status, or a
# tampered/failing hook reads as "clean".
LIVE_CLAUDE="$HOME/.claude"
for verifier in enforcement-guard-check hook-integrity-check; do
  V="$LIVE_CLAUDE/hooks/$verifier.sh"
  case "$verifier" in
    enforcement-guard-check) NAME=hook-registration ;;
    hook-integrity-check) NAME=hook-integrity ;;
    *) NAME="$verifier" ;;
  esac
  if [ -x "$V" ]; then
    OUT=$(bash "$V" 2>&1); ST=$?
    if [ "$ST" -ne 0 ]; then
      report fail "$NAME" "verifier errored: $(head -1 <<<"$OUT")"
    else
      FINDING=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
      [ -z "$FINDING" ] && [ -n "$OUT" ] && FINDING="$OUT"
      if [ -n "$FINDING" ]; then report warn "$NAME" "$(head -1 <<<"$FINDING")"; else report pass "$NAME" "clean"; fi
    fi
  else
    report skipped "$NAME" "${V/#$HOME/~} not installed"
  fi
done

BAD_HOOKS=""
if [ -f "$LIVE_CLAUDE/settings.json" ] && jq empty "$LIVE_CLAUDE/settings.json" >/dev/null 2>&1; then
  while IFS= read -r cmd; do
    script="${cmd/#\~/$HOME}"; script="${script%% *}"
    case "$script" in "$HOME"/.claude/hooks/*.sh)
      { [ -x "$script" ] && bash -n "$script" 2>/dev/null; } || BAD_HOOKS="$BAD_HOOKS ${script/#$HOME/~}" ;;
    esac
  done < <(jq -r '.hooks[]?[]?.hooks[]?.command // empty' "$LIVE_CLAUDE/settings.json")
  if [ -n "$BAD_HOOKS" ]; then report fail hook-executability "not executable or has syntax errors:$BAD_HOOKS"
  else report pass hook-executability "every registered hook executable and syntax-clean"; fi
else
  report skipped hook-executability "no parseable live settings at ${LIVE_CLAUDE/#$HOME/~}/settings.json"
fi

# Task 4: environment probes (B-6): required deps, Bash sandbox availability,
# the configured statusLine command (if any) rendering a sample payload, and
# the codex port staying in sync with its sources.
MISSING_DEPS=""
for dep in jq node git; do command -v "$dep" >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS $dep"; done
if [ -n "$MISSING_DEPS" ]; then report fail deps "missing:$MISSING_DEPS"; else report pass deps "jq, node, git present"; fi

# The OS probe alone answers "can the primitive run here"; the settings read
# below answers "did this checkout turn it on" (B-2). Combined: pass only
# when both hold, since an available-but-off sandbox leaves Bash subprocesses
# unconfined despite the primitive being installed, and an enabled-but-
# unavailable sandbox (Linux without bwrap/socat) leaves the same subprocess
# unconfined despite settings intent, in both cases a warn naming which half
# is missing rather than a silent pass. Never a fail: sessions must keep
# working on hosts without the primitive (failIfUnavailable: false). Ships
# with sandbox.enabled: false by default (review round 1, second pass): two
# live incidents (temp-dir denial, then an exclusive filesystem allowlist
# that left the whole working tree unwritable once the temp-only allowance
# was added) showed enabling by default breaks ordinary harness tooling
# faster than it can be scoped safely; see enforce/README.md's containment
# section for the manual rollout procedure. A present-but-disabled block
# gets its own warn ("configured but disabled") distinct from no block at
# all ("not enabled in settings"), so a doctor run tells the operator
# whether the bootstrap path is documented and ready or missing outright.
case "$(uname -s)" in
  Darwin) SANDBOX_OS_AVAILABLE=1; SANDBOX_OS_DETAIL="macOS Seatbelt built in" ;;
  Linux)
    if command -v bwrap >/dev/null 2>&1 && command -v socat >/dev/null 2>&1; then
      SANDBOX_OS_AVAILABLE=1; SANDBOX_OS_DETAIL="bwrap and socat present"
    else
      SANDBOX_OS_AVAILABLE=0; SANDBOX_OS_DETAIL="bwrap/socat missing; Bash sandboxing unavailable until installed"
    fi ;;
  *) SANDBOX_OS_AVAILABLE=0; SANDBOX_OS_DETAIL="unsupported OS for Bash sandboxing: $(uname -s)" ;;
esac
SANDBOX_ENABLED=$(jq -r '.sandbox.enabled // false' "$SETTINGS_FILE" 2>/dev/null)
SANDBOX_PRESENT=$(jq -r 'has("sandbox")' "$SETTINGS_FILE" 2>/dev/null)
if [ "$SANDBOX_OS_AVAILABLE" -eq 1 ] && [ "$SANDBOX_ENABLED" = "true" ]; then
  report pass sandbox-availability "$SANDBOX_OS_DETAIL, enabled in settings"
elif [ "$SANDBOX_OS_AVAILABLE" -eq 1 ] && [ "$SANDBOX_PRESENT" = "true" ]; then
  report warn sandbox-availability "configured but disabled (see containment docs for the rollout procedure)"
elif [ "$SANDBOX_OS_AVAILABLE" -eq 1 ]; then
  report warn sandbox-availability "$SANDBOX_OS_DETAIL, but not enabled in settings (set sandbox.enabled: true)"
elif [ "$SANDBOX_ENABLED" = "true" ]; then
  report warn sandbox-availability "enabled in settings but unavailable on this host: $SANDBOX_OS_DETAIL"
else
  report warn sandbox-availability "$SANDBOX_OS_DETAIL"
fi

SL_CMD=$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)
if [ -z "$SL_CMD" ]; then
  report skipped statusline "no statusLine configured in live settings"
else
  SL_SAMPLE='{"model":{"display_name":"probe"},"context_window":{"used_percentage":null},"cwd":"/tmp","cost":{"total_cost_usd":null,"total_duration_ms":0}}'
  SL_BIN="${SL_CMD/#\~/$HOME}"
  if SL_OUT=$(printf '%s' "$SL_SAMPLE" | bash -c "$SL_BIN" 2>/dev/null) && [ -n "$SL_OUT" ]; then
    report pass statusline "renders: $(head -1 <<<"$SL_OUT")"
  else
    report fail statusline "${SL_CMD/#$HOME/~} errored or printed nothing on a sample payload"
  fi
fi

if [ -f "$ROOT_DIR/translate/codex.mjs" ]; then
  if node "$ROOT_DIR/translate/codex.mjs" --check --root "$ROOT_DIR" >/dev/null 2>&1; then report pass port-freshness "codex port matches its sources"
  else report fail port-freshness "translate/codex.mjs --check reports drift; run --write"; fi
else
  report skipped port-freshness "no translator at $ROOT_DIR/translate/codex.mjs"
fi

# Task 5: --full fixture suites and the --release publish gate (B-4).
if [ "$MODE_FULL" = 1 ]; then
  SUITES_OK=1
  for suite in "$ROOT_DIR/claude/enforce/tests/run-tests.sh" "$ROOT_DIR/claude/hooks/tests/run-tests.sh"; do
    if [ ! -f "$suite" ]; then
      # skipped never counts toward release readiness (B-4): under --release
      # a missing suite must escalate to fail, not skip, or a broken
      # checkout could read release-ready. Non-release stays skipped.
      if [ "$MODE_RELEASE" = 1 ]; then
        report fail fixture-suites "$suite missing; release readiness cannot be evaluated"
      else
        report skipped fixture-suites "$suite missing"
      fi
      SUITES_OK=""; break
    fi
    bash "$suite" >/dev/null 2>&1 || { report fail fixture-suites "$suite is red"; SUITES_OK=0; break; }
  done
  [ "$SUITES_OK" = 1 ] && report pass fixture-suites "both suites green"
fi

if [ "$MODE_RELEASE" = 1 ]; then
  ISSUES="$ROOT_DIR/claude/ISSUES.md"
  if [ -f "$ISSUES" ] && grep -n "PENDING USER ACTION" "$ISSUES" >/dev/null; then
    report fail release-blockers "PENDING USER ACTION open in $ISSUES (B-4: stays first until the user closes it)"
  else
    report pass release-blockers "no pending user actions"
  fi
  PATTERNS_FILE="$ROOT_DIR/claude/enforce/secret-patterns.txt"
  [ -f "$PATTERNS_FILE" ] || PATTERNS_FILE="$(dirname "${BASH_SOURCE[0]}")/secret-patterns.txt"
  if [ -f "$PATTERNS_FILE" ]; then
    SCAN_PATTERN=$(grep -v '^#' "$PATTERNS_FILE" | grep -v '^$' | paste -sd'|' -)
    # Real home-path leak, not a blanket "/Users/..." match: a generic
    # example path (/Users/alice, /Users/someuser) in docs and fixtures is
    # allowed on purpose, same convention as global-repo-push-guard.sh's
    # R-106 check; only THIS machine's actual username in a Users/home path
    # is a leak worth failing release on.
    RELEASE_USER=$(id -un 2>/dev/null || echo "")
    if [ -n "$RELEASE_USER" ]; then
      # Alongside the literal /Users/<user>/ form, also match the mangled
      # Claude-Code project-dir form ("-Users-<user>-...", slashes turned to
      # dashes) that session transcripts and directory names use.
      SCAN_PATTERN="$SCAN_PATTERN|/(Users|home)/${RELEASE_USER}(/|\$)|-Users-${RELEASE_USER}-"
    fi
    HITS=$(git -C "$ROOT_DIR" grep -lE "$SCAN_PATTERN" -- . 2>/dev/null | grep -v "enforce/secret-patterns.txt" || true)
    if [ -n "$HITS" ]; then report fail release-secret-scan "pattern hits in tracked files: $(paste -sd' ' - <<<"$HITS")"
    else report pass release-secret-scan "no secret or home-path hits in tracked files"; fi
  else
    # skipped never counts toward release readiness (B-4): this whole block
    # only runs under --release, so a missing pattern file must fail, not
    # skip, or a broken checkout could read release-ready.
    report fail release-secret-scan "no pattern file at ${PATTERNS_FILE/#$HOME/~}; release readiness cannot be evaluated"
  fi
fi

finish_doctor
