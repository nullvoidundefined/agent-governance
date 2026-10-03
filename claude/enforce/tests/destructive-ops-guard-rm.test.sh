#!/usr/bin/env bash
# Coverage declaration for hook:destructive-ops-guard lands with its manifest
# row when slice B-1 closes (IAN-606), since the closure check needs the hook.
# Verifies slice B-3 of destructive-ops-guard.sh: the rm tier of owner
# decision 1 in docs/slices/slice-05-destructive-ops-guard.md.
#
#   deny    any delete (rm with any flags or none, unlink, rmdir, trash,
#           find -delete or -exec rm, xargs rm, rsync --delete) or truncation
#           whose target resolves to /, home, an entry directly under home,
#           a path outside the repository (through .. or written absolute), a
#           glob at home or root level, or an unset or empty variable
#   ask     every other recursive or forced delete, find -delete or -exec rm,
#           xargs rm, rsync --delete, git clean -f in any flag order, and
#           interpreter one-liners that delete
#   silent  plain rm or rmdir inside the repository, and commands that only
#           mention rm as text
#
# The environment is built in a temp dir: a fake HOME holding Library,
# Documents, Desktop, Downloads, a dotdir, and a dotfile, with HOME exported
# to the hook, and a git repository at HOME/code/proj that is the hook's cwd
# (the repository root). The real HOME is never touched. UNSET_VAR is removed
# from the hook's environment and EMPTY_VAR is set to the empty string.
#
# When a command holds several segments the strongest decision wins. The hook
# must exit 0 in every case; every run is bounded with timeout.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/destructive-ops-guard.sh"

JQ=$(command -v jq) || { echo "FAIL: setup: jq is required to run this fixture"; exit 1; }
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
[ -n "$TIMEOUT_BIN" ] || { echo "FAIL: setup: timeout (or gtimeout) is required to bound the hook"; exit 1; }
# Every hook run is killed after this many seconds; a kill is a FAIL.
RUN_BOUND=20

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)

FAKE_HOME="$WORK/home"
for entry in Library Documents Desktop Downloads .ssh code/sibling; do
  mkdir -p "$FAKE_HOME/$entry"
done
: > "$FAKE_HOME/.zshrc"
: > "$FAKE_HOME/x"

REPO="$FAKE_HOME/code/proj"
mkdir -p "$REPO/src" "$REPO/emptydir" "$REPO/node_modules/pkg" "$REPO/dist" "$REPO/build" "$REPO/out" "$REPO/empty"
: > "$REPO/notes.txt"
: > "$REPO/src/a.ts"
: > "$REPO/src/b.ts"
: > "$REPO/a.log"
: > "$REPO/list"
: > "$REPO/build/x.o"
(cd "$REPO" && HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 git init -q) \
  || { echo "FAIL: setup: git init failed in the temp repository"; exit 1; }

OUTSIDE="$WORK/elsewhere"
mkdir -p "$OUTSIDE"

payload() {
  "$JQ" -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}

# run_hook <command> <cwd>: runs the hook with the fake HOME, UNSET_VAR unset
# and EMPTY_VAR empty, bounded; sets OUT and STATUS.
run_hook() {
  STATUS=0
  OUT=$(payload "$1" "$2" | "$TIMEOUT_BIN" "$RUN_BOUND" env -u UNSET_VAR HOME="$FAKE_HOME" EMPTY_VAR= "$HOOK" 2>/dev/null) || STATUS=$?
}

# decision_of <label>: from OUT and STATUS, sets DECISION (none, deny, ask).
decision_of() {
  [ "$STATUS" -ne 124 ] || { echo "FAIL: hook did not finish within ${RUN_BOUND}s for: $1"; exit 1; }
  [ "$STATUS" -eq 0 ] || { echo "FAIL: hook exited $STATUS (must always exit 0) for: $1"; exit 1; }
  if [ -z "$OUT" ]; then
    DECISION=none
    return
  fi
  DECISION=$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null) \
    || { echo "FAIL: hook printed output that is not JSON for: $1: $OUT"; exit 1; }
  event=$(printf '%s' "$OUT" | "$JQ" -r '.hookSpecificOutput.hookEventName // ""')
  [ "$event" = "PreToolUse" ] || { echo "FAIL: hookEventName was '$event', not PreToolUse for: $1"; exit 1; }
}

# expect <deny|ask|none> <command> [cwd]
expect() {
  cwd=${3:-$REPO}
  run_hook "$2" "$cwd"
  decision_of "$2 (cwd $cwd)"
  [ "$DECISION" = "$1" ] || { echo "FAIL: expected $1, got $DECISION for: $2 (cwd $cwd)"; exit 1; }
}

