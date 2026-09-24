#!/usr/bin/env bash
# require-stack-observability-docs.sh: the R-608 check. When the branch
# changes what the application is built from or what it can dispatch, the same
# branch must also change the document that catalogs it; otherwise exit 1 with
# a report naming each change and each missing document.
#
#   docs/stack.md          a dependency added to or removed from a
#                          package.json, pyproject.toml, Gemfile, or go.mod
#                          (compared by dependency name, so a version bump
#                          and a Go `// indirect` requirement never trigger)
#   docs/observability.md  an entry line added to or removed from an analytics
#                          event registry or an error-code registry, or a log
#                          event name that is new to the tree or gone from it
#
# Canonical copy: hooks/push-feature-docs-gate.sh runs THIS file at push time
# and never a repository's own copy (push gates do not execute
# target-repository code, 2026-07-31 security audit).
#
# Usage: require-stack-observability-docs.sh [base-ref], run with cwd inside
# the repository. Base: the argument, else FEATURE_CHECKLIST_BASE, else
# origin/main. Per-repository data in .enforce.json, read and never evaluated:
# {"stackDoc": false} and {"observabilityDoc": false} each turn one half off;
# {"observabilityDoc": {"extraRegistries": ["<ERE>", ...]}} adds registry
# path patterns. A major upgrade or a replacement that keeps the name is not
# visible in the diff and stays a manual duty of the rule.
set -uo pipefail
export LC_ALL=C

MANIFEST_PATTERN='(^|/)(package\.json|pyproject\.toml|Gemfile|go\.mod)$'
VENDORED_PATTERN='(^|/)(node_modules|vendor|\.venv)/'
BUILTIN_REGISTRIES=(
  '(^|/)analytics/events\.(ts|js|mjs|py|rb|go)$'
  '(^|/)error_codes\.(py|rb|go)$'
  '(^|/)(error-codes|errorCodes|error_codes)\.(ts|js|mjs)$'
  '(^|/)errors/codes\.(ts|js|mjs|py|rb|go)$'
)
SOURCE_PATTERN='\.(ts|tsx|js|jsx|mjs|cjs|vue|py|rb|go)$'
TEST_FILE_PATTERN='(\.(test|spec)\.[^/]+$)|(/__tests__/)|((^|/)test_[^/]+\.py$)|(_test\.(py|go)$)|(_spec\.rb$)|((^|/)(tests?|spec|e2e)/)'
# A logger call whose first string literal (after an optional context object
# or ctx argument) is the event name, or a Ruby `event:` payload key.
LOG_CALL_PATTERN="(logger|log|slog)\.(trace|debug|info|warning|warn|error|exception|critical|fatal|Debug|Info|Warn|Error)(Context)?\( *(ctx, *)?(\{[^}]*\}, *)?[\"'][^\"']+[\"']|event: *[\"'][^\"']+[\"']"

# is_half_disabled <key>: true when .enforce.json sets the key to false. A
# missing jq means the opt-out cannot be read, so the check runs.
is_half_disabled() {
  [ -f .enforce.json ] && command -v jq >/dev/null 2>&1 \
    && jq -e --arg k "$1" '.[$k] == false' .enforce.json >/dev/null 2>&1
}

# list_extra_registries: prints each valid observabilityDoc.extraRegistries
# pattern; an invalid one is reported on stderr and dropped.
list_extra_registries() {
  [ -f .enforce.json ] && command -v jq >/dev/null 2>&1 || return 0
  local pattern
  jq -r '.observabilityDoc.extraRegistries[]? // empty' .enforce.json 2>/dev/null | while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    printf '' | grep -E -- "$pattern" >/dev/null 2>&1
    if [ $? -eq 2 ]; then
      echo "require-stack-observability-docs: ignoring invalid extraRegistries pattern in .enforce.json: $pattern" >&2
    else
      printf '%s\n' "$pattern"
    fi
  done
}

# list_npm_dependencies: dependency names in a package.json on stdin.
list_npm_dependencies() {
  jq -r '[.dependencies, .devDependencies, .peerDependencies, .optionalDependencies]
    | map(select(type == "object") | keys[]) | .[]' 2>/dev/null
}

