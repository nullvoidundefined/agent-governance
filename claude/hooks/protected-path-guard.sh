#!/usr/bin/env bash
# protected-path-guard.sh: PreToolUse guard (Write, Edit, Bash) for the TDD
# slice loop. Three rules, one hook, jq only, no Node:
#   R-410  the gate inputs (.claude/verify.sh, .enforce.json,
#          .enforce-baseline.json, the slice lock itself) are never written by
#          a session, and once a slice is RED every test tree, every locked
#          fixture dir, and the locked spec are read-only until the slice
#          closes; a test the implementer believes wrong is returned as
#          `DISPUTE: <test>` for the human, never edited
#   R-411  role boundaries by agent_type (enforce/role-policy.json): a
#          test-author writes only test and fixture trees, an implementer
#          never writes tests, fixtures, or specs, a slice-critic writes nothing
#   R-412  slice order: while .claude/tdd-lock.json says phase "open", only
#          test, fixture, and spec paths may be written; `tdd.sh red` moves
#          the slice to "red" and production writes open up
# Test-runner configs and the package.json test/typecheck scripts ask rather
# than deny: a legitimate edit is rare but real (2026-09-06 decision 8).
# Bash is covered by its write targets: redirections, tee, and the paths named
# alongside a mutating verb (rm, mv, cp, sed -i, git rm/mv/checkout/restore).
# An interpreter that writes a file from inside its own source is not seen
# here; `tdd.sh green` compares hashes against the RED commit for that case.
# Paths outside the repository root are not governed. Silent on allow.
set -uo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in Write | Edit | Bash) ;; *) exit 0 ;; esac
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD="$PWD"
AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""')
POLICY="${CLAUDE_ROLE_POLICY_FILE:-$HOME/.claude/enforce/role-policy.json}"

emit() {
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$2" | grep -oE 'R-[0-9]{3}' | head -1)" "protected-path-guard" "$1"
  jq -n --arg d "$1" --arg r "$2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

# Physical path of a file that may not exist yet: resolve the deepest existing
# ancestor with pwd -P and append the remainder, so a symlinked checkout and
# its real path compare equal.
physical_path() {
  local target="$1" rest=""
  case "$target" in /*) ;; *) target="$CWD/$target" ;; esac
  while [ ! -d "$target" ]; do
    rest="/$(basename "$target")$rest"
    target=$(dirname "$target")
    [ "$target" = "/" ] && break
  done
  printf '%s%s' "$(cd "$target" 2>/dev/null && pwd -P)" "$rest"
}

repo_root_for() {
  local dir="$1"
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir=$(dirname "$dir"); done
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true
}

pattern() { jq -r --arg n "$1" '.patterns[$n] // ""' "$POLICY" 2>/dev/null; }
matches() { [ -n "$2" ] && printf '%s' "$1" | grep -qE "$2"; }

TESTS_PATTERN=$(pattern tests)
SPECS_PATTERN=$(pattern specs)
ALWAYS_PROTECTED='^(\.claude/verify\.sh|\.claude/tdd-lock\.json|\.enforce\.json|\.enforce-baseline\.json)$'
RUNNER_CONFIG='(^|/)(vitest|jest|playwright)\.(config|workspace)\.[cm]?[jt]s$|(^|/)pytest\.ini$|(^|/)\.rspec$'

# Root and lock state are resolved once per call, from the file for Write/Edit
# and from cwd for Bash.
if [ "$TOOL" = "Bash" ]; then
  ROOT=$(repo_root_for "$CWD")
else
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
  [ -n "$FILE" ] || exit 0
  ROOT=$(repo_root_for "$(dirname "$(physical_path "$FILE")")")
fi
[ -n "$ROOT" ] || exit 0
ROOT_PHYSICAL=$(cd "$ROOT" && pwd -P)

LOCK="$ROOT/.claude/tdd-lock.json"
LOCK_STATE="none"
PHASE=""
LOCKED=""
if [ -f "$LOCK" ]; then
  if jq -e . "$LOCK" >/dev/null 2>&1; then
    LOCK_STATE="ok"
    PHASE=$(jq -r '.phase // "red"' "$LOCK")
    LOCKED=$(jq -r '[(.tests[]?.path // empty), (.locked[]? // empty)] | .[]' "$LOCK")
  else
    LOCK_STATE="unreadable"
  fi
fi

ROLE_MODE=""
ROLE_PATTERN=""
if [ -n "$AGENT" ] && [ -f "$POLICY" ]; then
  ROLE_MODE=$(jq -r --arg a "$AGENT" '.roles[$a] | if . == null then "" elif .allow then "allow" else "deny" end' "$POLICY" 2>/dev/null)
  if [ -n "$ROLE_MODE" ]; then
    ROLE_PATTERN=$(jq -r --arg a "$AGENT" --arg m "$ROLE_MODE" '.roles[$a][$m][] as $n | .patterns[$n]' "$POLICY" 2>/dev/null | paste -sd'|' -)
  fi
fi

# Root-relative form of a path, or empty when it lies outside the repository.
relative_path() {
  local physical
  physical=$(physical_path "$1")
  case "$physical" in
    "$ROOT_PHYSICAL"/*) printf '%s' "${physical#"$ROOT_PHYSICAL"/}" ;;
    *) printf '' ;;
  esac
}

is_locked() {
  local rel="$1" entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry="${entry#./}"
    case "$entry" in
      */) case "$rel" in "$entry"*) return 0 ;; esac ;;
      *) [ "$rel" = "$entry" ] && return 0 ;;
    esac
  done <<< "$LOCKED"
  return 1
}

