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
#          A refactor slice (`tdd.sh open --refactor`) starts in phase
#          "refactor", which locks tests exactly like "red"
# Test-runner configs and the package.json test/typecheck scripts ask rather
# than deny: a legitimate edit is rare but real (2026-09-06 decision 8).
# Bash is covered by its write targets, never by the text it carries: quoted
# strings and heredoc bodies are set aside before the command is scanned, so a
# `-t "does not rm the cookie"` filter or a `=> {` inside a heredoc no longer
# names a target (2026-09-24, five stops in one build). The targets are
# redirections, tee, the operands of a mutating command (rm, mv, sed -i,
# perl -i, git rm/mv/checkout/restore/clean/stash, find -delete or -exec),
# the destination of cp, rsync, install, and ln, a nested shell's own targets
# (bash -c, eval, bash <<EOF), and the paths an inline interpreter script
# (python -c, node -e, python3 - <<EOF) hands to a write call on the same line
# or through a variable assigned from a literal. A script file run by name, or
# a write through a path built at run time, is not seen here; `tdd.sh green`
# compares hashes against the lock and the RED commit for that case.
# While a slice is amending (`tdd.sh amend`), only the one test file under
# amendment is writable.
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
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$2" | grep -oE 'R-[0-9]{3}' | head -1)" "protected-path-guard" "$1"
  jq -n --arg d "$1" --arg r "$2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

# Physical path of a file that may not exist yet: resolve the deepest existing
# ancestor with pwd -P and append the remainder, so a symlinked checkout and
# its real path compare equal.
#
# The two loops below strip one path component per turn with parameter
# expansion rather than with `basename` and `dirname`. They used to spawn one
# process per component each, so this hook charged a session two processes for
# every directory level of every path it wrote, on top of the four `jq` reads
# above: 23 processes for a four-level path, the most expensive hook in the
# Write|Edit chain at 63ms and the reason hook-latency.test.sh sat on its
# budget line (IAN-183; IAN-115 measured the same 63ms and left it as the
# residual). Bash removes a component with no process at all.
# enforce/tests/hook-path-walk-budget.test.sh pins the property by counting
# what the chain starts at two path depths.
#
# Trailing slashes are stripped once, up front, because `${target##*/}` on
# "a/b/" yields the empty string where `basename` yields "b". Below that line
# the loop removes one component per turn and never reintroduces one.
physical_path() {
  local target="$1" rest="" parent
  case "$target" in /*) ;; *) target="$CWD/$target" ;; esac
  while [ "$target" != "/" ] && [ "${target%/}" != "$target" ]; do target="${target%/}"; done
  while [ ! -d "$target" ]; do
    rest="/${target##*/}$rest"
    parent="${target%/*}"
    [ "$parent" = "$target" ] && parent="."
    [ -n "$parent" ] || parent="/"
    target="$parent"
    [ "$target" = "/" ] && break
  done
  printf '%s%s' "$(cd "$target" 2>/dev/null && pwd -P)" "$rest"
}

repo_root_for() {
  local dir="$1" parent
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do
    parent="${dir%/*}"
    # A name with no slash left expands to itself, which `dirname` reports as
    # "." and which would otherwise spin this loop forever. Callers pass an
    # absolute path today, so this is a guard rather than a live case, but the
    # `dirname` it replaces terminated on such input and so must this.
    [ "$parent" = "$dir" ] && parent="."
    [ -n "$parent" ] || parent="/"
    dir="$parent"
  done
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true
}

pattern() { jq -r --arg n "$1" '.patterns[$n] // ""' "$POLICY" 2>/dev/null; }
matches() { [ -n "$2" ] && grep -qE "$2" <<< "$1"; }

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
  # physical_path already returns an absolute path with no trailing slash, so
  # its parent is one expansion rather than a `dirname` process.
  FILE_PHYSICAL=$(physical_path "$FILE")
  FILE_PHYSICAL_PARENT="${FILE_PHYSICAL%/*}"
  [ -n "$FILE_PHYSICAL_PARENT" ] || FILE_PHYSICAL_PARENT="/"
  ROOT=$(repo_root_for "$FILE_PHYSICAL_PARENT")
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
      red | green | refactor)
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
    # Process substitution, not a pipe: under pipefail, grep -q exiting at an
    # early match kills jq with SIGPIPE on output over 64KB (IAN-120).
    grep -qE '"(test|typecheck|type-check)"[[:space:]]*:' \
      < <(printf '%s' "$INPUT" | jq -r '(.tool_input.old_string // "") + "\n" + (.tool_input.new_string // "")')
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
# Byte-wise string indexing keeps the quote scan linear on non-ASCII input.
LC_ALL=C
TARGETS=""
add_target() { TARGETS="$TARGETS"$'\n'"$1"; }

