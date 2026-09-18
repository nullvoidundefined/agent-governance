#!/usr/bin/env bash
# Shard: slow
# Verifies every convention track has path frontmatter, a resolving rules link,
# and a reference in the session table or frontend convention file.
# Fresh sandbox mutations prove missing wiring is rejected by filename.
set -uo pipefail

# Checks convention frontmatter, resolving rules/*.md symlinks, and loading references.
# Loading references must appear in the Stack detection section of rules/session-types.md
# or the Framework Files section of CLAUDE-FRONTEND.md, each ending before the next
# level-two heading.
# Argument: root ($1) is the convention tree directory to inspect.
# Prints an unwired diagnostic for each missing requirement, or nothing on success.
# Returns 0 when all requirements pass, or 1 when any requirement fails.
check_tree() {
  local root="$1" convention basename link target linked failed=0
  for convention in "$root"/CLAUDE-*.md; do
    [ -f "$convention" ] || continue
    basename="${convention##*/}"
    if ! awk '
      NR == 1 { if ($0 != "---") exit 1; next }
      $0 == "---" { closed = 1; exit }
      /^paths:[[:space:]]*$/ { paths = 1; next }
      paths && /^  - "[^"]+"$/ { glob = 1 }
      END { if (!closed || !glob) exit 1 }
    ' "$convention"; then
      printf 'unwired: %s missing path frontmatter\n' "$basename"
      failed=1
    fi

    linked=0
    target=$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$convention")
    for link in "$root"/rules/*.md; do
      [ -L "$link" ] && [ -e "$link" ] || continue
      if [ "$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$link")" = "$target" ]; then
        linked=1
        break
      fi
    done
    if [ "$linked" -eq 0 ]; then
      printf 'unwired: %s missing rules symlink\n' "$basename"
      failed=1
    fi

    if ! awk '
      /^## Stack detection$/ { in_section = 1; print; next }
      in_section && /^## / { exit }
      in_section { print }
    ' "$root/rules/session-types.md" | grep -Fq "$basename" && ! awk '
      /^## Framework Files$/ { in_section = 1; print; next }
      in_section && /^## / { exit }
      in_section { print }
    ' "$root/CLAUDE-FRONTEND.md" | grep -Fq "$basename"; then
      printf 'unwired: %s missing loading reference\n' "$basename"
      failed=1
    fi
  done
  return "$failed"
}

real_tree="$(cd "$(dirname "$0")/../.." && pwd)"
failure=0
temp_directories=()
# Removes every recorded sandbox directory when the script exits.
trap 'for directory in "${temp_directories[@]}"; do rm -rf "$directory"; done' EXIT

if output=$(check_tree "$real_tree"); then
  echo 'PASS: real tree wired'
else
  printf '%s\n' "$output" | sed 's/^unwired:/FAIL:/'
  failure=1
fi

# Creates a temporary copy of the convention files and rules and records it for cleanup.
# Takes no arguments; uses real_tree as the source and sets sandbox to the copy path.
# Prints nothing on success; setup commands may print errors to standard error.
# Returns 1 if temporary directory creation fails, otherwise the copy command status.
create_sandbox() {
  sandbox=$(mktemp -d) || return 1
  temp_directories+=("$sandbox")
  cp -R "$real_tree"/CLAUDE-*.md "$real_tree/rules" "$sandbox/"
}

if ! create_sandbox; then
  echo 'FAIL: sandbox setup failed'
  exit 1
fi
if output=$(check_tree "$sandbox"); then
  echo 'PASS: sandbox baseline wired'
else
  printf '%s\n' "$output" | sed 's/^unwired:/FAIL:/'
  failure=1
fi

# Checks that each missing wiring requirement is rejected in a fresh sandbox.
# C3 removes every mention of CLAUDE-RUBY.md from both detection files so the missing-mention check must name it.
for case_id in C1 C2 C3; do
  if ! create_sandbox; then
    echo 'FAIL: sandbox setup failed'
    exit 1
  fi
  case "$case_id" in
    C1)
      mutated_basename=CLAUDE-PYTHON.md
      rm "$sandbox/rules/python.md" || exit 1
      ;;
    C2)
      mutated_basename=CLAUDE-GO.md
      awk 'NR == 1 { next } !closed { if ($0 == "---") closed = 1; next } { print }' \
        "$sandbox/$mutated_basename" > "$sandbox/stripped.md" || exit 1
      mv "$sandbox/stripped.md" "$sandbox/$mutated_basename" || exit 1
      ;;
    C3)
      mutated_basename=CLAUDE-RUBY.md
      for reference in rules/session-types.md CLAUDE-FRONTEND.md; do
        awk 'index($0, "CLAUDE-RUBY.md") == 0' "$sandbox/$reference" > "$sandbox/filtered.md" || exit 1
        mv "$sandbox/filtered.md" "$sandbox/$reference" || exit 1
      done
      ;;
  esac
  output=$(check_tree "$sandbox")
  result=$?
  if [ "$result" -eq 1 ] && [[ "$output" == *"$mutated_basename"* ]]; then
    printf 'PASS: %s rejected naming %s\n' "$case_id" "$mutated_basename"
  else
    printf 'FAIL: %s not rejected\n' "$case_id"
    failure=1
  fi
done

# Python-track block (spec AC-3, AC-4). The Python file offers no alternative to
# a settled decision, carries a level-two heading for each of the spec's 40
# outline rows, and sits in the 800 to 1000 line band that matches the Express file.
python_track="$real_tree/CLAUDE-PYTHON.md"
banned_python_terms=$(grep -nE 'Django|Celery|\bRQ\b|pip install|stdlib' "$python_track")
if [ -z "$banned_python_terms" ]; then
  echo 'PASS: P1 Python track names no rejected alternative'
else
  printf 'FAIL: P1 Python track names a rejected alternative:\n%s\n' "$banned_python_terms"
  failure=1
fi

python_outline_headings=(
  'Stack' 'Directory Structure' 'Layer Responsibilities' 'File and Module Naming'
  'File Layout' 'Import Ordering' 'Entry Point (App Factory)' 'Build Tool (uv)'
  'Health Endpoints' 'Worker Pattern (arq)' 'Containers (R-351)' 'Session Store' 'CSRF'
  'Rate Limiting' 'Idempotency Keys' 'Request Timeout' 'Environment Validation'
  'FastAPI App Structure' 'Router Pattern' 'Validation (Pydantic)' 'Repository Pattern'
  'Database Session and Engine' 'Migrations (Alembic)' 'Risky Migrations'
  'Error Handling and Response Envelope' 'Stripe Webhook' 'Email (Resend)'
  'Object Storage (Cloudflare R2)' 'Error Tracking (Sentry)' 'Circuit Breaker'
  'Logging (structlog)' 'Observability (R-341 to R-346)' 'pg_cron Cleanup Jobs'
  'OpenAPI and /v1 Versioning' 'Python Typing Patterns' 'RESTful Route Naming'
  'Testing (pytest)' 'Tooling' 'Enforcement' 'Build/Run Assets (R-407)'
)
missing_python_headings=()
for heading in "${python_outline_headings[@]}"; do
  grep -Fxq "## $heading" "$python_track" || missing_python_headings+=("$heading")
done
if [ "${#python_outline_headings[@]}" -eq 40 ] && [ "${#missing_python_headings[@]}" -eq 0 ]; then
  echo 'PASS: P2 Python track carries all 40 outline headings'
else
  printf 'FAIL: P2 Python track is missing headings: %s\n' "${missing_python_headings[*]}"
  failure=1
fi

python_line_count=$(wc -l < "$python_track" | tr -d ' ')
if [ "$python_line_count" -ge 800 ] && [ "$python_line_count" -le 1000 ]; then
  printf 'PASS: P3 Python track is %s lines, inside 800 to 1000\n' "$python_line_count"
else
  printf 'FAIL: P3 Python track is %s lines, outside 800 to 1000\n' "$python_line_count"
  failure=1
fi

exit "$failure"
