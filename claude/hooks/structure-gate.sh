#!/usr/bin/env bash
# structure-gate.sh: deterministic path checks for directory case (R-312),
# banned catch-all directory names (R-306/R-304), and test-file placement
# (R-313 no co-location; R-314 one top-level __tests__ tree per package src/).
# Per-edit, no Node spawn.
set -euo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in Write|Edit) ;; *) exit 0 ;; esac
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

BANNED='^(lib|utils|helpers|common|core|misc|shared)$'
ABBREV='^(db|di|svc|ctrl|mw|cfg)$'
IFS='/' read -ra PARTS <<< "$FILE"
in_src=0
in_app=0
# Track the path walked so far so a banned segment can be tested for prior
# existence. R-306 forbids *creating* catch-all directories; an established one
# in a third-party codebase is a fact to work within, not a violation to author.
prefix=""
[ "${FILE:0:1}" = "/" ] && prefix="/"
for seg in "${PARTS[@]}"; do
  [ -n "$seg" ] && prefix="${prefix%/}/$seg"
  [ "$seg" = "src" ] && in_src=1 && continue
  [ "$in_src" -eq 0 ] && continue
  [[ "$seg" == *.* ]] && continue
  [[ "$seg" =~ ^__.*__$ ]] && continue
  [[ "$seg" =~ ^\(.*\)$ ]] && continue
  [ "$seg" = "app" ] && in_app=1 && continue
  if [[ "$seg" =~ $BANNED ]]; then
    # Pre-existing directory: writing into it creates nothing. Allow.
    [ -d "$prefix" ] && continue
    deny "Directory '$seg' is a banned catch-all (R-306/R-304) and does not exist yet, so this Write would create it. Use services/, clients/, or a domain folder."
  fi
  if [[ "$seg" =~ $ABBREV ]]; then
    deny "Directory '$seg' is an abbreviation (R-311). Use the full word: database/, dependencyInjection/, services/, controllers or handlers/, middleware/, config/."
  fi
  if [[ "$seg" == *-* || "$seg" == *_* ]]; then
    [ "$in_app" -eq 1 ] && continue
    deny "Directory '$seg' must be camelCase, not kebab/snake (R-312)."
  fi
done

# R-313/R-314: test files live in a conventional test tree, never beside their
# source. TypeScript keeps one top-level __tests__ per package src/ (R-314), so
# a per-directory __tests__ nested below src/ is denied too.
#
# Exemption: third-party repos whose established convention is co-located tests.
# Listed one absolute repo root per line in the allowlist below. R-313 still
# fires everywhere else, including all greenfield work. Adopting a foreign
# codebase's layout is not the same as choosing it.
COLOCATED_ALLOWLIST="$HOME/.claude/enforce/colocated-test-repos.txt"
skip_colocation_check=0
if [ -f "$COLOCATED_ALLOWLIST" ]; then
  while IFS= read -r allowed_root || [ -n "$allowed_root" ]; do
    [ -z "$allowed_root" ] && continue
    case "$allowed_root" in \#*) continue ;; esac
    case "$FILE" in "${allowed_root%/}"/*) skip_colocation_check=1; break ;; esac
  done < "$COLOCATED_ALLOWLIST"
fi

BASE=$(basename "$FILE")
if [ "$skip_colocation_check" -eq 0 ] && { [[ "$BASE" =~ \.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$ ]] || [[ "$BASE" =~ ^test_.*\.py$ ]] || [[ "$BASE" =~ _test\.py$ ]]; }; then
  case "$FILE" in
    */__tests__/* | */tests/* | */e2e/*)
      if [[ "$FILE" == */src/*/__tests__/* ]]; then
        deny "Test file sits in a per-directory __tests__ nested below src/ (R-314). Keep one top-level tree: src/__tests__/<mirrored source path>."
      fi ;;
    *)
      deny "Test file co-located beside source (R-313). Move it to the package's src/__tests__/ tree (TypeScript) or tests/ (Python)." ;;
  esac
fi
exit 0
