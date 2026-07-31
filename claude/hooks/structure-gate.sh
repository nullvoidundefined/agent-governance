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
# Python tree: importable package directories must be snake_case, so the R-312
# camelCase check does not apply; `db/` is the blessed engine/session home in
# the Python track (CLAUDE-PYTHON.md), so the R-311 abbreviation ban skips it.
# Ruby tree: snake_case dirs, `lib/` root blessed as the Ruby term of art
# (CLAUDE-RUBY.md). Go tree: dir-case checks waived (lowercase packages,
# kebab-case cmd/ binary names, CLAUDE-GO.md); `db` blessed for both.
is_python=0
is_ruby=0
is_go=0
[[ "$FILE" == *.py ]] && is_python=1
[[ "$FILE" == *.rb ]] && is_ruby=1
[[ "$FILE" == *.go ]] && is_go=1
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
  # Python packages root at app/ (CLAUDE-PYTHON.md layout), not src/: a
  # top-level app/ segment starts the scan for .py writes, else the whole
  # Python stack silently bypasses the gate (2026-07-31 audit P1).
  [ "$is_python" -eq 1 ] && [ "$seg" = "app" ] && [ "$in_src" -eq 0 ] && { in_src=1; continue; }
  # Ruby roots at app/ and lib/ (Rails layout); Go roots at internal/, cmd/,
  # pkg/ (standard layout). Same audit lesson: scan from the documented roots.
  if [ "$is_ruby" -eq 1 ] && [ "$in_src" -eq 0 ]; then
    case "$seg" in app|lib) in_src=1; continue ;; esac
  fi
  if [ "$is_go" -eq 1 ] && [ "$in_src" -eq 0 ]; then
    case "$seg" in internal|cmd|pkg) in_src=1; continue ;; esac
  fi
  [ "$in_src" -eq 0 ] && continue
  [[ "$seg" == *.* ]] && continue
  [[ "$seg" =~ ^__.*__$ ]] && continue
  [[ "$seg" =~ ^\(.*\)$ ]] && continue
  [ "$seg" = "app" ] && in_app=1 && continue
  if [[ "$seg" =~ $BANNED ]]; then
    # CLAUDE-PYTHON.md blesses core/ (config, logging, security primitives).
    [ "$is_python" -eq 1 ] && [ "$seg" = "core" ] && continue
    # Pre-existing directory: writing into it creates nothing. Allow.
    [ -d "$prefix" ] && continue
    deny "Directory '$seg' is a banned catch-all (R-306/R-304) and does not exist yet, so this Write would create it. Use services/, clients/, or a domain folder."
  fi
  if [[ "$seg" =~ $ABBREV ]]; then
    # CLAUDE-PYTHON.md blesses db/ as the engine/session home; Rails db/ and
    # Go db packages are the same term of art.
    { [ "$is_python" -eq 1 ] || [ "$is_ruby" -eq 1 ] || [ "$is_go" -eq 1 ]; } && [ "$seg" = "db" ] && continue
    deny "Directory '$seg' is an abbreviation (R-311). Use the full word: database/, dependencyInjection/, services/, controllers or handlers/, middleware/, config/."
  fi
  if [[ "$seg" == *-* || "$seg" == *_* ]]; then
    [ "$in_app" -eq 1 ] && continue
    # Python and Ruby package directories are importable/require-able names:
    # snake_case is the idiom (R-312 exception); kebab-case stays denied.
    { [ "$is_python" -eq 1 ] || [ "$is_ruby" -eq 1 ]; } && [[ "$seg" != *-* ]] && continue
    # Go waives dir-case entirely: lowercase packages, kebab cmd/ binary names.
    [ "$is_go" -eq 1 ] && continue
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

# Go is exempt by omission: *_test.go never matches below because co-located
# same-package tests are a toolchain requirement (R-313 Go exception).
BASE=$(basename "$FILE")
if [ "$skip_colocation_check" -eq 0 ] && { [[ "$BASE" =~ \.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$ ]] || [[ "$BASE" =~ ^test_.*\.py$ ]] || [[ "$BASE" =~ _test\.py$ ]] || [[ "$BASE" =~ _spec\.rb$ ]]; }; then
  case "$FILE" in
    */__tests__/* | */tests/* | */e2e/* | */spec/*)
      if [[ "$FILE" == */src/*/__tests__/* ]]; then
        deny "Test file sits in a per-directory __tests__ nested below src/ (R-314). Keep one top-level tree: src/__tests__/<mirrored source path>."
      fi ;;
    *)
      deny "Test file co-located beside source (R-313). Move it to the conventional test tree: src/__tests__/ (TypeScript), tests/ (Python), or spec/ (Ruby)." ;;
  esac
fi
exit 0
