#!/usr/bin/env bash
# Covers: hook:lexicon-gate
# Verifies hooks/lexicon-gate.sh (R-330 walking-skeleton clause, IAN-365): a
# Write of a brand-new file with a gated source extension, inside a git work
# tree that carries no "## Domain vocabulary" heading anywhere, is denied. An
# existing file, a non-source extension, a repo that already has the heading
# somewhere, a path outside any work tree, and any other tool are allowed.
# Every repository is a sandbox; the real ~/.claude is never read or written.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/lexicon-gate.sh"

fail=0
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
SB=$(cd "$SB" && pwd -P)
OUT=""

check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; echo "  output was: $OUT"; fail=1; fi; }
is_deny() { jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<< "$OUT"; }
is_silent() { [ -z "$OUT" ]; }
reason_has() { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "$OUT" 2>/dev/null | grep -qF -- "$1"; }

# make_repo <name>: an empty git work tree, no glossary anywhere; prints its path.
make_repo() {
  local dir="$SB/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  printf '%s' "$dir"
}

# file_gate <file> [cwd]: runs the hook on a Write of <file>, optionally with a
# .cwd field (for a relative <file>); sets OUT.
file_gate() {
  if [ -n "${2:-}" ]; then
    OUT=$(jq -nc --arg f "$1" --arg d "$2" \
      '{tool_name:"Write",cwd:$d,tool_input:{file_path:$f,content:"x"}}' | "$HOOK" 2>/dev/null)
  else
    OUT=$(jq -nc --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' | "$HOOK" 2>/dev/null)
  fi
}

check "hook exists and is executable" test -x "$HOOK"

# L-1: a repo with no glossary anywhere denies a brand-new source file.
R=$(make_repo l1)
file_gate "$R/src/new_thing.py"
check "L-1 new source file with no glossary denies" is_deny
check "L-1 reason names R-330" reason_has "R-330"
check "L-1 reason names the file" reason_has "src/new_thing.py"
check "L-1 reason names docs/lexicon.md" reason_has "docs/lexicon.md"

# L-2: every gated extension denies the same way.
for ext in ts tsx js jsx mjs py rb go vue; do
  R=$(make_repo "l2-$ext")
  file_gate "$R/src/new.$ext"
  check "L-2 .$ext denies" is_deny
done

# L-3: a non-gated extension (markdown, json, yaml) allows.
R=$(make_repo l3)
file_gate "$R/docs/notes.md"
check "L-3 markdown allows" is_silent
file_gate "$R/config.json"
check "L-3 json allows" is_silent

# L-4: a repo that already carries the heading, anywhere, allows.
R=$(make_repo l4)
mkdir -p "$R/docs"
printf '# Spec\n\n## Domain vocabulary\n\n- posting - a job posting\n' > "$R/docs/spec.md"
file_gate "$R/src/new_thing.py"
check "L-4 repo with the heading allows" is_silent

# L-5: the heading in a nested doc, not just docs/spec.md, still satisfies the gate.
R=$(make_repo l5)
mkdir -p "$R/notes"
printf 'Some prose.\n\n## Domain vocabulary\n\nEntries go here.\n' > "$R/notes/anything.md"
file_gate "$R/src/new_thing.go"
check "L-5 heading in any markdown file allows" is_silent

# L-6: an existing file (an Edit target, or a Write that overwrites) allows,
# since its walking-skeleton moment has already passed.
R=$(make_repo l6)
mkdir -p "$R/src"
printf 'existing = 1\n' > "$R/src/already_here.py"
file_gate "$R/src/already_here.py"
check "L-6 existing file allows" is_silent

# L-7: a path outside any git work tree allows.
PLAIN="$SB/plain"; mkdir -p "$PLAIN/src"
file_gate "$PLAIN/src/new_thing.py"
check "L-7 path outside any work tree allows" is_silent

# L-8: a non-Write tool (Edit, Bash) is never matched by this hook's own logic;
# the settings.json matcher is what scopes it to Write, but the hook itself
# only reads tool_input.file_path, so it is exercised through the same
# payload shape here rather than duplicated per tool.
R=$(make_repo l8)
OUT=$(jq -nc --arg f "$R/src/new_thing.py" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}' | "$HOOK" 2>/dev/null)
check "L-8 Edit payload (no glossary) still denies a brand-new path" is_deny

# L-9: a linked git worktree is still "inside a git work tree." A worktree's
# .git is a file (a gitdir: pointer), not a directory, so a repo-root walk
# that only tests `-d "$dir/.git"` never recognizes it and silently allows.
R=$(make_repo l9)
printf 'seed\n' > "$R/README.md"
git -C "$R" add -A; git -C "$R" commit -qm seed
WT="$SB/l9-worktree"
git -C "$R" worktree add -q -b l9-branch "$WT" >/dev/null 2>&1
file_gate "$WT/src/new_thing.py"
check "L-9 new file in a linked worktree with no glossary denies" is_deny

# L-10: an unrelated read error elsewhere in the tree (a permission-denied
# sibling directory) must fail open, not be read as "no glossary anywhere,"
# even though the glossary genuinely exists elsewhere in the same repo.
R=$(make_repo l10)
mkdir -p "$R/docs" "$R/locked"
printf '# Spec\n\n## Domain vocabulary\n\n- posting - a job posting\n' > "$R/docs/spec.md"
printf 'x\n' > "$R/locked/secret.md"
chmod 000 "$R/locked"
file_gate "$R/src/new_thing.py"
check "L-10 unrelated permission error fails open (glossary exists elsewhere)" is_silent
chmod 755 "$R/locked"

# L-11: a relative file_path resolves against the PreToolUse payload's own
# .cwd, not the hook process's bare $PWD, which need not be the same
# directory the tool call is scoped to.
R=$(make_repo l11)
file_gate "src/new_thing.py" "$R"
check "L-11 relative file_path resolves against payload .cwd, not bare PWD" is_deny

# L-12: a .d.ts declaration file is not a hand-written source file (R-320
# already exempts it from the file-header requirement); the gate should not
# treat it as one either.
R=$(make_repo l12)
file_gate "$R/src/types.d.ts"
check "L-12 .d.ts declaration file allows" is_silent

exit $fail