# Decide one root-relative write target. Prints "<decision>|<reason>" for a
# verdict, nothing for allow. Deny tiers first, ask tiers last.
verdict_for() {
  local rel="$1"
  if matches "$rel" "$ALWAYS_PROTECTED"; then
    printf 'deny|%s' "This write targets '$rel', a gate input the session never edits (R-410): .claude/verify.sh decides what the verification gate runs, .enforce.json and .enforce-baseline.json decide what the linters and the ratchet enforce, and .claude/tdd-lock.json is the slice lock. Change it outside the session, or tell the user what must change and why."
    return
  fi
  if [ "$LOCK_STATE" = "unreadable" ]; then
    printf 'deny|%s' "The slice lock at .claude/tdd-lock.json is unreadable (not JSON), so the guard cannot tell what is protected and fails closed (R-410). Ask the user to repair or delete the lock outside the session; enforce/tdd.sh writes it and never leaves it in this state."
    return
  fi
  if [ -n "$ROLE_MODE" ]; then
    if [ "$ROLE_MODE" = "allow" ] && ! matches "$rel" "$ROLE_PATTERN"; then
      printf 'deny|%s' "The '$AGENT' role writes only test and fixture trees, and '$rel' is not one (R-411). The behavior belongs in a test; the implementation is another agent's job. If the test needs an interface that does not exist, describe it in the test and report it in your summary."
      return
    fi
    if [ "$ROLE_MODE" = "deny" ] && matches "$rel" "$ROLE_PATTERN"; then
      printf 'deny|%s' "The '$AGENT' role may not write '$rel' (R-411): tests, fixtures, specs, and the slice lock are the contract, owned by the test author and the user. If a test is wrong, return 'DISPUTE: <test id>: <why>' and stop; the user decides."
      return
    fi
  fi
  if [ "$LOCK_STATE" = "ok" ]; then
    case "$PHASE" in
      open)
        if ! matches "$rel" "$TESTS_PATTERN" && ! matches "$rel" "$SPECS_PATTERN"; then
          printf 'deny|%s' "Slice '$(jq -r '.slice // "?"' "$LOCK")' is open and not yet red, so production paths are read-only (R-412). Write the failing test for this behavior first, run 'bash ~/.claude/enforce/tdd.sh red <test file>' to prove it fails for the right reason, and then '$rel' opens up."
          return
        fi ;;
      red | green)
        if is_locked "$rel" || matches "$rel" "$TESTS_PATTERN"; then
          printf 'deny|%s' "'$rel' is locked for slice '$(jq -r '.slice // "?"' "$LOCK")' (R-410): once the slice is red, tests, fixtures, and the spec are the contract and stay read-only through GREEN and REFACTOR. Make the implementation satisfy the test. If the test is wrong, return 'DISPUTE: <test id>: <why>' and stop; the user decides, and any change is a new RED. A new behavior is a new slice: 'tdd.sh close' then 'tdd.sh open'."
          return
        fi ;;
    esac
  fi
  if matches "$rel" "$RUNNER_CONFIG"; then
    printf 'ask|%s' "This changes the test-runner configuration ('$rel'), which decides what the verification gate and tdd.sh consider a passing run (R-410). Confirm the change is deliberate and not a way to make a failing run pass."
    return
  fi
}

