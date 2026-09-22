#!/usr/bin/env bash
# Watches: hooks/*.sh settings.json enforce/harness-root.sh
# hook-path-walk-budget.test.sh: the per-event cost of the PreToolUse
# Write|Edit chain must not grow with the DEPTH of the path being written.
#
# Why this exists, and why it is not a timing check. hook-latency.test.sh
# bounds the same chain in wall-clock milliseconds against a bare-spawn
# control taken in the same run. That check is honest about what a session
# pays, but both its measurement and its budget are noisy, so it sat on its
# own budget line and tipped over under load: IAN-183 recorded 296ms against
# a 294ms budget, 354ms against 318ms, and 279ms against 288ms on three
# consecutive runs with no change between them. The cost of that flake is not
# a red fixture, it is that `tdd.sh red` refuses to certify any slice while
# the suite is red, so a timing wobble blocks the RED step of every unrelated
# slice.
#
# Raising the budget was refused (R-204): the chain really was close to it.
# The reason it was close is measurable without a clock. Three hooks in the
# chain walked the written path one component at a time and spawned a process
# per component to do it, so a session paid a `dirname` or a `basename`
# process for every directory level in every file it wrote:
#
#   protected-path-guard.sh  physical_path's deepest-existing-ancestor loop,
#                            one `basename` plus one `dirname` per level
#   structure-gate.sh        find_package_file's walk toward package.json,
#                            one `dirname` per level, six levels
#   content-gate.sh          the R-302 climb-depth check's walk to an
#                            existing directory, one `dirname` per level
#
# Measured on the chain as it stood: 74 processes for `/x/a.ts`, 92 for
# `/x/b/c/d/a.ts`, and 118 for `/x/b/c/d/e/f/g/h/i/j/a.ts`, about five more
# processes for every extra directory level. Bash strips a path component with
# parameter expansion (`${path%/*}`, `${path##*/}`) and no process at all, so
# that growth was pure waste and it is what put the timing check on its line.
#
# Counting processes rather than timing them is the shape IAN-115 arrived at
# for the same class of defect in harness-sync.sh (PR #67, case 3f): a timing
# proxy can pass a per-component loop on a fast runner and fail a correct
# implementation on a slow one, while a process count is the same number on
# every machine and under any load. This fixture therefore makes no claim
# about milliseconds. It claims only that the chain's process cost is flat in
# path depth, which is the property that keeps the wall-clock check's margin
# real.
#
# The chain is read from settings.json rather than listed here, for the reason
# hook-latency.test.sh gives: a hand-kept list drifted from the registered
# chain three audits running and left newly registered hooks unmeasured.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOKS_DIR="$CLAUDE_HARNESS_ROOT/hooks"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$CLAUDE_HARNESS_ROOT/settings.json}"

# A shallow path and a deep one, both outside any git repository so that every
# hook in the chain takes the same branch for both and the only difference
# between the two runs is the number of directory levels. Nine extra levels is
# enough that a per-component spawn is unmistakable and still a path a real
# monorepo could hold.
SHALLOW_PATH="/x/a.ts"
DEEP_PATH="/x/b/c/d/e/f/g/h/i/j/a.ts"
EXTRA_LEVELS=9

# Flat in depth means flat, but a couple of processes of slack keeps the
# fixture from failing on an incidental difference that is not per-component
# growth (a longer path printed through one extra `sed`, say). Anything that
# scales with depth clears this by a wide margin: the pre-fix chain spent 44.
DEPTH_BUDGET=6

