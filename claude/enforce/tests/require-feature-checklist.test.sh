#!/usr/bin/env bash
# require-feature-checklist.test.sh: verifies enforce/require-feature-checklist.sh
# (R-607, spec docs/superpowers/specs/2026-09-18-product-docs-design.md B-1 to
# B-11) against sandboxed repositories: each stack's trigger paths, the three
# required artifacts, the skip rules, and the .enforce.json opt-out and
# extra triggers.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CHECK="$CLAUDE_HARNESS_ROOT/enforce/require-feature-checklist.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
OUT=""; ST=0

# check <name> <command...>: records one PASS or FAIL line for an assertion.
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; echo "  output was: $OUT"; fail=1; fi; }

# reports <text>: true when the last run's output contains the text.
reports() { printf '%s' "$OUT" | grep -qF -- "$1"; }

# lacks <text>: true when the last run's output does not contain the text.
lacks() { ! printf '%s' "$OUT" | grep -qF -- "$1"; }

# make_repo <name>: a repository with one commit on main and a checked-out
# feat/x branch; prints its path.
make_repo() {
  local dir="$SB/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.invalid; git -C "$dir" config user.name t
  printf '# app\n' > "$dir/README.md"
  git -C "$dir" add -A && git -C "$dir" commit -qm init
  git -C "$dir" switch -q -c feat/x
  printf '%s' "$dir"
}

# add_files <repo> <path>...: creates each path with placeholder content and
# commits them together on the current branch.
add_files() {
  local dir="$1"; shift
  local path
  for path in "$@"; do
    mkdir -p "$dir/$(dirname "$path")"
    printf 'content %s\n' "$RANDOM" >> "$dir/$path"
  done
  git -C "$dir" add -A && git -C "$dir" commit -qm "add $*"
}

# run_check <repo> [base]: runs the script inside the repository with the
# base defaulting to main; sets OUT and ST.
run_check() {
  OUT=$(cd "$1" && FEATURE_CHECKLIST_BASE="${2:-main}" bash "$CHECK" 2>&1); ST=$?
}

ARTIFACTS=(docs/feature-list/features.md docs/user-stories/trips.md e2e/trips.spec.ts)

# B-1: no trigger file.
R=$(make_repo b1); add_files "$R" README.md; run_check "$R"
check "B-1 no trigger exits 0" test "$ST" -eq 0
check "B-1 no trigger prints nothing" test -z "$OUT"

# B-2: Next page and route handler.
R=$(make_repo b2page); add_files "$R" src/app/trips/page.tsx; run_check "$R"
check "B-2 next page exits 1" test "$ST" -eq 1
check "B-2 names the trigger" reports "src/app/trips/page.tsx"
check "B-2 names features.md" reports "docs/feature-list/features.md"
check "B-2 names the user story" reports "docs/user-stories/"
check "B-2 names the e2e spec" reports "e2e/"
R=$(make_repo b2route); add_files "$R" src/app/api/trips/route.ts; run_check "$R"
check "B-2 next route handler exits 1" test "$ST" -eq 1

# B-3: Nuxt pages, server/api, server/routes.
for path in app/pages/trips/index.vue server/api/trips.get.ts server/routes/feed.ts; do
  R=$(make_repo "b3-$(printf '%s' "$path" | tr '/.' '--')"); add_files "$R" "$path"; run_check "$R"
  check "B-3 nuxt $path exits 1" test "$ST" -eq 1
done

# B-4: FastAPI routers, __init__.py excluded.
R=$(make_repo b4router); add_files "$R" app/routers/trips.py; run_check "$R"
check "B-4 fastapi router exits 1" test "$ST" -eq 1
R=$(make_repo b4init); add_files "$R" app/routers/__init__.py; run_check "$R"
check "B-4 routers __init__.py exits 0" test "$ST" -eq 0