# package.json: only the test and typecheck scripts are gate inputs. A Write
# compares the scripts against the file on disk; an Edit looks at the strings.
package_scripts_change() {
  local rel="$1" current next
  [ "$rel" = "package.json" ] || return 1
  if [ "$TOOL" = "Write" ]; then
    [ -f "$ROOT/package.json" ] || return 1
    current=$(jq -c '[.scripts.test, .scripts.typecheck, .scripts["type-check"]]' "$ROOT/package.json" 2>/dev/null)
    next=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' | jq -c '[.scripts.test, .scripts.typecheck, .scripts["type-check"]]' 2>/dev/null)
    [ -n "$next" ] && [ "$current" != "$next" ]
  else
    printf '%s' "$INPUT" | jq -r '(.tool_input.old_string // "") + "\n" + (.tool_input.new_string // "")' | grep -qE '"(test|typecheck|type-check)"[[:space:]]*:'
  fi
}

apply_verdict() {
  local rel="$1" verdict
  [ -n "$rel" ] || return 0
  verdict=$(verdict_for "$rel")
  [ -n "$verdict" ] && emit "${verdict%%|*}" "${verdict#*|}"
  if package_scripts_change "$rel"; then
    emit ask "This changes the package.json test or typecheck script, which is what the verification gate and tdd.sh run (R-410). Confirm the change is deliberate and not a way to make a failing run pass."
  fi
}

if [ "$TOOL" != "Bash" ]; then
  apply_verdict "$(relative_path "$FILE")"
  exit 0
fi

# Bash: collect write targets, then judge each one.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
[ -n "$CMD" ] || exit 0
NORM=$(printf '%s' "$CMD" | tr '\n' ';')
TARGETS=""
add_target() { TARGETS="$TARGETS"$'\n'"$1"; }

# Redirections and tee always write their operand.
while IFS= read -r target; do
  [ -n "$target" ] && add_target "$target"
done < <(printf '%s' "$NORM" | grep -oE '>>?[[:space:]]*[^[:space:];&|<>]+' | sed -E 's/^>>?[[:space:]]*//' || true)
while IFS= read -r target; do
  [ -n "$target" ] && add_target "$target"
done < <(printf '%s' "$NORM" | grep -oE '(^|[;&|(][[:space:]]*|[[:space:]])tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^[:space:];&|]+' | awk '{print $NF}' || true)

# A mutating verb makes every path-like operand of the command a write target.
MUTATE='(^|[;&|(][[:space:]]*|[[:space:]])(sudo[[:space:]]+)?(rm|mv|cp|shred|truncate|unlink|sed[[:space:]]+-[a-zA-Z]*i|git[[:space:]]+(rm|mv|checkout|restore|clean|stash))([[:space:]]|$)'
if printf '%s' "$NORM" | grep -qE "$MUTATE"; then
  while IFS= read -r token; do
    [ -n "$token" ] && add_target "$token"
  done < <(printf '%s' "$NORM" | tr ';&|()' '     ' | tr -s ' ' '\n' | sed -E "s/^['\"]|['\"]$//g" | grep -E '^[^-]' | grep -E '/|\.' || true)
fi

while IFS= read -r target; do
  [ -n "$target" ] || continue
  target="${target#\'}"; target="${target%\'}"; target="${target#\"}"; target="${target%\"}"
  case "$target" in /dev/*) continue ;; esac
  apply_verdict "$(relative_path "$target")"
done <<< "$TARGETS"
exit 0