WRITE_HOOKS=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Write|Edit") | .hooks[].command' "$SETTINGS" | sed 's#.*/##' | tr '\n' ' ')
[ -n "$WRITE_HOOKS" ] || { echo "FAIL: could not read the PreToolUse Write|Edit chain from $SETTINGS" >&2; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hook-path-walk.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SHIM_DIR="$SANDBOX/shim"
mkdir -p "$SHIM_DIR"

# A sandboxed HOME carrying a ticket tracker, and the reason this fixture needs
# one. ticket-at-start-gate.sh is in this chain and returns at its second line
# when `$HOME/.claude/TICKET-TRACKER.json` is absent, before either of its two
# path walks runs. A container without a tracker therefore measures a shorter
# chain than a developer machine, and the first version of this fixture passed
# here while failing on any machine configured the way R-605 requires: the
# chain grew 9 processes over 9 levels with a tracker present and 0 without.
# A fixture whose verdict depends on the developer's own configuration is not
# a gate, so the tracker is supplied here and every hook runs its full path on
# every machine.
HOME_SANDBOX="$SANDBOX/home"
mkdir -p "$HOME_SANDBOX/.claude"
printf '{"tracker":"none"}\n' > "$HOME_SANDBOX/.claude/TICKET-TRACKER.json"

# Pass-through wrappers that record one line per start and then exec the real
# tool, so the chain behaves exactly as it does in a session and only the
# count is observed. The real path is resolved here, at generation time, and
# written into the wrapper: a wrapper that looked the tool up itself would
# find the wrapper. A tool this environment does not carry is simply not
# shimmed, which can only undercount and never invent a failure.
for tool in dirname basename jq git grep sed awk cut tr wc head tail cat expr realpath readlink stat find python3; do
  real_tool=$(command -v "$tool" 2>/dev/null) || continue
  cat > "$SHIM_DIR/$tool" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "$tool" >> "\$SPAWN_LOG"
exec "$real_tool" "\$@"
SHIM
  chmod +x "$SHIM_DIR/$tool"
done

# Runs the whole chain once for one file path and prints how many shimmed
# processes it started. Hook exit codes are ignored: a deny is a legitimate
# verdict and this fixture is counting work, not judging it.
count_chain_spawns() {
  local file_path="$1" payload hook
  payload=$(jq -n --arg f "$file_path" '{tool_name:"Write",tool_input:{file_path:$f,content:"export function formatDate() {}"}}')
  : > "$SANDBOX/spawns.log"
  for hook in $WRITE_HOOKS; do
    [ -f "$HOOKS_DIR/$hook" ] || continue
    printf '%s' "$payload" \
      | SPAWN_LOG="$SANDBOX/spawns.log" HOME="$HOME_SANDBOX" PATH="$SHIM_DIR:$PATH" \
        bash "$HOOKS_DIR/$hook" >/dev/null 2>&1 || true
  done
  # `wc -l`, not `grep -c ''`. On an empty log `grep -c ''` prints 0 AND exits
  # 1, so a `|| echo 0` fallback fires as well and the substitution captures
  # "0\n0", which kills the subtraction below with an arithmetic syntax error
  # and makes the zero-spawn guard unreachable. `wc -l` prints 0 and exits 0.
  wc -l < "$SANDBOX/spawns.log" | tr -d '[:space:]'
}

SHALLOW_SPAWNS=$(count_chain_spawns "$SHALLOW_PATH")
DEEP_SPAWNS=$(count_chain_spawns "$DEEP_PATH")
GROWTH=$(( DEEP_SPAWNS - SHALLOW_SPAWNS ))

# A chain that started nothing means the shims never took effect, which would
# make the comparison below pass for the wrong reason.
if [ "$SHALLOW_SPAWNS" -eq 0 ]; then
  echo "FAIL: the Write|Edit chain started no shimmed process at all, so this fixture is not measuring it." >&2
  exit 1
fi

if [ "$GROWTH" -gt "$DEPTH_BUDGET" ]; then
  echo "FAIL: the Write|Edit chain starts $GROWTH more process(es) for a path $EXTRA_LEVELS levels deeper (budget $DEPTH_BUDGET): $SHALLOW_SPAWNS for '$SHALLOW_PATH' against $DEEP_SPAWNS for '$DEEP_PATH'. A per-edit hook is walking the path one component at a time and spawning a process for each. Strip components with bash parameter expansion ('\${path%/*}' for the parent, '\${path##*/}' for the base) instead of calling dirname or basename in a loop." >&2
  exit 1
fi

echo "  Write|Edit chain: $SHALLOW_SPAWNS spawns at depth 2, $DEEP_SPAWNS at depth $(( EXTRA_LEVELS + 2 )) (growth $GROWTH, budget $DEPTH_BUDGET)"
echo "hook-path-walk-budget.test.sh PASS"
