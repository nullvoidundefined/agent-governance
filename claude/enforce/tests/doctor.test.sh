#!/usr/bin/env bash
# Verifies enforce/doctor.sh (hardening spec B-6 core): output contract,
# exit codes, and each check section as later tasks add them. Hermetic:
# drives sandbox trees via --root and a sandbox HOME for every invocation
# that runs past option parsing; never reads the live ~/.claude or real
# credential files.
set -uo pipefail
REPO_TOP=$(git rev-parse --show-toplevel)
DOCTOR="$REPO_TOP/claude/enforce/doctor.sh"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
not() { ! "$@"; }
# helpShowsUsage <exit-status> <output>: a bare "test ... && grep ..." on the
# check() invocation line only passes the first command's result into
# check()'s "$@"; the && short-circuit result never reaches it, so the
# usage-text half would be vacuous. Wrapping both halves in one function
# keeps the whole assertion inside a single check() argument.
helpShowsUsage() { test "$1" -eq 0 && grep -q -- "--full" <<<"$2"; }

# Task 1: contract.
OUT=$(bash "$DOCTOR" --frobnicate 2>&1); ST=$?
check "unknown flag exits 2" test "$ST" -eq 2
check "unknown flag prints usage" grep -q -- "--release" <<<"$OUT"
OUT=$(bash "$DOCTOR" --help 2>&1); ST=$?
check "--help exits 0 with usage" helpShowsUsage "$ST" "$OUT"

# unknownVerdictFailsLoudly: extracts the real report() function body out of
# doctor.sh (rather than a hand-copied duplicate) and calls it in isolation
# with a bogus verdict, asserting it counts as a fail and says so instead of
# silently dropping the counter update.
unknownVerdictFailsLoudly() {
  local body out2
  body=$(sed -n '/^report()/,/^}/p' "$DOCTOR")
  out2=$(bash -c "PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0; $body; report bogus some-check detail; echo \"F=\$FAIL_COUNT\"")
  grep -q "unknown verdict" <<<"$out2" && grep -q "F=1" <<<"$out2"
}
check "unknown verdict counted as fail and surfaced" unknownVerdictFailsLoudly

# Task 2: settings parse and schema keys (B-1).
SANDBOX=$(mktemp -d); HOME_SANDBOX=$(mktemp -d)
STUB_WARN=$(mktemp -d); STUB_PASS=$(mktemp -d); STUB_FAIL=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$HOME_SANDBOX" "$STUB_WARN" "$STUB_PASS" "$STUB_FAIL"' EXIT
make_settings_tree() { # dir, settings-content
  mkdir -p "$1/claude"
  printf '%s\n' "$2" >"$1/claude/settings.json"
}
make_settings_tree "$SANDBOX" '{"$schema":"https://json.schemastore.org/claude-code-settings.json","model":"opusplan"}'
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --root "$SANDBOX" 2>&1)
check "valid settings pass parse" grep -q "^pass settings-parse" <<<"$OUT"
check "known keys pass schema check" grep -q "^pass settings-schema-keys" <<<"$OUT"
make_settings_tree "$SANDBOX" '{"model": broken'
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --root "$SANDBOX" 2>&1); ST=$?
check "broken JSON fails parse naming the file" grep -q "^fail settings-parse: .*settings.json" <<<"$OUT"
check "broken JSON exits 1" test "$ST" -eq 1
make_settings_tree "$SANDBOX" '{"model":"opusplan","definitelyNotARealKey":true}'
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --root "$SANDBOX" 2>&1); ST=$?
check "unknown key fails naming the key" grep -q "^fail settings-schema-keys: .*definitelyNotARealKey" <<<"$OUT"
make_settings_tree "$SANDBOX" '{"model":"opusplan","skipWorkflowUsageWarning":true}'
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --root "$SANDBOX" 2>&1)
check "accepted-unknown key warns not fails" grep -q "^warn settings-schema-keys: .*skipWorkflowUsageWarning" <<<"$OUT"

