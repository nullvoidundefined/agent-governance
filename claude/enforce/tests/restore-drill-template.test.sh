#!/usr/bin/env bash
# Covers: M-7 M-8 (docs/specs/2026-10-05-migrate-backup.md)
# restore-drill template: claude/templates/restore-drill.yml parses as YAML
# (python3 + PyYAML; falls back to yq, then ruby; if none can parse, the test
# FAILS rather than skips), has a weekly cron schedule and workflow_dispatch,
# pins every `uses:` to a 40-hex SHA, holds no literal secret values, and has
# a step whose run text holds a SELECT count. M-8: the two rules files name
# db-migrate-safe.sh and restore-drill.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$(cd "$CLAUDE_HARNESS_ROOT/.." && pwd)"
TPL="$ROOT/claude/templates/restore-drill.yml"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "ok: $*"; }

if [ ! -f "$TPL" ]; then
  fail "template missing: $TPL"
else
  pass "template exists"
  # Parse: emit JSON via the first available YAML reader.
  JSON=""
  if python3 -c 'import yaml' 2>/dev/null; then
    JSON=$(python3 -c 'import sys,json,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$TPL" 2>/dev/null)
  elif command -v yq >/dev/null 2>&1; then
    JSON=$(yq -o=json '.' "$TPL" 2>/dev/null || yq '.' "$TPL" 2>/dev/null)
  elif command -v ruby >/dev/null 2>&1; then
    JSON=$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$TPL" 2>/dev/null)
  fi
  if [ -z "$JSON" ] || ! printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
    fail "template does not parse as YAML (or no YAML reader available)"
  else
    pass "template parses as YAML"
    # PyYAML reads the key `on` as boolean true; accept either spelling.
    ON='(.["on"] // .["true"])'
    printf '%s' "$JSON" | jq -e "$ON.schedule | type == \"array\" and length > 0 and (.[0].cron | type == \"string\" and (split(\" \") | length == 5))" >/dev/null 2>&1
    [ $? -eq 0 ] && pass "schedule with a 5-field cron" || fail "no schedule with a 5-field cron"
    printf '%s' "$JSON" | jq -e "$ON | has(\"workflow_dispatch\")" >/dev/null 2>&1
    [ $? -eq 0 ] && pass "workflow_dispatch present" || fail "workflow_dispatch missing"
    printf '%s' "$JSON" | jq -e '[.jobs[].services // {} | to_entries[] | .value.image | tostring | test("postgres")] | any' >/dev/null 2>&1
    [ $? -eq 0 ] && pass "a postgres service container" || fail "no postgres service container"
    printf '%s' "$JSON" | jq -e '[.jobs[].steps[]? | .run? // empty | tostring | test("select +count"; "i")] | any' >/dev/null 2>&1
    [ $? -eq 0 ] && pass "a step runs a SELECT count smoke query" || fail "no step with a SELECT count in its run text"
  fi

  uses=$(grep -E '^[[:space:]-]*uses:' "$TPL" | sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]]*#.*$//')
  if [ -z "$uses" ]; then
    fail "no uses: lines (the template must check out or restore through pinned actions)"
  else
    bad=$(printf '%s\n' "$uses" | grep -Ev '^[^@[:space:]]+@[0-9a-f]{40}$' || true)
    [ -z "$bad" ] && pass "every uses: pinned to a 40-hex SHA" || fail "unpinned uses: $bad"
  fi

  # Secrets only by ${{ secrets.NAME }}: any key whose name looks secret must
  # have a value that is an expression, and no credential-shaped literals.
  lit=$(grep -Eiv '\$\{\{[[:space:]]*secrets\.[A-Za-z0-9_]+[[:space:]]*\}\}' "$TPL" \
    | grep -Ei '(password|passwd|secret|token|api[_-]?key|access[_-]?key)[A-Za-z_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[^$"'"'"'[:space:]#][^[:space:]]*' || true)
  # Allow throwaway service-container values that are plainly not secrets.
  lit=$(printf '%s\n' "$lit" | grep -Ev 'POSTGRES_PASSWORD:[[:space:]]*(postgres|drill|test|restore-drill)[[:space:]]*$' | sed '/^$/d')
  [ -z "$lit" ] && pass "no literal secret-looking values" || fail "literal secret-looking value: $lit"
  if grep -Eq 'AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|postgres(ql)?://[^:/[:space:]]+:[^@$[:space:]{]+@' "$TPL"; then
    fail "credential-shaped literal in template"
  else pass "no credential-shaped literals"; fi
  grep -q '\${{[[:space:]]*secrets\.' "$TPL" && pass "secrets referenced via secrets.NAME" || fail "template references no secrets.NAME (snapshot access needs one)"
fi

# M-8: rules mention the wrapper and the drill
for f in "$ROOT/rules/CLOUD-DEPLOYMENT.md" "$ROOT/rules/stacks/DATABASE.md"; do
  n=$(basename "$f")
  grep -q 'db-migrate-safe\.sh' "$f" && pass "$n names db-migrate-safe.sh" || fail "$n does not mention db-migrate-safe.sh"
  grep -qi 'restore-drill' "$f" && pass "$n names restore-drill" || fail "$n does not mention restore-drill"
done

[ "$fails" -eq 0 ] && { echo "PASS: restore-drill-template"; exit 0; }
echo "FAIL: restore-drill-template ($fails failures)"
exit 1
