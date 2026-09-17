#!/usr/bin/env bash
# Verifies frontend convention scope using path strings without creating fixtures.
# Checks shared core coverage, framework isolation, and that core carries no React rule tokens.
# A2 covers React state hooks and providers while excluding every Nuxt fixture, including composables.
# A3 covers Next and Vite fixtures while excluding every Nuxt fixture from both tracks.
# A5 permits React framework names in dispatch and directory comparisons.
# Optional Vue and Nuxt tracks are checked together once both files exist.
# Prints one result per assertion and exits nonzero if any assertion fails.
set -uo pipefail

claude_directory="$(cd "$(dirname "$0")/../.." && pwd)"
failure=0
react_paths=(
  'apps/client/web/src/components/Header/Header.tsx'
  'apps/client/web/src/state/useAuth.ts'
  'apps/client/web/src/api/fetchTrips.ts'
)
next_paths=(
  'apps/client/web/src/app/(protected)/dashboard/page.tsx'
  'apps/client/web/next.config.ts'
)
vite_paths=(
  'apps/web/src/routes/index.tsx'
  'apps/web/vite.config.ts'
  'apps/web/src/main.tsx'
)
nuxt_paths=(
  'apps/client/web/app/components/Header/Header.vue'
  'apps/client/web/app/composables/useAuth.ts'
  'apps/client/web/app/pages/index.vue'
  'apps/client/web/server/api/health.get.ts'
  'apps/client/web/nuxt.config.ts'
)

# Checks a candidate against a convention file's frontmatter path globs.
# Arguments: convention basename, candidate path; optional third argument is --tsx-glob.
# Prints nothing; returns 0 for a match, 1 for no match, or 2 for invalid input.
# With --tsx-glob, checks for a glob ending in *.tsx instead of matching a path.
matches_path() {
  python3 - "$claude_directory/$1" "$2" "${3:-}" <<'PY'
import re
import sys
from pathlib import Path

# Extracts the quoted globs from the frontmatter paths list.
# Argument: filename is a convention file path; prints nothing.
# Returns a list of globs; raises ValueError or OSError for invalid input.
def read_globs(filename):
    lines = Path(filename).read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("Missing frontmatter")
    end = lines.index("---", 1)
    globs = []
    in_paths = False
    for line in lines[1:end]:
        if re.fullmatch(r"paths:\s*", line):
            in_paths = True
        elif line and not line[0].isspace() and not line.startswith("#"):
            in_paths = False
        elif in_paths:
            match = re.fullmatch(r'  - "([^"]+)"\s*', line)
            if match:
                globs.append(match.group(1))
    if not globs:
        raise ValueError("Missing path globs")
    return globs

# Converts minimatch-like glob tokens to a whole-path regular expression.
# Argument: glob is a path pattern; prints nothing.
# Returns a regex string whose metacharacters are literal except for glob stars.
def glob_regex(glob):
    tokens = re.findall(r"/\*\*$|\*\*/|\*\*|\*|.", glob)
    replacements = {
        "/**": r"(?:/.*)?",
        "**/": r"(?:.*/)?",
        "**": r".*",
        "*": r"[^/]*",
    }
    return "".join(replacements.get(token, re.escape(token)) for token in tokens)

try:
    globs = read_globs(sys.argv[1])
except (OSError, ValueError, UnicodeError):
    sys.exit(2)
if sys.argv[3] == "--tsx-glob":
    matched = any(glob.endswith("*.tsx") for glob in globs)
else:
    matched = any(re.fullmatch(glob_regex(glob), sys.argv[2]) for glob in globs)
sys.exit(0 if matched else 1)
PY
}

# Checks that every supplied path has the expected matching outcome.
# Arguments: expected status (0 or 1), convention basename, then candidate paths.
# Prints nothing; returns 0 if all outcomes agree, otherwise 1, including input errors.
check_paths() {
  local expected="$1" convention="$2" candidate result
  shift 2
  for candidate in "$@"; do
    matches_path "$convention" "$candidate"
    result=$?
    [ "$result" -eq "$expected" ] || return 1
  done
  return 0
}