# Task 3: hook wiring (B-6). Real verifiers run against a sandbox HOME
# lacking them (skipped); the executability sweep reads the sandbox HOME's
# own settings.json and hook files.
mkdir -p "$HOME_SANDBOX/.claude/hooks" "$HOME_SANDBOX/.claude/enforce"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$HOME_SANDBOX/.claude/hooks/sample-hook.sh"
chmod +x "$HOME_SANDBOX/.claude/hooks/sample-hook.sh"
cat >"$HOME_SANDBOX/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/sample-hook.sh"}]}]}}
JSON
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --root "$SANDBOX" 2>&1)
check "verifiers skipped when not installed in sandbox HOME" grep -q "^skipped hook-registration: .*enforcement-guard-check.sh not installed" <<<"$OUT"
check "executable registered hook passes" grep -q "^pass hook-executability" <<<"$OUT"
chmod -x "$HOME_SANDBOX/.claude/hooks/sample-hook.sh"
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --root "$SANDBOX" 2>&1); ST=$?
check "non-executable hook fails naming it" grep -q "^fail hook-executability: .*sample-hook.sh" <<<"$OUT"
check "non-executable hook exits 1" test "$ST" -eq 1
# Home-path redaction (finding 2): the fail detail names the path under this
# invocation's HOME (here HOME_SANDBOX), which must render tilde-prefixed,
# never as the literal HOME value.
check "home path redacted to tilde in fail detail" grep -q "~/.claude/hooks/sample-hook.sh" <<<"$OUT"
check "literal HOME value absent from fail detail" not grep -q "$HOME_SANDBOX" <<<"$OUT"

# Task 3 review round 1: both real verifiers always exit 0 even when they
# have a finding (it travels as hookSpecificOutput.additionalContext JSON on
# stdout), so the doctor must branch on OUTPUT content, not exit status.
# These stubs encode the real contract's three shapes: a finding, silence,
# and an unhandled script error.
mkdir -p "$STUB_WARN/.claude/hooks" "$STUB_PASS/.claude/hooks" "$STUB_FAIL/.claude/hooks"
cat >"$STUB_WARN/.claude/hooks/enforcement-guard-check.sh" <<'STUB'
#!/usr/bin/env bash
jq -n --arg m "manifest hook missing" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
exit 0
STUB
chmod +x "$STUB_WARN/.claude/hooks/enforcement-guard-check.sh"
# review round 2: hook-integrity-check has its own entry in the explicit
# name map (enforcement-guard-check -> hook-registration is a different
# verifier); assert its name independently so half the map cannot go
# untested.
cat >"$STUB_WARN/.claude/hooks/hook-integrity-check.sh" <<'STUB'
#!/usr/bin/env bash
jq -n --arg m "hashes drifted" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
exit 0
STUB
chmod +x "$STUB_WARN/.claude/hooks/hook-integrity-check.sh"
cat >"$STUB_PASS/.claude/hooks/enforcement-guard-check.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_PASS/.claude/hooks/enforcement-guard-check.sh"
cat >"$STUB_FAIL/.claude/hooks/enforcement-guard-check.sh" <<'STUB'
#!/usr/bin/env bash
echo "boom: something broke"
exit 3
STUB
chmod +x "$STUB_FAIL/.claude/hooks/enforcement-guard-check.sh"

OUT=$(HOME="$STUB_WARN" bash "$DOCTOR" --root "$SANDBOX" 2>&1)
check "verifier finding surfaces as warn under hook-registration" grep -q "^warn hook-registration: .*manifest hook missing" <<<"$OUT"
check "verifier finding surfaces as warn under hook-integrity" grep -q "^warn hook-integrity: .*hashes drifted" <<<"$OUT"
OUT=$(HOME="$STUB_PASS" bash "$DOCTOR" --root "$SANDBOX" 2>&1)
check "silent zero-exit verifier passes as hook-registration" grep -q "^pass hook-registration: clean" <<<"$OUT"
OUT=$(HOME="$STUB_FAIL" bash "$DOCTOR" --root "$SANDBOX" 2>&1)
check "verifier nonzero exit fails as hook-registration" grep -q "^fail hook-registration: verifier errored:.*boom" <<<"$OUT"

