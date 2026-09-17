#!/usr/bin/env bash
# harness-sync.test.sh: verifies hooks/harness-sync.sh (R-003) against a
# sandbox checkout and a fake HOME: the first run syncs the checkout's tracked
# claude/ files into ~/.claude and says so; a second run finds no drift and
# stays silent locally; a drifted live file is re-synced; with no reachable
# checkout the hook is silent locally and reports once in a remote session;
# a sync.sh refusal (invalid JSON) leaves the live tree unchanged and is
# reported. Needs rsync, which sync.sh needs too.
set -uo pipefail
HOOK="$HOME/.claude/hooks/harness-sync.sh"
REAL_SYNC="$(cd "$(dirname "$(readlink -f "$HOME/.claude")")" && pwd)/sync.sh"
[ -f "$REAL_SYNC" ] || REAL_SYNC="$(cat "$HOME/.claude/.sync-source" 2>/dev/null)/sync.sh"
[ -f "$REAL_SYNC" ] || { echo "FAIL: cannot locate the checkout's sync.sh from $HOME/.claude"; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "FAIL: rsync is required by sync.sh and this fixture"; exit 1; }
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
# The session running this fixture may itself be an agent-governance checkout
# in a remote container; neither must leak into the sandbox.
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_REMOTE

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
context() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
reports() { context | grep -qF "$1"; }
silent() { [ -z "$OUT" ]; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
CO="$SB/agent-governance"; mkdir -p "$CO/claude/hooks" "$CO/cursor" "$CO/codex"
git -C "$CO" init -q -b main
git -C "$CO" config user.email t@example.invalid; git -C "$CO" config user.name t
cp "$REAL_SYNC" "$CO/sync.sh"; chmod +x "$CO/sync.sh"
printf '# rules\n' > "$CO/claude/CLAUDE.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CO/claude/hooks/sample.sh"
printf '{"hooks":{}}\n' > "$CO/claude/settings.json"
printf '# cursor\n' > "$CO/cursor/README.md"; printf '# codex\n' > "$CO/codex/README.md"
git -C "$CO" add -A; git -C "$CO" commit -qm init
FAKE="$SB/home"; mkdir -p "$FAKE"
export HARNESS_SYNC_HOME="$FAKE" SYNC_CURSOR_HOME="$SB/home/.cursor" SYNC_CODEX_HOME="$SB/home/.codex"

# 1. Bootstrap: nothing live, checkout passed as the argument.
OUT=$(printf '{}' | CLAUDE_CODE_REMOTE=true bash "$HOOK" "$CO" 2>/dev/null)
check "bootstrap syncs the live tree" test -f "$FAKE/.claude/hooks/sample.sh"
check "bootstrap copies the rules" cmp -s "$CO/claude/CLAUDE.md" "$FAKE/.claude/CLAUDE.md"
check "bootstrap stamps the source" test "$(cat "$FAKE/.claude/.sync-source")" = "$CO"
check "bootstrap reports the count" reports "synced 3 changed or missing file(s) from $CO"

# 2. No drift: silent locally, in-sync line remotely, source found from the stamp.
OUT=$(printf '{}' | bash "$HOOK" 2>/dev/null)
check "in sync is silent locally" silent
OUT=$(printf '{}' | CLAUDE_CODE_REMOTE=true bash "$HOOK" 2>/dev/null)
check "in sync is reported remotely" reports "live ~/.claude matches $CO"

# 3. Drift: a live file edited out from under the checkout is re-synced.
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/.claude/hooks/sample.sh"
OUT=$(printf '{}' | bash "$HOOK" 2>/dev/null)
check "drifted file re-synced" cmp -s "$CO/claude/hooks/sample.sh" "$FAKE/.claude/hooks/sample.sh"
check "drift reported with its count" reports "synced 1 changed or missing file(s)"

# 4. No reachable checkout: silent locally, one report remotely.
rm -rf "$FAKE/.claude"
OUT=$(printf '{}' | bash "$HOOK" 2>/dev/null)
check "no checkout is silent locally" silent
OUT=$(printf '{}' | CLAUDE_CODE_REMOTE=true bash "$HOOK" 2>/dev/null)
check "no checkout reported remotely" reports "runs WITHOUT the synced harness"
check "no checkout writes nothing" test ! -e "$FAKE/.claude"

# 5. A sync.sh refusal (invalid JSON in the checkout) is reported, live tree untouched.
printf '{"hooks":' > "$CO/claude/settings.json"; git -C "$CO" commit -qam "break json"
OUT=$(printf '{}' | bash "$HOOK" "$CO" 2>/dev/null)
check "sync refusal reported" reports "sync.sh failed"
check "sync refusal leaves the live tree absent" test ! -e "$FAKE/.claude/CLAUDE.md"

[ "$fail" -eq 0 ] && echo "harness-sync.test.sh PASS"
exit "$fail"