# B-5: Express routes and handlers, test files excluded.
R=$(make_repo b5route); add_files "$R" src/routes/trips.ts; run_check "$R"
check "B-5 express route exits 1" test "$ST" -eq 1
R=$(make_repo b5handler); add_files "$R" src/handlers/trips/createTrip.ts; run_check "$R"
check "B-5 express handler exits 1" test "$ST" -eq 1
R=$(make_repo b5test); add_files "$R" src/handlers/trips/createTrip.test.ts; run_check "$R"
check "B-5 handler test file exits 0" test "$ST" -eq 0

# B-6: trigger with all three artifacts.
R=$(make_repo b6); add_files "$R" src/app/trips/page.tsx "${ARTIFACTS[@]}"; run_check "$R"
check "B-6 all artifacts exits 0" test "$ST" -eq 0

# B-7: partial artifacts name only what is missing; a README-only story
# change does not count as a story.
R=$(make_repo b7); add_files "$R" src/app/trips/page.tsx docs/feature-list/features.md e2e/trips.spec.ts; run_check "$R"
check "B-7 missing story exits 1" test "$ST" -eq 1
check "B-7 does not name features.md as missing" lacks "features.md not updated"
check "B-7 does not name e2e as missing" lacks "no e2e spec"
check "B-7 names the story" reports "docs/user-stories/"
R=$(make_repo b7readme); add_files "$R" src/app/trips/page.tsx docs/feature-list/features.md docs/user-stories/README.md e2e/trips.spec.ts; run_check "$R"
check "B-7 README-only story change exits 1" test "$ST" -eq 1
check "B-7 README-only names the story" reports "docs/user-stories/"

# B-8: monorepo prefixes trigger; artifacts stay at the root, e2e may nest.
R=$(make_repo b8); add_files "$R" apps/client/web/src/app/trips/page.tsx; run_check "$R"
check "B-8 monorepo page exits 1" test "$ST" -eq 1
check "B-8 names the prefixed trigger" reports "apps/client/web/src/app/trips/page.tsx"
add_files "$R" docs/feature-list/features.md docs/user-stories/trips.md apps/e2e/trips.spec.ts; run_check "$R"
check "B-8 root artifacts plus nested e2e exits 0" test "$ST" -eq 0

# B-9: a trigger path modified rather than added.
R=$(make_repo b9); git -C "$R" switch -q main; add_files "$R" src/routes/trips.ts
git -C "$R" switch -q feat/x; git -C "$R" merge -q --ff-only main; add_files "$R" src/routes/trips.ts; run_check "$R"
check "B-9 modified route exits 0" test "$ST" -eq 0

# B-10: skip on main, on an unresolvable base, and on the opt-out.
R=$(make_repo b10main); git -C "$R" switch -q main; add_files "$R" src/app/trips/page.tsx; run_check "$R" "HEAD~1"
check "B-10 on main exits 0" test "$ST" -eq 0
R=$(make_repo b10base); add_files "$R" src/app/trips/page.tsx; run_check "$R" "no-such-ref"
check "B-10 unresolvable base exits 0" test "$ST" -eq 0
R=$(make_repo b10optout); printf '{"productDocs": false}\n' > "$R/.enforce.json"; add_files "$R" src/app/trips/page.tsx; run_check "$R"
check "B-10 productDocs false exits 0" test "$ST" -eq 0

# B-11: extra triggers from .enforce.json, and a bad pattern is ignored.
R=$(make_repo b11); printf '{"productDocs": {"extraTriggers": ["^src/views/.+\\\\.tsx$"]}}\n' > "$R/.enforce.json"
add_files "$R" src/views/Trips.tsx; run_check "$R"
check "B-11 extra trigger exits 1" test "$ST" -eq 1
check "B-11 names the extra trigger" reports "src/views/Trips.tsx"
R=$(make_repo b11bad); printf '{"productDocs": {"extraTriggers": ["(unclosed"]}}\n' > "$R/.enforce.json"
add_files "$R" app/routers/trips.py; run_check "$R"
check "B-11 bad pattern keeps built-in triggers" test "$ST" -eq 1
check "B-11 bad pattern is reported" reports "(unclosed"

[ "$fail" -eq 0 ] && echo "require-feature-checklist.test.sh PASS"
exit "$fail"