# Task 4: environment probes (B-6). HOME_SANDBOX keeps this invocation off
# the live ~/.claude (finding 3): it drives the full script past option
# parsing, and its Task-3 hook-wiring section would otherwise read the real
# checkout's hooks and settings.
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --root "$REPO_TOP" 2>&1)
check "deps check reports" grep -qE "^(pass|fail) deps:" <<<"$OUT"
check "sandbox availability reports" grep -qE "^(pass|warn) sandbox-availability:" <<<"$OUT"

# Task 2: sandbox settings reporting (B-2). Each case builds its own
# --root tree with a minimal claude/settings.json so the check combines the
# OS-availability probe with settings.sandbox.enabled; macOS is always
# available here, so these three cases exercise the available+enabled and
# available+not-enabled arms. The unavailable+enabled/unavailable+not-enabled
# arms need a Linux host without bwrap/socat and are exercised by inspection
# of the doctor.sh branch, noted in the report.
sandboxReport() { # settings-json, expected-grep
  local dir; dir=$(mktemp -d); mkdir -p "$dir/claude"
  printf '%s\n' "$1" >"$dir/claude/settings.json"
  local out; out=$(bash "$DOCTOR" --root "$dir" 2>&1); local rc=0
  grep -qE "$2" <<<"$out" || rc=1
  rm -rf "$dir"; return $rc
}
check "sandbox enabled reports pass" sandboxReport '{"sandbox":{"enabled":true}}' '^pass sandbox-availability: .*enabled'
check "sandbox absent reports warn not-enabled" sandboxReport '{"model":"opusplan"}' '^warn sandbox-availability: .*not enabled'
check "sandbox disabled with block present reports warn configured-but-disabled" sandboxReport '{"sandbox":{"enabled":false}}' '^warn sandbox-availability: .*configured but disabled'

# Task 2 fix round 1: temp-write allowance regression guard. The harness
# outage this round fixes (sandbox.enabled:true synced live with no
# filesystem.allowWrite for the macOS system temp root broke every bare
# `mktemp` call, including this very suite's own sandbox-tree helpers) is a
# schema-shape drift: someone re-enables the sandbox later without carrying
# the allowance forward. Asserts the checked-in claude/settings.json still
# pairs sandbox.enabled:true with filesystem.allowWrite entries covering both
# the macOS system temp root (var/folders) and /tmp whenever the sandbox is
# on, so a future edit that drops the allowance fails here instead of at the
# next live session.
sandboxTempAllowancePresent() { # settings-file
  local enabled; enabled=$(jq -r '.sandbox.enabled // false' "$1")
  [ "$enabled" = "true" ] || return 0
  local allow; allow=$(jq -r '(.sandbox.filesystem.allowWrite // [])[]?' "$1")
  grep -qF 'var/folders' <<<"$allow" && grep -qF 'tmp' <<<"$allow"
}
check "committed sandbox block carries temp-write allowances when enabled" sandboxTempAllowancePresent "$REPO_TOP/claude/settings.json"