# Prints a single assertion result and records failures for the final exit status.
# Arguments: assertion status (0 for success), assertion ID, descriptive reason.
# Prints one PASS or FAIL line; returns the printf status.
report_result() {
  if [ "$1" -eq 0 ]; then
    printf 'PASS: %s %s\n' "$2" "$3"
  else
    failure=1
    printf 'FAIL: %s %s\n' "$2" "$3"
  fi
}

check_paths 0 CLAUDE-FRONTEND.md "${react_paths[0]}" "${nuxt_paths[0]}" "${nuxt_paths[1]}"
report_result "$?" A1 'core covers React components, Vue components, and composables'

react_tsx_paths=()
for candidate in "${react_paths[@]}"; do
  case "$candidate" in *.tsx) react_tsx_paths+=("$candidate") ;; esac
done
check_paths 0 CLAUDE-FRONTEND-REACT.md "${react_tsx_paths[@]}" "${next_paths[0]}" &&
  check_paths 0 CLAUDE-FRONTEND-REACT.md "${react_paths[1]}" 'apps/client/web/src/state/AuthProvider.tsx' &&
  check_paths 1 CLAUDE-FRONTEND-REACT.md "${nuxt_paths[@]}"
report_result "$?" A2 'React covers React TSX and Next pages while excluding Nuxt paths'

# A2b: a legacy hook file living directly under src/hooks/ (not *.tsx, not
# under src/state/) must still reach the React file, or it loads only the
# framework-agnostic core and misses the hooks/state migration guidance.
check_paths 0 CLAUDE-FRONTEND-REACT.md 'apps/client/web/src/hooks/useAuth.ts'
report_result "$?" A2b 'React covers a legacy src/hooks/ file, not only *.tsx and src/state/'

check_paths 0 CLAUDE-FRONTEND-NEXT.md "${next_paths[@]}" &&
  check_paths 0 CLAUDE-FRONTEND-VITE.md "${vite_paths[@]}" &&
  check_paths 1 CLAUDE-FRONTEND-NEXT.md "${nuxt_paths[@]}" &&
  check_paths 1 CLAUDE-FRONTEND-VITE.md "${nuxt_paths[@]}"
report_result "$?" A3 'Next and Vite exclude every Nuxt path'

if [ ! -f "$claude_directory/CLAUDE-FRONTEND-VUE.md" ] ||
  [ ! -f "$claude_directory/CLAUDE-FRONTEND-NUXT.md" ]; then
  report_result 0 A4 'skipped: Vue or Nuxt convention file is absent'
else
  check_paths 0 CLAUDE-FRONTEND-VUE.md "${nuxt_paths[0]}" "${nuxt_paths[1]}" &&
    check_paths 1 CLAUDE-FRONTEND-VUE.md "${react_paths[@]}" &&
    check_paths 0 CLAUDE-FRONTEND-NUXT.md "${nuxt_paths[2]}" "${nuxt_paths[3]}" "${nuxt_paths[4]}" &&
    check_paths 1 CLAUDE-FRONTEND-NUXT.md "${react_paths[@]}"
  report_result "$?" A4 'Vue and Nuxt cover their fixtures while excluding React paths'
fi

react_rule_count=$(grep -cE "useCallback|useState|useRef|Zustand|use client|React\.FC|from 'react'|React 19" "$claude_directory/CLAUDE-FRONTEND.md")
grep_result=$?
[ "$grep_result" -eq 1 ] && [ "$react_rule_count" = 0 ]
report_result "$?" A5 'core carries no React rule tokens'

[ -f "$claude_directory/CLAUDE-FRONTEND-REACT.md" ] &&
  matches_path CLAUDE-FRONTEND-REACT.md '' --tsx-glob
report_result "$?" A6 'React convention exists with a frontmatter glob ending in *.tsx'

exit "$failure"
