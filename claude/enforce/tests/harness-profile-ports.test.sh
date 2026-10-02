#!/usr/bin/env bash
# Shard: slow
# Watches: translate/* cursor/* codex/* enforce/harness-profiles.json
# Verifies the --profile flag of translate/cursor.mjs and translate/codex.mjs
# (IAN-518). With no profile the committed ports stay byte-identical, so
# --check passes on the real repository. With --profile lean each exporter
# renders from the filtered claude/ set that translate/apply-profile.mjs
# returns: the listed rules, hooks, SKILL.md files, audit agents, and
# reference files are gone, while skill scripts still port. A source the
# active profile did not remove is still a hard error, so the tolerance for
# missing files cannot hide an accidental deletion. Runs the lean write in a
# copy of the tracked tree, never in the repository itself.
set -uo pipefail
REPO_TOP=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
not() { ! "$@"; }
lacks() { ! grep -q -- "$1" "$2"; }

# copy_tracked <dest>: the tracked claude/, translate/, cursor/, and codex/
# files, staged ones included, as a repo-shaped --root.
copy_tracked() {
  mkdir -p "$1"
  git -C "$REPO_TOP" ls-files -- claude translate cursor codex >"$TMP/tracked.txt"
  rsync -a --files-from="$TMP/tracked.txt" "$REPO_TOP/" "$1/"
}

# No profile: the committed ports are current, byte for byte.
node "$REPO_TOP/translate/cursor.mjs" --check >"$TMP/cursor-check.log" 2>&1
check "cursor --check passes on the repository with no profile" test $? -eq 0
node "$REPO_TOP/translate/codex.mjs" --check >"$TMP/codex-check.log" 2>&1
check "codex --check passes on the repository with no profile" test $? -eq 0

ROOT="$TMP/root"
copy_tracked "$ROOT"
node "$ROOT/translate/cursor.mjs" --profile lean --write --root "$ROOT" >"$TMP/cursor-lean.log" 2>&1
check "cursor --profile lean --write exits 0" test $? -eq 0
node "$ROOT/translate/codex.mjs" --profile lean --write --root "$ROOT" >"$TMP/codex-lean.log" 2>&1
check "codex --profile lean --write exits 0" test $? -eq 0
node "$ROOT/translate/cursor.mjs" --profile lean --check --root "$ROOT" >/dev/null 2>&1
check "cursor --profile lean --check passes after the lean write" test $? -eq 0
node "$ROOT/translate/codex.mjs" --profile lean --check --root "$ROOT" >/dev/null 2>&1
check "codex --profile lean --check passes after the lean write" test $? -eq 0
node "$ROOT/translate/cursor.mjs" --check --root "$ROOT" >/dev/null 2>&1
check "cursor --check with no profile reports the lean tree as stale" test $? -eq 1
node "$ROOT/translate/codex.mjs" --check --root "$ROOT" >/dev/null 2>&1
check "codex --check with no profile reports the lean tree as stale" test $? -eq 1

# Cursor lean tree.
C="$ROOT/cursor"
check "cursor lean drops R-104" lacks '^R-104:' "$C/rules/000-global-rules.mdc"
check "cursor lean drops R-308" lacks '^R-308:' "$C/rules/000-global-rules.mdc"
check "cursor lean keeps R-101" grep -q '^R-101:' "$C/rules/000-global-rules.mdc"
check "cursor lean keeps R-517" grep -q '^R-517:' "$C/rules/000-global-rules.mdc"
check "cursor lean drops the session-types rule" test ! -e "$C/rules/001-session-types.mdc"
check "cursor lean drops the python stack rule" test ! -e "$C/rules/python.mdc"
check "cursor lean drops the structure-conventions rule" test ! -e "$C/rules/structure-conventions.mdc"
check "cursor lean drops rulebook-cost" test ! -e "$C/rules/rulebook-cost.mdc"
check "cursor lean keeps the reference rulebook bands" test -e "$C/rules/rulebook-reference-r1xx-secrets-and-trust.mdc"
check "cursor lean drops skills/gof" test ! -e "$C/skills/gof/SKILL.md"
check "cursor lean drops the task-start SKILL.md" test ! -e "$C/skills/task-start/SKILL.md"
check "cursor lean keeps task-tier.sh executable" test -x "$C/skills/task-start/scripts/task-tier.sh"
check "cursor lean keeps build-lane.sh" test -f "$C/skills/build-fast/scripts/build-lane.sh"
check "cursor lean drops the audit agents" test ! -e "$C/agents/audit-ux.md"
check "cursor lean keeps spec-conformance-review" test -f "$C/agents/spec-conformance-review.md"
check "cursor lean hooks.json drops session-start" lacks 'session-start' "$C/hooks.json"
check "cursor lean hooks.json keeps secret-scan" grep -q 'secret-scan' "$C/hooks.json"
check "cursor lean keeps hand-authored README" test -f "$C/README.md"

# Codex lean tree.
X="$ROOT/codex"
check "codex lean drops R-104" lacks '^R-104:' "$X/AGENTS.md"
check "codex lean keeps R-101" grep -q '^R-101:' "$X/AGENTS.md"
check "codex lean drops the session-types appendix" lacks '^# Session Types' "$X/AGENTS.md"
check "codex lean drops skills/gof" test ! -e "$X/skills/gof/SKILL.md"
check "codex lean keeps task-tier.sh executable" test -x "$X/skills/task-start/scripts/task-tier.sh"
check "codex lean drops audit agents" test ! -e "$X/agents/audit-ux.toml"
check "codex lean keeps test-author" test -f "$X/agents/test-author.toml"
check "codex lean hooks.json drops session-start" lacks 'session-start' "$X/hooks.json"
check "codex lean hooks.json keeps secret-scan" grep -q 'secret-scan' "$X/hooks.json"

# Unknown profile: a usage-level error, exit 2, nothing written.
node "$ROOT/translate/cursor.mjs" --profile no-such-profile --check --root "$ROOT" >/dev/null 2>&1
check "cursor refuses an unknown profile with exit 2" test $? -eq 2
node "$ROOT/translate/codex.mjs" --profile no-such-profile --check --root "$ROOT" >/dev/null 2>&1
check "codex refuses an unknown profile with exit 2" test $? -eq 2
node "$ROOT/translate/codex.mjs" --profile --check --root "$ROOT" >/dev/null 2>&1
check "codex refuses a bare --profile with exit 2" test $? -eq 2

# A missing source the profile did not remove is still a SourceError.
BROKEN="$TMP/broken"
copy_tracked "$BROKEN"
rm "$BROKEN/claude/rules/session-types.md"
node "$BROKEN/translate/cursor.mjs" --check --root "$BROKEN" >/dev/null 2>&1
check "cursor with no profile still refuses a missing session-types.md" test $? -eq 2
node "$BROKEN/translate/codex.mjs" --check --root "$BROKEN" >/dev/null 2>&1
check "codex with no profile still refuses a missing session-types.md" test $? -eq 2
rm "$BROKEN/claude/skills/gof/SKILL.md"
echo "helper" >"$BROKEN/claude/skills/gof/notes.txt"
cp "$REPO_TOP/claude/rules/session-types.md" "$BROKEN/claude/rules/session-types.md"
node "$BROKEN/translate/cursor.mjs" --check --root "$BROKEN" >/dev/null 2>&1
check "cursor with no profile still refuses a skill folder without SKILL.md" test $? -eq 2

exit "$fail"
