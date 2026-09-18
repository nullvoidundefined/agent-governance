#!/usr/bin/env bash
# repo-setup.test.sh: verifies skills/repo-setup/scripts/setup.sh against a
# stubbed gh (REPO_SETUP_GH_CMD) that records every call and keeps the
# repository's remote state in a scratch directory. --check on a bare
# repository reports every item MISSING; apply writes the four files, creates
# staging, both rulesets, the merge policy, alerts, and secret scanning, and
# reports only greptile as the manual remainder; a second apply changes
# nothing; an installed Greptile makes --check exit 0; --stack and
# --required-reviews shape the templates and the ruleset; an existing file
# is never overwritten; the product-docs item (R-607) seeds the features
# list, the user stories index, and the checklist script, never overwrites
# them, and --no-product-docs records the opt-out in .enforce.json.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SETUP="$CLAUDE_HARNESS_ROOT/skills/repo-setup/scripts/setup.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
jqe() { jq -e "$@" >/dev/null; }
row() { printf '%s' "$OUT" | grep -E "^$1 +$2 " >/dev/null; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export STUB_STATE="$SB/state"; mkdir -p "$STUB_STATE"
export STUB_LOG="$SB/gh.log"; : > "$STUB_LOG"
export STUB_APPS=""
cat > "$SB/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub: records calls, answers from STUB_STATE.
printf '%s\n' "$*" >> "$STUB_LOG"
A="$*"
case "$A" in
  "auth status") exit 0 ;;
  "repo view --json nameWithOwner --jq .nameWithOwner") echo acme/widget ;;
  "api repos/acme/widget --jq .default_branch") echo main ;;
  "api repos/acme/widget --jq [.allow_squash_merge"*) cat "$STUB_STATE/policy" 2>/dev/null || echo "true,true,true,false,false" ;;
  "api repos/acme/widget --jq .security_and_analysis"*) cat "$STUB_STATE/scan" 2>/dev/null || echo disabled ;;
  "api repos/acme/widget/branches/staging") [ -f "$STUB_STATE/staging" ] ;;
  "api repos/acme/widget/git/ref/heads/main --jq .object.sha") echo abc123 ;;
  "api -X POST repos/acme/widget/git/refs -f ref=refs/heads/staging -f sha=abc123") : > "$STUB_STATE/staging" ;;
  "api repos/acme/widget/rulesets --jq .[].name") cat "$STUB_STATE/rulesets" 2>/dev/null ;;
  "api -X POST repos/acme/widget/rulesets --input "*) f="${A##* }"; n=$(jq -r .name "$f"); echo "$n" >> "$STUB_STATE/rulesets"; cp "$f" "$STUB_STATE/ruleset-$n.json" ;;
  "repo edit acme/widget --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge --enable-auto-merge=false") echo "true,false,false,true,false" > "$STUB_STATE/policy" ;;
  "api repos/acme/widget/vulnerability-alerts") [ -f "$STUB_STATE/alerts" ] ;;
  "api -X PUT repos/acme/widget/vulnerability-alerts") : > "$STUB_STATE/alerts" ;;
  "api -X PUT repos/acme/widget/automated-security-fixes") : ;;
  "api -X PATCH repos/acme/widget --input "*) echo enabled > "$STUB_STATE/scan" ;;
  "api /user/installations --jq .installations[].app_slug") printf '%s\n' "$STUB_APPS" ;;
  *) echo "gh stub: unexpected call: $A" >&2; exit 99 ;;
esac
STUB
chmod +x "$SB/gh"
export REPO_SETUP_GH_CMD="$SB/gh"

REPO="$SB/widget"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid; git -C "$REPO" config user.name t
printf '{"name":"widget","scripts":{"test":"vitest run"}}\n' > "$REPO/package.json"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init

# 1. --check on a bare repository: everything missing, exit 1, nothing written.
OUT=$(cd "$REPO" && bash "$SETUP" acme/widget --check 2>&1); ST=$?
check "check exits 1 when items are missing" test "$ST" -eq 1
for item in ci dependabot pr-template gitignore staging protect-refs protect-merge merge-policy alerts secret-scan greptile harness product-docs; do
  check "check reports $item MISSING" row "$item" MISSING