check "port freshness runs the translator" grep -qE "^(pass|fail) port-freshness:" <<<"$OUT"
# statusline unconfigured in the sandbox tree: must be skipped, never pass.
# HOME must point at a sandbox (the Task 3 HOME_SANDBOX, whose settings.json
# has no statusLine key) rather than the ambient live HOME: reading the real
# ~/.claude/settings.json here would break hermeticity and false-fail on any
# machine that does have a statusLine configured.
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --root "$SANDBOX" 2>&1)
check "unconfigured statusline is skipped" grep -q "^skipped statusline" <<<"$OUT"
# configured statusline in a sandbox HOME: probe runs the script with a sample payload.
SL_HOME_SANDBOX=$(mktemp -d); mkdir -p "$SL_HOME_SANDBOX/.claude"
printf '%s\n' '#!/usr/bin/env bash' 'echo "model | branch"' >"$SL_HOME_SANDBOX/.claude/status-line.sh"; chmod +x "$SL_HOME_SANDBOX/.claude/status-line.sh"
printf '%s\n' "{\"statusLine\":{\"type\":\"command\",\"command\":\"$SL_HOME_SANDBOX/.claude/status-line.sh\"}}" >"$SL_HOME_SANDBOX/.claude/settings.json"
OUT=$(HOME="$SL_HOME_SANDBOX" bash "$DOCTOR" --root "$SANDBOX" 2>&1)
check "configured statusline probe passes" grep -q "^pass statusline" <<<"$OUT"
rm -rf "$SL_HOME_SANDBOX"