# list_python_dependencies: normalized dependency names in a pyproject.toml on
# stdin: [project] dependencies, [project.optional-dependencies],
# [dependency-groups], and Poetry's dependency tables (python excluded).
list_python_dependencies() {
  awk '
    function emit_requirements(text,   item) {
      gsub(/\{[^}]*\}/, "", text)
      while (match(text, /"[^"]+"|\047[^\047]+\047/)) {
        item = substr(text, RSTART + 1, RLENGTH - 2)
        text = substr(text, RSTART + RLENGTH)
        if (match(item, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) print normalize(substr(item, RSTART, RLENGTH))
      }
    }
    function normalize(name) { name = tolower(name); gsub(/[._]+/, "-", name); return name }
    /^[[:space:]]*\[/ && !in_array { section = $0; gsub(/[[:space:]]/, "", section); next }
    in_array { emit_requirements($0); if ($0 ~ /\]/) in_array = 0; next }
    section == "[project]" && /^[[:space:]]*dependencies[[:space:]]*=[[:space:]]*\[/ ||
    (section == "[project.optional-dependencies]" || section == "[dependency-groups]") && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*\[/ {
      line = $0; sub(/^[^[]*\[/, "", line); emit_requirements(line)
      if (line !~ /\]/) in_array = 1
      next
    }
    section ~ /^\[tool\.poetry\.(dependencies|dev-dependencies|group\.[^.]+\.dependencies)\]$/ && /^[[:space:]]*[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]*=/ {
      name = $0; sub(/^[[:space:]]*/, "", name); sub(/[[:space:]]*=.*/, "", name)
      if (tolower(name) != "python") print normalize(name)
    }
  '
}

# list_ruby_dependencies: gem names in a Gemfile on stdin.
list_ruby_dependencies() {
  sed -nE "s/^[[:space:]]*gem[[:space:]]+[\"']([^\"']+)[\"'].*/\1/p"
}

# list_go_dependencies: direct module requirements in a go.mod on stdin.
list_go_dependencies() {
  awk '
    /\/\/[[:space:]]*indirect/ { if ($0 ~ /^\)/) in_block = 0; next }
    /^require[[:space:]]*\(/ { in_block = 1; next }
    in_block && /^\)/ { in_block = 0; next }
    in_block && NF >= 2 { print $1; next }
    /^require[[:space:]]+[^([:space:]]/ { print $2 }
  '
}

# list_manifest_dependencies <path>: the sorted dependency names of the
# manifest content on stdin, by the manifest's file name.
list_manifest_dependencies() {
  case "$(basename "$1")" in
    package.json) list_npm_dependencies ;;
    pyproject.toml) list_python_dependencies ;;
    Gemfile) list_ruby_dependencies ;;
    go.mod) list_go_dependencies ;;
  esac | sort -u
}

# list_dependency_changes <changed-files>: one line per dependency added to or
# removed from a changed manifest, by comparing names at the base and HEAD.
list_dependency_changes() {
  local manifest before after
  grep -E "$MANIFEST_PATTERN" <<<"$1" | grep -vE "$VENDORED_PATTERN" | while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    before=$(git show "$MERGE_BASE:$manifest" 2>/dev/null | list_manifest_dependencies "$manifest")
    after=$(git show "HEAD:$manifest" 2>/dev/null | list_manifest_dependencies "$manifest")
    comm -13 <(printf '%s\n' "$before" | sed '/^$/d') <(printf '%s\n' "$after" | sed '/^$/d') | sed "s#^#    $manifest: added #"
    comm -23 <(printf '%s\n' "$before" | sed '/^$/d') <(printf '%s\n' "$after" | sed '/^$/d') | sed "s#^#    $manifest: removed #"
  done
}

# list_diff_lines <path> <+|->: the added or removed content lines of the
# branch's change to one file, marker stripped. Always succeeds: an empty side
# is not a failure, and under pipefail a grep that matched nothing would make
# every pipeline this feeds report false.
list_diff_lines() {
  git diff -U0 "$MERGE_BASE"..HEAD -- "$1" 2>/dev/null \
    | grep -E "^[$2]" | grep -vE '^(\+\+\+|---) ' | cut -c2-
  return 0
}

# has_registry_entry_line: true for stdin lines that declare an entry (a quoted
# name or an UPPER_CASE key), skipping blanks and comments. The final grep -q
# reads a here-string, never a pipe: under pipefail an early-exiting grep -q
# kills its upstream writer with SIGPIPE and the pipeline reports false (the
# same trap require-feature-checklist.sh documents, PR #44 review).
has_registry_entry_line() {
  local code_lines
  code_lines=$(grep -vE '^[[:space:]]*(#|//|/\*|\*|$)')
  grep -qE "[\"'][^\"']+[\"']|^[[:space:]]*[A-Z][A-Z0-9_]*[[:space:]]*[=:]" <<<"$code_lines"
}