# Set-aside text, referenced from the scanned command by placeholder: a quoted
# string with anything beyond plain path characters becomes __Q<n>__ and a
# heredoc body becomes __H<n>__, so neither is read as shell syntax.
QUOTES=()
HEREDOCS=()
PLAIN_WORD='^[A-Za-z0-9_./@:+,=~%-]+$'
HEREDOC_MARKER='(^|[^<])<<(-?)[[:space:]]*(["'"'"']?)([A-Za-z_][A-Za-z0-9_]*)["'"'"']?'
INTERPRETERS='^(python[0-9.]*|node|nodejs|ruby|php|deno|bun|tsx|ts-node|perl|osascript)$'
LAUNCHERS='^(uv|npx|pnpx|pnpm|yarn|bunx|poetry|pipenv)$'
# A write call in an inline script: Python open() with a write mode,
# pathlib's write_text and write_bytes, shutil and os moves and deletes,
# Node's fs writers, Ruby's File and FileUtils, Perl's output open.
SCRIPT_WRITE='open\(.*,[[:space:]]*(mode[[:space:]]*=[[:space:]]*)?["'"'"'][rbt]*[wax+]|\.write_(text|bytes)\(|shutil\.(copy|copyfile|copy2|move|rmtree)\(|os\.(remove|unlink|rename|replace|truncate)\(|\.unlink\(|\.rename\(|(^|[^A-Za-z0-9_])(writeFile|appendFile|createWriteStream|copyFile|rename|unlink|rm|truncate|cp)(Sync)?\(|File\.(write|delete|rename)|FileUtils\.|open\([^,]*,[[:space:]]*["'"'"']?\+?[>]'