# Task 5: --full and --release (B-4). Every invocation below sets HOME to
# HOME_SANDBOX (finding 3): doctor.sh's Task-3 hook-wiring section runs
# unconditionally on every invocation regardless of --root/--full/--release,
# so an unset HOME here would read the live ~/.claude checkout.
RELEASE_SANDBOX=$(mktemp -d)
mkdir -p "$RELEASE_SANDBOX/claude"
git -C "$RELEASE_SANDBOX" init -q
printf '%s\n' '{"model":"opusplan"}' >"$RELEASE_SANDBOX/claude/settings.json"
printf '%s\n' "# Issues" "- PENDING USER ACTION (probe): rotate something." >"$RELEASE_SANDBOX/claude/ISSUES.md"
git -C "$RELEASE_SANDBOX" add -A && git -C "$RELEASE_SANDBOX" -c user.email=t@t -c user.name=t commit -qm seed
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --release --root "$RELEASE_SANDBOX" 2>&1); ST=$?
check "pending user action fails release" grep -q "^fail release-blockers: .*PENDING USER ACTION" <<<"$OUT"
check "release gate exits 1" test "$ST" -eq 1
# Recursion-safety bound (review round 1): --release implies --full, and this
# very fixture suite runs doctor.sh --release against $RELEASE_SANDBOX, so
# doctor.sh's fixture-suites loop would run this suite again unless the
# sandbox lacks the two suite paths it looks for. It does (the sandbox tree
# has only claude/settings.json and claude/ISSUES.md), so the loop's first
# `[ -f "$suite" ]` check misses before running anything. That bound holds
# regardless of verdict. Under --release the missing suite must now escalate
# to fail (finding 1: skipped can never count toward release readiness); a
# plain --full run on the same sandbox (no --release) still just skips it,
# so both behaviors stay locked.
check "fixture suites fail under release when suite paths are missing" grep -q "^fail fixture-suites: .*run-tests.sh missing" <<<"$OUT"
OUT_FULL_NONRELEASE=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --full --root "$RELEASE_SANDBOX" 2>&1)
check "fixture suites still skipped under plain --full" grep -q "^skipped fixture-suites: .*run-tests.sh missing" <<<"$OUT_FULL_NONRELEASE"
# Release-mode skipped-gate escalation also applies to release-secret-scan:
# a release run whose pattern file is missing entirely (neither
# $ROOT_DIR/claude/enforce nor doctor.sh's own directory carries
# secret-patterns.txt) must fail, not skip. Run a copy of doctor.sh from a
# directory with no sibling secret-patterns.txt so the fallback also misses.
NOPATTERNS_SANDBOX=$(mktemp -d)
cp "$DOCTOR" "$NOPATTERNS_SANDBOX/doctor.sh"
OUT_NOPATTERNS=$(HOME="$HOME_SANDBOX" bash "$NOPATTERNS_SANDBOX/doctor.sh" --release --root "$RELEASE_SANDBOX" 2>&1)
check "missing pattern file fails release scan under release mode" grep -q "^fail release-secret-scan: .*pattern file" <<<"$OUT_NOPATTERNS"
rm -rf "$NOPATTERNS_SANDBOX"
# Clean ISSUES: release-blockers passes; a planted runtime-built secret in a tracked file fails the scan.
printf '%s\n' "# Issues" >"$RELEASE_SANDBOX/claude/ISSUES.md"
repeat() { printf "$1%.0s" $(seq 1 "$2"); }
printf '%s\n' "key = sk-ant-api03-$(repeat A 54)" >"$RELEASE_SANDBOX/claude/notes.md"
git -C "$RELEASE_SANDBOX" add -A && git -C "$RELEASE_SANDBOX" -c user.email=t@t -c user.name=t commit -qm plant
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --release --root "$RELEASE_SANDBOX" 2>&1); ST=$?
check "tracked secret fails release scan naming the file" grep -q "^fail release-secret-scan: .*notes.md" <<<"$OUT"
# Home-path branch (review round 1): the release-secret-scan's home-path
# check is scoped to THIS machine's real username (id -un), not a blanket
# /Users/... match, so a generic placeholder path stays allowed while a
# runtime-built literal path using the real username must fail naming the
# file. Built at runtime, never a literal in this file, same convention as
# the planted secret above.
CURRENT_USER=$(id -un)
printf '%s\n' "note: /Users/${CURRENT_USER}/scratch/x" >"$RELEASE_SANDBOX/claude/homepath.md"
git -C "$RELEASE_SANDBOX" add -A && git -C "$RELEASE_SANDBOX" -c user.email=t@t -c user.name=t commit -qm "plant home path"
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --release --root "$RELEASE_SANDBOX" 2>&1); ST=$?
check "real home path fails release scan naming the file" grep -q "^fail release-secret-scan: .*homepath.md" <<<"$OUT"
check "real home path release gate exits 1" test "$ST" -eq 1
rm -f "$RELEASE_SANDBOX/claude/homepath.md" "$RELEASE_SANDBOX/claude/notes.md"
git -C "$RELEASE_SANDBOX" add -A && git -C "$RELEASE_SANDBOX" -c user.email=t@t -c user.name=t commit -qm "clean release sandbox"
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --release --root "$RELEASE_SANDBOX" 2>&1)
check "clean tracked tree passes release scan" grep -q "^pass release-secret-scan" <<<"$OUT"
# Mangled Claude-Code project-dir path leak (ruled addition): Claude Code
# names session-scoped project directories by mangling the checkout path's
# slashes to dashes ("-Users-<user>-..."), so the release scan must also
# catch that literal form alongside "/Users/<user>/".
printf '%s\n' "note: -Users-${CURRENT_USER}-dev-project" >"$RELEASE_SANDBOX/claude/mangledpath.md"
git -C "$RELEASE_SANDBOX" add -A && git -C "$RELEASE_SANDBOX" -c user.email=t@t -c user.name=t commit -qm "plant mangled home path"
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --release --root "$RELEASE_SANDBOX" 2>&1); ST=$?
check "mangled home path fails release scan naming the file" grep -q "^fail release-secret-scan: .*mangledpath.md" <<<"$OUT"
check "mangled home path release gate exits 1" test "$ST" -eq 1
rm -f "$RELEASE_SANDBOX/claude/mangledpath.md"
git -C "$RELEASE_SANDBOX" add -A && git -C "$RELEASE_SANDBOX" -c user.email=t@t -c user.name=t commit -qm "clean mangled path"
OUT=$(HOME="$HOME_SANDBOX" bash "$DOCTOR" --release --root "$RELEASE_SANDBOX" 2>&1)
check "clean tracked tree passes release scan after mangled-path clean" grep -q "^pass release-secret-scan" <<<"$OUT"
rm -rf "$RELEASE_SANDBOX"

[ "$fail" -eq 0 ] && echo "doctor.test.sh PASS" || exit 1