done
check "check writes no files" test ! -e "$REPO/.github"
check "check posts nothing" bash -c "! grep -q -- '-X POST' '$STUB_LOG'"

# 2. Apply: files, branch, rulesets, policy, alerts, scanning, harness bootstrap; greptile remains.
OUT=$(cd "$REPO" && bash "$SETUP" acme/widget --harness-repo https://github.com/acme/agent-governance 2>&1); ST=$?
check "apply exits 1 while greptile is manual" test "$ST" -eq 1
for item in ci dependabot pr-template gitignore staging protect-refs protect-merge merge-policy alerts secret-scan harness product-docs; do
  check "apply reports $item OK" row "$item" OK
done
check "bootstrap hook written" test -x "$REPO/.claude/hooks/harness-bootstrap.sh"
check "bootstrap hook carries the repo url" grep -q 'HARNESS_REPO="https://github.com/acme/agent-governance"' "$REPO/.claude/hooks/harness-bootstrap.sh"
check "bootstrap hook has no placeholder left" bash -c "! grep -q __HARNESS_REPO__ '$REPO/.claude/hooks/harness-bootstrap.sh'"
check "settings register the bootstrap at SessionStart" jqe '[.hooks.SessionStart[].hooks[].command | select(test("harness-bootstrap.sh"))] | length == 1' "$REPO/.claude/settings.json"
check "apply reports greptile with the install link" bash -c "printf '%s' \"\$0\" | grep -q 'https://github.com/apps/greptile/installations/new'" "$OUT"
check "ci workflow written with the ci job" grep -q '^    name: ci$' "$REPO/.github/workflows/ci.yml"
check "ci workflow uses pnpm for node" grep -q 'pnpm test' "$REPO/.github/workflows/ci.yml"
check "dependabot names the npm ecosystem" grep -q 'package-ecosystem: npm' "$REPO/.github/dependabot.yml"
check "dependabot has no placeholder left" bash -c "! grep -q __ECOSYSTEM__ '$REPO/.github/dependabot.yml'"
check "pr template has the seven fields" grep -q '^## Review focus' "$REPO/.github/pull_request_template.md"
check "gitignore excludes env files" grep -q '^\.env' "$REPO/.gitignore"
check "staging created from main" test -f "$STUB_STATE/staging"
check "protect-refs has deletion and non_fast_forward and no bypass" jqe '.rules | map(.type) == ["deletion","non_fast_forward"]' "$STUB_STATE/ruleset-protect-refs.json"
check "protect-refs bypass list empty" jqe '.bypass_actors == []' "$STUB_STATE/ruleset-protect-refs.json"
check "protect-refs covers main and staging" jqe '.conditions.ref_name.include == ["refs/heads/main","refs/heads/staging"]' "$STUB_STATE/ruleset-protect-refs.json"
check "protect-merge requires the ci check" jqe '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[0].context == "ci"' "$STUB_STATE/ruleset-protect-merge.json"
check "protect-merge default zero reviews" jqe '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count == 0' "$STUB_STATE/ruleset-protect-merge.json"
check "protect-merge admin bypass" jqe '.bypass_actors[0].actor_id == 5' "$STUB_STATE/ruleset-protect-merge.json"
check "merge policy set" test "$(cat "$STUB_STATE/policy")" = "true,false,false,true,false"
check "secret scanning enabled" test "$(cat "$STUB_STATE/scan")" = "enabled"

# 3. Second apply is idempotent.
posts_before=$(grep -c -- '-X POST' "$STUB_LOG")
printf '# edited by hand\n' >> "$REPO/.github/workflows/ci.yml"
OUT=$(cd "$REPO" && bash "$SETUP" acme/widget --harness-repo https://github.com/acme/agent-governance 2>&1)
check "second apply posts nothing new" test "$(grep -c -- '-X POST' "$STUB_LOG")" -eq "$posts_before"
check "existing workflow not overwritten" grep -q '# edited by hand' "$REPO/.github/workflows/ci.yml"
check "second apply reports rulesets present" row protect-refs OK
check "second apply does not duplicate the bootstrap entry" jqe '[.hooks.SessionStart[].hooks[].command | select(test("harness-bootstrap.sh"))] | length == 1' "$REPO/.claude/settings.json"

# 4. Greptile installed: --check exits 0.
export STUB_APPS=greptile
OUT=$(cd "$REPO" && bash "$SETUP" acme/widget --check 2>&1); ST=$?
check "check exits 0 at baseline" test "$ST" -eq 0
check "greptile OK when installed" row greptile OK
check "baseline line printed" bash -c "printf '%s' \"\$0\" | grep -q 'meets the baseline'" "$OUT"

# 5. Stack and review options shape the output.
REPO2="$SB/pyapp"; mkdir -p "$REPO2"; git -C "$REPO2" init -q -b main
rm -f "$STUB_STATE/rulesets" "$STUB_STATE"/ruleset-*.json
printf '[project]\nname = "pyapp"\n' > "$REPO2/pyproject.toml"
OUT=$(cd "$REPO2" && bash "$SETUP" acme/widget --required-reviews 2 2>&1)
check "python stack detected: ruff in ci" grep -q 'ruff check' "$REPO2/.github/workflows/ci.yml"
check "python stack: pip ecosystem" grep -q 'package-ecosystem: pip' "$REPO2/.github/dependabot.yml"
check "required reviews honoured" jqe '.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count == 2' "$STUB_STATE/ruleset-protect-merge.json"

# 5b. A repository with its own workflow under another name keeps it, and
#     --ci-context names the check the ruleset requires; an existing
#     .claude/settings.json keeps its hooks when the bootstrap entry is merged.
REPO3="$SB/existing"; mkdir -p "$REPO3/.github/workflows" "$REPO3/.claude"; git -C "$REPO3" init -q -b main
rm -f "$STUB_STATE/rulesets" "$STUB_STATE"/ruleset-*.json
printf 'name: enforce\njobs:\n  fixtures:\n    runs-on: ubuntu-latest\n' > "$REPO3/.github/workflows/enforce.yml"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo pre"}]}]}}\n' > "$REPO3/.claude/settings.json"
OUT=$(cd "$REPO3" && bash "$SETUP" acme/widget --ci-context fixtures --harness-repo https://github.com/acme/agent-governance 2>&1)
check "existing workflow satisfies ci" row ci OK
check "existing workflow named in the report" bash -c "printf '%s' \"\$0\" | grep -q 'workflow present: .github/workflows/enforce.yml'" "$OUT"
check "no ci.yml written beside an existing workflow" test ! -e "$REPO3/.github/workflows/ci.yml"
check "ci-context honoured in the ruleset" jqe '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[0].context == "fixtures"' "$STUB_STATE/ruleset-protect-merge.json"
check "existing settings keep their hooks" jqe '.hooks.PreToolUse[0].hooks[0].command == "echo pre"' "$REPO3/.claude/settings.json"
check "bootstrap merged into existing settings" jqe '[.hooks.SessionStart[].hooks[].command | select(test("harness-bootstrap.sh"))] | length == 1' "$REPO3/.claude/settings.json"
check "harness reported OK after the merge" row harness OK

# 6. The harness repository itself: its settings run harness-sync.sh directly,
#    so the item is satisfied without a bootstrap hook.
REPO4="$SB/harness-repo"; mkdir -p "$REPO4/.claude" "$REPO4/claude/hooks"; git -C "$REPO4" init -q -b main
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO4/claude/hooks/harness-sync.sh"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \\"$CLAUDE_PROJECT_DIR/claude/hooks/harness-sync.sh\\" \\"$CLAUDE_PROJECT_DIR\\""}]}]}}\n' > "$REPO4/.claude/settings.json"
OUT=$(cd "$REPO4" && bash "$SETUP" acme/agent-governance --check 2>&1)
check "harness repository reports harness OK from its own hook" row harness OK
check "harness repository gets no bootstrap hook" test ! -e "$REPO4/.claude/hooks/harness-bootstrap.sh"

