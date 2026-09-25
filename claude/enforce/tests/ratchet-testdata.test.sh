#!/usr/bin/env bash
# Verifies that ratchet.mjs treats any path with a whole `testdata/` segment as
# inert sample input and leaves it out of the files it counts, the same way it
# already leaves out node_modules/, dist/, and the other build trees (IAN-381,
# B-6c). The Semgrep samples under enforce/tests/testdata/semgrep/ are
# deliberately insecure code, and before this slice they were the only tracked
# .ts files under claude/, so CI's ratchet step demanded a baseline for them.
#
# Three cases, each in its own throwaway git repository:
#   a. The only tracked .ts files sit under a testdata/ segment (nested and at
#      the root). The ratchet exits 0 and prints its "nothing to baseline" line.
#   b. A real src/app.ts is tracked beside them. The ratchet now demands a
#      baseline: it exits non-zero and names .enforce-baseline.json.
#   c. The only tracked .ts file is src/mytestdata/app.ts, where "testdata" is
#      part of a directory name but not a whole segment. It is NOT excluded, so
#      the ratchet demands a baseline exactly as in case b.
#
# Every failure is collected and printed, and the fixture exits non-zero at the
# end if any assertion failed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
RATCHET="$CLAUDE_HARNESS_ROOT/enforce/ratchet.mjs"
SCRATCH_ROOT=$(mktemp -d)
trap 'rm -rf "$SCRATCH_ROOT"' EXIT
FAILURES=0

# Records one failed assertion with its case label and the ratchet output.
record_failure() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

# Creates an empty git repository with naming enforcement on, under the
# scratch root, and prints its path.
create_repo() {
  local repo_dir="$SCRATCH_ROOT/$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email t@t
  git -C "$repo_dir" config user.name t
  printf '{"naming":{"enabled":true}}\n' > "$repo_dir/.enforce.json"
  echo "$repo_dir"
}

# Writes one .ts file at the given repo-relative path.
write_source_file() {
  local repo_dir="$1" relative_path="$2"
  mkdir -p "$(dirname "$repo_dir/$relative_path")"
  printf 'export function generate() { return 1; }\n' > "$repo_dir/$relative_path"
}

# Stages and commits everything in the repository.
commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm "chore: snapshot"
}

# a. Only testdata/ files are tracked: nothing to baseline, exit 0.
REPO_A=$(create_repo case-a)
write_source_file "$REPO_A" "some/testdata/sample.ts"
write_source_file "$REPO_A" "testdata/root-sample.ts"
commit_all "$REPO_A"
OUT_A=$(node "$RATCHET" "$REPO_A" 2>&1)
RC_A=$?
[ "$RC_A" -eq 0 ] \
  || record_failure "case a: a tree whose only .ts files sit under testdata/ must exit 0, got rc=$RC_A: $OUT_A"
grep -q 'nothing to baseline' <<< "$OUT_A" \
  || record_failure "case a: expected the 'nothing to baseline' line, got: $OUT_A"
grep -q '\.enforce-baseline\.json' <<< "$OUT_A" \
  && record_failure "case a: testdata/ samples must not make the ratchet demand a baseline, got: $OUT_A"

# b. Real source beside the testdata/ files: the ratchet demands a baseline.
REPO_B=$(create_repo case-b)
write_source_file "$REPO_B" "some/testdata/sample.ts"
write_source_file "$REPO_B" "src/app.ts"
commit_all "$REPO_B"
OUT_B=$(node "$RATCHET" "$REPO_B" 2>&1)
RC_B=$?
[ "$RC_B" -ne 0 ] \
  || record_failure "case b: a tracked src/app.ts with no baseline must exit non-zero, got rc=0: $OUT_B"
grep -q 'no \.enforce-baseline\.json' <<< "$OUT_B" \
  || record_failure "case b: expected 'no .enforce-baseline.json', got: $OUT_B"
grep -q 'nothing to baseline' <<< "$OUT_B" \
  && record_failure "case b: real source must not be reported as nothing to baseline, got: $OUT_B"

# c. "testdata" inside a directory name, not a whole segment: not excluded.
REPO_C=$(create_repo case-c)
write_source_file "$REPO_C" "src/mytestdata/app.ts"
commit_all "$REPO_C"
OUT_C=$(node "$RATCHET" "$REPO_C" 2>&1)
RC_C=$?
[ "$RC_C" -ne 0 ] \
  || record_failure "case c: src/mytestdata/app.ts is real source and must demand a baseline, got rc=0: $OUT_C"
grep -q 'no \.enforce-baseline\.json' <<< "$OUT_C" \
  || record_failure "case c: expected 'no .enforce-baseline.json', got: $OUT_C"

if [ "$FAILURES" -gt 0 ]; then
  echo "ratchet-testdata.test.sh: $FAILURES assertion(s) failed"
  exit 1
fi
echo "ratchet-testdata.test.sh PASS"