# split_heredocs <text>: sets HEREDOC_SPLIT to the text with each heredoc body
# removed and its opening marker replaced by __H<n>__; the body lands in
# HEREDOCS[n]. A marker whose terminator never comes keeps the rest as body.
split_heredocs() {
  local text="$1" line pending=() strips=() indexes=() body="" out="" compare index
  while IFS= read -r line || [ -n "$line" ]; do
    if [ ${#pending[@]} -gt 0 ]; then
      compare="$line"
      [ "${strips[0]}" = "-" ] && compare="${compare#"${compare%%[!$'\t']*}"}"
      if [ "$compare" = "${pending[0]}" ]; then
        HEREDOCS[${indexes[0]}]="$body"; body=""
        pending=("${pending[@]:1}"); strips=("${strips[@]:1}"); indexes=("${indexes[@]:1}")
      else
        body+="$line"$'\n'
      fi
      continue
    fi
    while [[ "$line" =~ $HEREDOC_MARKER ]]; do
      index=${#HEREDOCS[@]}
      HEREDOCS+=("")
      pending+=("${BASH_REMATCH[4]}"); strips+=("${BASH_REMATCH[2]}"); indexes+=("$index")
      line="${line/"${BASH_REMATCH[0]}"/${BASH_REMATCH[1]} __H${index}__ }"
    done
    out+="$line"$'\n'
  done <<< "$text"
  [ ${#pending[@]} -gt 0 ] && HEREDOCS[${indexes[0]}]="$body"
  HEREDOC_SPLIT="$out"
}

# set_aside_quotes <text>: sets UNQUOTED to the text with every quoted string
# either unwrapped (plain path characters only, so `rm "a/b.ts"` still names
# its operand) or replaced by __Q<n>__, and with newlines outside quotes
# turned into `;`.
set_aside_quotes() {
  local text="$1" out="" rest content char i=0 length=${#1}
  while [ "$i" -lt "$length" ]; do
    char="${text:i:1}"
    case "$char" in
      \\) out+="${text:i:2}"; i=$((i + 2)) ;;
      $'\n') out+=";"; i=$((i + 1)) ;;
      "'")
        rest="${text:i+1}"; content="${rest%%\'*}"
        i=$((i + ${#content} + 2)); quoted_word "$content"; out+="$WORD" ;;
      '"')
        content=""; i=$((i + 1))
        while [ "$i" -lt "$length" ] && [ "${text:i:1}" != '"' ]; do
          if [ "${text:i:1}" = \\ ]; then content+="${text:i+1:1}"; i=$((i + 2))
          else content+="${text:i:1}"; i=$((i + 1)); fi
        done
        i=$((i + 1)); quoted_word "$content"; out+="$WORD"
        # A command substitution inside double quotes still runs.
        case "$content" in *'$('* | *'`'*) collect_shell_targets "$content" ;; esac ;;
      *) out+="$char"; i=$((i + 1)) ;;
    esac
  done
  UNQUOTED="$out"
}

# quoted_word <content>: sets WORD to the unwrapped content, or to a
# __Q<n>__ placeholder with the content stored in QUOTES[n].
quoted_word() {
  if [[ "$1" =~ $PLAIN_WORD ]]; then WORD="$1"; return; fi
  WORD=" __Q${#QUOTES[@]}__ "
  QUOTES+=("$1")
}

# resolve_word <word>: a __Q<n>__ placeholder's text, any other word as is.
resolve_word() {
  if [[ "$1" =~ ^__Q([0-9]+)__$ ]]; then printf '%s' "${QUOTES[${BASH_REMATCH[1]}]}"
  else printf '%s' "$1"; fi
}

# add_operands <word>...: every operand that is not an option and looks like
# a path (a slash or a dot) is a target.
add_operands() {
  local word
  for word in "$@"; do
    case "$word" in -*) continue ;; esac
    word=$(resolve_word "$word")
    case "$word" in */* | *.*) add_target "$word" ;; esac
  done
}

# add_destination <word>...: cp, rsync, install, and ln write only their
# destination, the -t directory or else the last operand.
add_destination() {
  local word last="" target_dir="" take_next=0
  for word in "$@"; do
    if [ "$take_next" -eq 1 ]; then target_dir="$word"; take_next=0; continue; fi
    case "$word" in
      -t | --target-directory) take_next=1 ;;
      --target-directory=*) target_dir="${word#*=}" ;;
      -*) ;;
      *) last="$word" ;;
    esac
  done
  [ -n "$target_dir" ] && last="$target_dir"
  [ -n "$last" ] && add_target "$(resolve_word "$last")"
}

# script_targets <script>: the path literals an inline interpreter script hands
# to a write call, on the write line itself or through a variable assigned
# from a literal elsewhere in the script. Literals only: a read of the locked
# test beside a write of another file is not a write of the test.
script_targets() {
  local script="$1" write_lines names line
  write_lines=$(grep -E "$SCRIPT_WRITE" <<< "$script") || return 0
  names=$(grep -oE '[A-Za-z_][A-Za-z0-9_]*' <<< "$write_lines" | sort -u)
  { printf '%s\n' "$write_lines"
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*((const|let|var|my)[[:space:]]+)?\$?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:?=[^=] ]] || continue
      grep -qxF "${BASH_REMATCH[3]}" <<< "$names" && printf '%s\n' "$line"
    done <<< "$script"
  } | grep -oE "[\"'][^\"'[:space:]]*[^\"'[:space:]./][^\"'[:space:]]*[\"']" | sed -E "s/^.(.*).$/\1/" | while IFS= read -r literal; do
    case "$literal" in *://*) continue ;; */* | *.*) printf '%s\n' "$literal" ;; esac
  done
}

# segment_targets <segment> <depth>: the targets of one simple command.
segment_targets() {
  local segment="$1" depth="$2" words=() index=0 word verb skip_options=0 launched=0
  read -ra words <<< "$segment"
  [ ${#words[@]} -gt 0 ] || return 0
  # Step past assignments, wrappers, and launchers to the command itself.
  while [ "$index" -lt ${#words[@]} ]; do
    word="${words[index]}"
    if [ "$skip_options" -eq 1 ]; then
      case "$word" in
        -I | -n | -P | -L | -s | -d | -E | -u | -g) index=$((index + 2)); continue ;;
        -*) index=$((index + 1)); continue ;;
      esac
      skip_options=0
    fi
    if [ "$launched" -eq 1 ]; then
      launched=0
      case "$word" in run | exec | x | dlx | --) index=$((index + 1)); continue ;; esac
    fi
    if [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then index=$((index + 1)); continue; fi
    case "$word" in
      sudo | env | xargs | nice | nohup | time | command | builtin | exec) skip_options=1; index=$((index + 1)); continue ;;
      then | do | else | elif | if | while | until | '!' | '{') index=$((index + 1)); continue ;;
    esac
    if [[ "$word" =~ $LAUNCHERS ]]; then launched=1; index=$((index + 1)); continue; fi
    break
  done
  [ "$index" -lt ${#words[@]} ] || return 0
  verb="${words[index]##*/}"
  local operands=("${words[@]:index+1}")
  case "$verb" in
    rm | rmdir | shred | truncate | unlink | mv) add_operands "${operands[@]+"${operands[@]}"}" ;;
    cp | rsync | install | ln) add_destination "${operands[@]+"${operands[@]}"}" ;;
    dd) for word in "${operands[@]+"${operands[@]}"}"; do case "$word" in of=*) add_target "${word#of=}" ;; esac; done ;;
    sed | gsed)
      for word in "${operands[@]+"${operands[@]}"}"; do
        [[ "$word" =~ ^--in-place|^-[a-zA-Z]*i ]] && { add_operands "${operands[@]}"; break; }
      done ;;
    git)
      while [ ${#operands[@]} -gt 0 ]; do
        case "${operands[0]}" in -C | -c) operands=("${operands[@]:2}") ;; -*) operands=("${operands[@]:1}") ;; *) break ;; esac
      done
      case "${operands[0]:-}" in rm | mv | checkout | restore | clean | stash) add_operands "${operands[@]:1}" ;; esac ;;
    find)
      case " $segment " in *" -delete "* | *" -exec "* | *" -execdir "* | *" -ok "*) add_operands "${operands[@]+"${operands[@]}"}" ;; esac ;;
    bash | sh | zsh | dash | ksh | eval)
      [ "$depth" -lt 3 ] || return 0
      local take_next=0
      [ "$verb" = eval ] && take_next=1
      for word in "${operands[@]+"${operands[@]}"}"; do
        if [ "$take_next" -eq 1 ]; then collect_shell_targets "$(resolve_word "$word")" $((depth + 1)); [ "$verb" = eval ] || take_next=0; continue; fi
        case "$word" in -c | -*c) take_next=1 ;; esac
        [[ "$word" =~ ^__H([0-9]+)__$ ]] && collect_shell_targets "${HEREDOCS[${BASH_REMATCH[1]}]}" $((depth + 1))
      done ;;
    *)
      if [[ "$verb" =~ $INTERPRETERS ]]; then
        # perl -i edits its operands in place; any other flag set runs a script.
        if [ "$verb" = perl ] && [[ " ${operands[*]:-} " =~ \ -[a-zA-Z]*i[a-zA-Z]*\  ]]; then add_operands "${operands[@]}"; return 0; fi
        for word in "${operands[@]+"${operands[@]}"}"; do
          if [[ "$word" =~ ^__Q[0-9]+__$ ]]; then
            while IFS= read -r target; do [ -n "$target" ] && add_target "$target"; done < <(script_targets "$(resolve_word "$word")")
          elif [[ "$word" =~ ^__H([0-9]+)__$ ]]; then
            while IFS= read -r target; do [ -n "$target" ] && add_target "$target"; done < <(script_targets "${HEREDOCS[${BASH_REMATCH[1]}]}")
          fi
        done
      fi ;;
  esac
}

