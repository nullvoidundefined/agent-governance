#!/usr/bin/env bash
# settings-permission-rules.sh: evaluates the `Bash(...)` and `Read(...)`
# entries of a Claude Code settings.json from plain shell, so the Codex and
# Cursor hook adapters can mirror the permission layer of a harness their host
# tool does not read. Sourced, never executed: it defines two functions and
# does nothing else.
#
#   matching_bash_rule <deny|ask|allow> <command>
#       prints the pattern of the first rule in that tier that matches the
#       command, exit 0; exit 1 when no rule matches; exit 2 when the settings
#       file is missing, unreadable, or not JSON, which is a different answer
#       from "nothing matched" and callers must treat it as such.
#
#   read_is_denied <path>
#       exit 0 when a `permissions.deny` `Read(<glob>)` rule covers the path,
#       exit 1 when none does, exit 2 on the same undecidable settings file.
#
# The settings file is `$CLAUDE_SETTINGS_FILE`, falling back to
# `$CLAUDE_HOME/settings.json` and then `~/.claude/settings.json`. It is read on
# every call rather than cached, because a hook process is short-lived and a
# stale cache would be a permission layer running on yesterday's rules.
#
# WHAT IS MATCHED. Claude Code's own rule syntax is a glob over the command
# string, and that is what is implemented here, with bash's `case` doing the
# globbing: `*` matches any run of characters anywhere in the pattern, so both
# the common trailing form (`Bash(git push *)`) and the embedded form
# (`Bash(git config --unset*core.hooksPath*)`) work, and a pattern with no
# wildcard (`Bash(rm -rf /)`) matches that command and nothing else. A `~` in a
# rule is matched both literally and with `$HOME` substituted, since a command
# may carry either spelling. The command is tested whole and then split on
# `&&`, `||`, `|`, `;` and newlines, so a denied command does not escape by
# riding behind a harmless one.
#
# Read rules are converted to an anchored extended regex over the absolute
# path: a leading `//` means "absolute path", a leading `~/` is expanded to
# `$HOME`, `**/` matches any number of leading directories, `**` matches across
# separators, `*` and `?` match within one segment, and every other regex
# metacharacter is escaped. A relative rule is resolved against `$PWD`.
#
# WHAT IS NOT MATCHED, and is therefore weaker than Claude Code itself:
#   - shell quoting and escaping are not interpreted, so `rm -rf $(echo /)` and
#     `r''m -rf /` are not recognised as the commands they resolve to
#   - `$HOME` written as `$HOME` or `${HOME}` in a command is not expanded, so
#     only the `~` and literal spellings of a home path are matched
#   - `..` segments in a read path are not collapsed, so a path that walks up
#     out of a denied directory and back into it is not recognised
#   - the `allow` tier is readable here but means nothing on its own: these
#     adapters mirror the deny and ask tiers, and an unmatched command is left
#     to the host tool's own approval policy
# Each of those is a bypass for an adversary and a non-event for an agent doing
# ordinary work, which is the trade the rest of this harness makes too: the
# guards raise the cost of an accident, they do not contain a hostile process.
set -uo pipefail

# The settings.json this helper reads, resolved per call so a test (or a second
# harness on the same machine) can point it somewhere else.
settings_permission_file() {
  if [ -n "${CLAUDE_SETTINGS_FILE:-}" ]; then
    printf '%s' "$CLAUDE_SETTINGS_FILE"
    return 0
  fi
  printf '%s/settings.json' "${CLAUDE_HOME:-${HOME:-}/.claude}"
}

# Prints the rule patterns of one tier and one rule kind, one per line:
# `settings_permission_patterns deny Bash` prints the text inside every
# `Bash(...)` entry of permissions.deny. Exit 2 means the file could not be
# read, which is not the same as a tier with no rules in it.
settings_permission_patterns() {
  local tier="$1" kind="$2" settings
  settings=$(settings_permission_file)
  [ -n "$settings" ] && [ -r "$settings" ] || return 2
  jq -e . "$settings" >/dev/null 2>&1 || return 2
  jq -r --arg tier "$tier" --arg prefix "$kind(" '
    .permissions[$tier] // []
    | .[]
    | select(type == "string")
    | select(startswith($prefix) and endswith(")"))
    | .[($prefix | length):-1]
  ' "$settings" 2>/dev/null || return 2
}

# The command whole, then each piece of it that the shell would run on its own,
# trimmed and with the empties dropped. Splitting matters: `true && rm -rf /`
# is a denied command wearing a prefix.
command_permission_segments() {
  printf '%s\n' "$1" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); if (length($0)) print }'
  printf '%s' "$1" \
    | awk '{ gsub(/&&|\|\||\||;/, "\n"); print }' \
    | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); if (length($0)) print }'
}