# expect_each <decision> <cwd>: reads one command per line from stdin.
expect_each() {
  while IFS= read -r command_text; do
    [ -n "$command_text" ] || continue
    expect "$1" "$command_text" "$2"
  done
}

# Every recursive or forced flag spelling, crossed with every protected target.
RM_FLAGS=$(cat <<'EOF'
-rf
-fr
-Rf
-R
-rfv
-r -f
-f -r
--recursive --force
-f
-r
--force
EOF
)
PROTECTED_TARGETS=$(cat <<EOF
/
/*
~
~/
\$HOME
"\$HOME"
\${HOME}
\$HOME/
~/Library
~/Documents
~/Desktop
~/Downloads
~/.ssh
~/*
~/.*
..
../..
../sibling
../../Library
$OUTSIDE
/etc/hosts
/usr/local/lib
\$UNSET_VAR/
\${UNSET_VAR}/x
\$EMPTY_VAR/
~root
EOF
)
while IFS= read -r flags; do
  [ -n "$flags" ] || continue
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    expect deny "rm $flags $target"
  done <<< "$PROTECTED_TARGETS"
done <<< "$RM_FLAGS"

# Plain rm with no flags against a target outside the repository, and targets
# after an end-of-options marker.
expect_each deny "$REPO" <<EOF
rm /etc/hosts
rm $OUTSIDE/file
rm ~/.zshrc
rm ~/x
rm \$HOME/.zshrc
rm ../sibling/file
rm notes.txt ~/.zshrc
rm -- ~/.zshrc
rm -- /etc/hosts
rm -rf -- ~
rm -rf -- /
rm -f -- ~/Documents
rm -rf node_modules ~/Library
EOF

# Wrappers and indirection around a protected delete.
expect_each deny "$REPO" <<'EOF'
/bin/rm -rf ~
/usr/bin/rm -rf ~
\rm -rf ~
command rm -rf ~
env rm -rf ~
sudo rm -rf /
nohup rm -rf ~
timeout 5 rm -rf ~
bash -c "rm -rf ~"
sh -c 'rm -rf ~'
zsh -c 'rm -rf ~'
eval "rm -rf ~"
(rm -rf ~)
{ rm -rf ~; }
cd / && rm -rf *
cd ~ && rm -rf Library
cd ~; rm -rf Documents
echo ~ | xargs rm -rf
find ~ -delete
find / -exec rm -f {} +
find ~/Documents -name '*.pdf' -delete
rsync -a --delete empty/ ~/
unlink ~/x
trash ~/Documents
rmdir ~/Documents
rm -rf node_modules && rm -rf ~
ls; rm -f ~/.zshrc
: > ~/.zshrc
> ~/.zshrc
truncate -s 0 ~/.zshrc
EOF

# Recursive or forced deletes inside the repository ask.
expect_each ask "$REPO" <<EOF
rm -rf node_modules
rm -fr dist
rm -Rf build
rm -r build/
rm -f a.log
rm -r -f dist
rm --recursive --force dist
rm -rf $REPO/dist
rm -rf ./dist
find . -name '*.o' -delete
find . -exec rm {} +
find build -execdir rm {} \\;
xargs rm -f < list
git clean -fdx
git clean -xdf
git clean -f -d
git clean -f
rsync -a --delete src/ out/
python3 -c "import shutil; shutil.rmtree('build')"
python3 -c "import os; os.remove('a.log')"
node -e "require('fs').rmSync('dist',{recursive:true})"
node -e "require('fs').rm('dist',{recursive:true},()=>{})"
npx rimraf dist
perl -e 'use File::Path; rmtree("build")'
rm notes.txt; rm -rf dist
sudo rm -rf node_modules
bash -c "rm -rf node_modules"
EOF

# A cwd below the repository root: .. still resolves inside the repository.
expect ask "rm -rf ../dist" "$REPO/src"
expect none "rm ../notes.txt" "$REPO/src"
expect deny "rm -rf ../../sibling" "$REPO/src"

# Plain deletes inside the repository, and commands that only mention rm.
expect_each none "$REPO" <<EOF
rm notes.txt
rm src/a.ts src/b.ts
rm build/x.o
rm $REPO/notes.txt
rmdir emptydir
: > notes.txt
ls -la
echo rm -rf ~
git commit -m "rm -rf ~"
grep -rn "rm -rf" .
git clean -n
git status
EOF

echo "PASS: destructive-ops-guard-rm"