# list_registry_changes <changed-files>: one line per registry whose entries
# the branch added or removed.
list_registry_changes() {
  local pattern_args=() pattern registry
  for pattern in "${BUILTIN_REGISTRIES[@]}"; do pattern_args+=(-e "$pattern"); done
  while IFS= read -r pattern; do pattern_args+=(-e "$pattern"); done < <(list_extra_registries)
  printf '%s\n' "$1" | grep -E "${pattern_args[@]}" | grep -vE "$TEST_FILE_PATTERN" | while IFS= read -r registry; do
    [ -n "$registry" ] || continue
    { list_diff_lines "$registry" +; list_diff_lines "$registry" -; } | has_registry_entry_line \
      && echo "    $registry: registry entries added or removed"
  done
}

# extract_log_event_names: the event names of the logger calls on stdin.
extract_log_event_names() {
  grep -oE "$LOG_CALL_PATTERN" | sed -E "s/.*[\"']([^\"']+)[\"']$/\1/" | sort -u
}

# is_log_event_in_tree <ref> <name>: true when the name appears as a quoted
# string anywhere in the tree at the ref.
is_log_event_in_tree() {
  git grep -qF -e "\"$2\"" -e "'$2'" "$1" -- 2>/dev/null
}

# list_log_event_changes <changed-files>: one line per log event name that the
# branch introduces to the tree or removes from it, test files excluded.
list_log_event_changes() {
  local sources added removed name
  sources=$(grep -E "$SOURCE_PATTERN" <<<"$1" | grep -vE "$TEST_FILE_PATTERN" | grep -vE "$VENDORED_PATTERN")
  [ -n "$sources" ] || return 0
  added=$(while IFS= read -r f; do list_diff_lines "$f" +; done <<<"$sources" | extract_log_event_names)
  removed=$(while IFS= read -r f; do list_diff_lines "$f" -; done <<<"$sources" | extract_log_event_names)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    is_log_event_in_tree "$MERGE_BASE" "$name" || echo "    log event \"$name\" added"
  done <<<"$added"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    is_log_event_in_tree HEAD "$name" || echo "    log event \"$name\" removed"
  done <<<"$removed"
}

# print_section <heading> <changes> <missing-line>: one half of the report.
print_section() {
  echo "  $1"
  printf '%s\n' "$2"
  echo "  missing:"
  echo "    $3"
  echo ""
}

BASE_REF="${1:-${FEATURE_CHECKLIST_BASE:-origin/main}}"
git rev-parse --verify --quiet "$BASE_REF" >/dev/null || exit 0
MERGE_BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null || true)
[ -n "$MERGE_BASE" ] || exit 0
[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "main" ] && exit 0
cd "$(git rev-parse --show-toplevel)" || exit 0

CHANGED=$(git diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null || true)
[ -n "$CHANGED" ] || exit 0

STACK_CHANGES=""
if ! is_half_disabled stackDoc && ! grep -qxF 'docs/stack.md' <<<"$CHANGED"; then
  STACK_CHANGES=$(list_dependency_changes "$CHANGED")
fi
OBSERVABILITY_CHANGES=""
if ! is_half_disabled observabilityDoc && ! grep -qxF 'docs/observability.md' <<<"$CHANGED"; then
  OBSERVABILITY_CHANGES=$(list_registry_changes "$CHANGED"; list_log_event_changes "$CHANGED")
fi
[ -n "$STACK_CHANGES$OBSERVABILITY_CHANGES" ] || exit 0

echo "R-608 stack and observability docs are incomplete for this branch."
echo ""
[ -z "$STACK_CHANGES" ] || print_section "dependency changes on this branch:" "$STACK_CHANGES" \
  "docs/stack.md not updated (the entry's version, explanation, docs link, role, why chosen, and where configured)"
[ -z "$OBSERVABILITY_CHANGES" ] || print_section "dispatch changes on this branch:" "$OBSERVABILITY_CHANGES" \
  "docs/observability.md not updated (the event, log event, or error code with its trigger, fields, and level or status)"
echo "Update the document in the same branch; a removal deletes its entry."
exit 1