# collect_shell_targets <command> [depth]: every write target of a command
# line, nested shells included up to three levels.
collect_shell_targets() {
  local text="$1" depth="${2:-0}" unquoted segment
  split_heredocs "$text"
  set_aside_quotes "$HEREDOC_SPLIT"
  unquoted="$UNQUOTED"
  # Redirections and tee always write their operand.
  while IFS= read -r target; do
    [ -n "$target" ] && add_target "$(resolve_word "$target")"
  done < <(printf '%s' "$unquoted" | grep -oE '(^|[^<-])>>?[[:space:]]*[^[:space:];&|<>()]+' | sed -E 's/^[^>]?>>?[[:space:]]*//' || true)
  while IFS= read -r target; do
    [ -n "$target" ] && add_target "$(resolve_word "$target")"
  done < <(printf '%s' "$unquoted" | grep -oE '(^|[;&|(][[:space:]]*|[[:space:]])tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^[:space:];&|]+' | awk '{print $NF}' || true)
  # Each simple command on its own: a verb reaches only its own operands.
  while IFS= read -r segment; do
    [ -n "$segment" ] && segment_targets "$segment" "$depth"
  done < <(printf '%s' "$unquoted" | sed -E 's/&&|\|\|/;/g' | tr ';|()&' '\n\n\n\n\n')
}

collect_shell_targets "$CMD"

while IFS= read -r target; do
  [ -n "$target" ] || continue
  case "$target" in /dev/* | __Q*__) continue ;; esac
  apply_verdict "$(relative_path "$target")"
done <<< "$TARGETS"
exit 0