# One rule pattern against one command segment, with `case` supplying the glob
# semantics. A `~` in the pattern is tried twice, literal and expanded, because
# the rule is written the way a human types a path and the command may not be.
bash_rule_matches() {
  local pattern="$1" segment="$2" expanded
  # shellcheck disable=SC2254
  case "$segment" in $pattern) return 0 ;; esac
  case "$pattern" in
    *'~'*)
      expanded="${pattern//\~/${HOME:-}}"
      # shellcheck disable=SC2254
      case "$segment" in $expanded) return 0 ;; esac
      ;;
  esac
  return 1
}

# The first rule of <tier> matching <command>, printed for the caller to quote
# back to the user. Exit 1 is "no rule matched"; exit 2 is "the rules could not
# be read", and a caller that treats the second as the first has turned a
# broken permission layer into a silent allow.
matching_bash_rule() {
  local tier="${1:-}" command="${2:-}" patterns pattern segment
  case "$tier" in deny | ask | allow) ;; *) return 2 ;; esac
  [ -n "$command" ] || return 1
  patterns=$(settings_permission_patterns "$tier" Bash) || return 2
  [ -n "$patterns" ] || return 1
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    while IFS= read -r segment; do
      [ -n "$segment" ] || continue
      if bash_rule_matches "$pattern" "$segment"; then
        printf '%s\n' "$pattern"
        return 0
      fi
    done <<< "$(command_permission_segments "$command")"
  done <<< "$patterns"
  return 1
}

# `/./` and doubled separators removed, so a `$HOME` or `$PWD` that ends in a
# slash cannot make a pattern and a path disagree about a file they both name.
collapse_path_separators() {
  printf '%s' "$1" | sed -e 's|/\./|/|g' -e 's|//*|/|g'
}

# A `Read(...)` glob as an anchored extended regex. Kept separate from the
# matching so the conversion can be read (and argued with) on its own.
read_rule_regex() {
  local pattern="$1" out="" index=0 char
  # SC2088 reads the literal tilde below as a failed expansion; it is a literal
  # on purpose, because the rule text is matched before any shell sees it.
  # shellcheck disable=SC2088
  case "$pattern" in
    //*) pattern=$(collapse_path_separators "${pattern#/}") ;;
    '~/'*) pattern=$(collapse_path_separators "${HOME:-}/${pattern#\~/}") ;;
    /*) pattern=$(collapse_path_separators "$pattern") ;;
    *) pattern=$(collapse_path_separators "${PWD:-}/$pattern") ;;
  esac
  while [ "$index" -lt "${#pattern}" ]; do
    char="${pattern:index:1}"
    case "${pattern:index:3}" in
      '**/') out="$out(.*/)?"; index=$((index + 3)); continue ;;
    esac
    case "${pattern:index:2}" in
      '**') out="$out.*"; index=$((index + 2)); continue ;;
    esac
    case "$char" in
      '*') out="${out}[^/]*" ;;
      '?') out="${out}[^/]" ;;
      '.' | '\' | '^' | '$' | '+' | '(' | ')' | '{' | '}' | '[' | ']' | '|') out="$out\\$char" ;;
      *) out="$out$char" ;;
    esac
    index=$((index + 1))
  done
  printf '^%s$' "$out"
}

# An absolute form of a path that may not exist: `$PWD` for a relative path,
# `$HOME` for a leading `~`, with `/./` and doubled separators collapsed. No
# symlink resolution, because the rules are written against the paths a human
# types, not the paths a filesystem reports.
absolute_read_path() {
  local target="$1"
  # shellcheck disable=SC2088
  case "$target" in
    '~/'*) target="${HOME:-}/${target#\~/}" ;;
    '~') target="${HOME:-}" ;;
    /*) ;;
    *) target="${PWD:-}/$target" ;;
  esac
  collapse_path_separators "$target"
}

# Whether a `permissions.deny` `Read(...)` rule covers <path>. Exit 0 denied,
# exit 1 not denied, exit 2 the rules could not be read.
read_is_denied() {
  local target="${1:-}" patterns pattern absolute
  [ -n "$target" ] || return 1
  patterns=$(settings_permission_patterns deny Read) || return 2
  [ -n "$patterns" ] || return 1
  absolute=$(absolute_read_path "$target")
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if grep -qE "$(read_rule_regex "$pattern")" <<< "$absolute"; then
      return 0
    fi
  done <<< "$patterns"
  return 1
}