# 8. Product docs (R-607, spec B-16, B-17): --check names each absent file;
#    apply writes all three from the harness templates and the canonical
#    script; an existing features list is never overwritten.
REPO5="$SB/app"; mkdir -p "$REPO5"; git -C "$REPO5" init -q -b main
OUT=$(cd "$REPO5" && bash "$SETUP" acme/widget --check 2>&1)
check "B-16 product-docs MISSING on a bare repository" row product-docs MISSING
for f in docs/feature-list/features.md docs/user-stories/README.md scripts/require-feature-checklist.sh; do
  check "B-16 check names $f" bash -c "printf '%s' \"\$0\" | grep -E '^product-docs ' | grep -qF '$f'" "$OUT"
done
check "B-16 check writes no docs" test ! -e "$REPO5/docs"
mkdir -p "$REPO5/docs/feature-list"; printf '# Hand-written list\n' > "$REPO5/docs/feature-list/features.md"
OUT=$(cd "$REPO5" && bash "$SETUP" acme/widget --harness-repo https://github.com/acme/agent-governance 2>&1)
check "B-17 apply reports product-docs OK" row product-docs OK
check "B-17 existing features list not overwritten" test "$(cat "$REPO5/docs/feature-list/features.md")" = "# Hand-written list"
check "B-17 user stories index written" grep -q 'R-607' "$REPO5/docs/user-stories/README.md"
check "B-17 index has no placeholder left" bash -c "! grep -q '{{' '$REPO5/docs/user-stories/README.md'"
check "B-17 checklist script executable" test -x "$REPO5/scripts/require-feature-checklist.sh"
check "B-17 checklist script is the canonical copy" cmp -s "$CLAUDE_HARNESS_ROOT/enforce/require-feature-checklist.sh" "$REPO5/scripts/require-feature-checklist.sh"
REPO5B="$SB/app-fresh"; mkdir -p "$REPO5B"; git -C "$REPO5B" init -q -b main
OUT=$(cd "$REPO5B" && bash "$SETUP" acme/widget --harness-repo https://github.com/acme/agent-governance 2>&1)
check "B-17 features list written from the template" grep -q '^Status key: \*\*Complete\*\* | \*\*Partial\*\* | \*\*Planned\*\*$' "$REPO5B/docs/feature-list/features.md"
check "B-17 features list names the project" grep -q '^# app-fresh Feature List$' "$REPO5B/docs/feature-list/features.md"
check "B-17 features list has a dated Last updated line" grep -qE '^Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2} ' "$REPO5B/docs/feature-list/features.md"
OUT=$(cd "$REPO5B" && bash "$SETUP" acme/widget --check 2>&1)
check "B-17 check after apply reports OK" row product-docs OK

# 9. Opt-out (spec B-18): --no-product-docs writes no docs, merges
#    productDocs:false into an existing .enforce.json, and --check then
#    reports SKIPPED without counting it as missing.
REPO6="$SB/library"; mkdir -p "$REPO6"; git -C "$REPO6" init -q -b main
printf '{"importZones":[]}\n' > "$REPO6/.enforce.json"
OUT=$(cd "$REPO6" && bash "$SETUP" acme/widget --no-product-docs --harness-repo https://github.com/acme/agent-governance 2>&1)
check "B-18 opt-out reports SKIPPED" row product-docs SKIPPED
check "B-18 opt-out writes no docs" test ! -e "$REPO6/docs"
check "B-18 opt-out writes no script" test ! -e "$REPO6/scripts"
check "B-18 opt-out recorded" jqe '.productDocs == false' "$REPO6/.enforce.json"
check "B-18 opt-out keeps existing keys" jqe '.importZones == []' "$REPO6/.enforce.json"
OUT=$(cd "$REPO6" && bash "$SETUP" acme/widget --check 2>&1)
check "B-18 check reports SKIPPED" row product-docs SKIPPED
check "B-18 SKIPPED is not counted missing" bash -c "! printf '%s' \"\$0\" | grep -q '^product-docs .*MISSING'" "$OUT"

# 7. Usage.
OUT=$(cd "$REPO" && bash "$SETUP" not-a-repo 2>&1); ST=$?
check "bad repo name is a usage error" test "$ST" -eq 2

[ "$fail" -eq 0 ] && echo "repo-setup.test.sh PASS"
exit "$fail"
