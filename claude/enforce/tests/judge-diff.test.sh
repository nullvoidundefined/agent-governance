#!/usr/bin/env bash
# Shard: slow
# Covers: ci:llm-rule-judge
# Verifies judge-diff.sh (the CI rule judge) exits 1 and prints the finding when
# the judge returns a high-confidence error-severity violation, and exits 0
# silently on below-threshold, warn-severity, or empty verdicts. Uses
# CLAUDE_JUDGE_CMD to stub the model, so no live API call. A judge run that
# fails is captured as a trailing "exit=<n>" line so set -e does not abort.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
JUDGE="$CLAUDE_HARNESS_ROOT/enforce/judge-diff.sh"

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git commit -q --allow-empty -m init
printf 'export function generate(){}\n' > generate.ts; git add .; git commit -q -m x

# A stub that prints the given JSON verdict to stdout.
mkstub() { local j f; j=$(mktemp); printf '%s' "$1" > "$j"; f=$(mktemp); printf '#!/usr/bin/env bash\ncat %q\n' "$j" > "$f"; chmod +x "$f"; echo "$f"; }

# Creates a curl stub that captures the request's -d argument and returns an
# API response containing an empty violations verdict. Arguments: stub directory
# and capture filename. Prints nothing. Returns 0 on success, nonzero on failure.
mkcapture() {
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'capture_file=%q\n' "$2"
    cat <<'STUB'
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-d" ]; then
    printf '%s' "$2" > "$capture_file"
    printf '%s\n' '{"content":[{"text":"{\"violations\":[]}"}]}'
    exit 0
  fi
  shift
done
exit 1
STUB
  } > "$1/curl"
  chmod +x "$1/curl"
}

# High confidence -> ask (the human adjudicates; 2026-09-05).
S1=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.ts","why":"vague filename"}]}')
OUT=$(CLAUDE_JUDGE_CMD="$S1" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
grep -q '^exit=1$' <<< "$OUT"

# Below threshold -> allow (no output).
S2=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.5,"file":"generate.ts","why":"maybe"}]}')
OUT2=$(CLAUDE_JUDGE_CMD="$S2" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
[ -z "$OUT2" ]

# No violations -> allow.
S3=$(mkstub '{"violations":[]}')
OUT3=$(CLAUDE_JUDGE_CMD="$S3" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
[ -z "$OUT3" ]

# High confidence violation whose manifest severity is warn -> allow (no deny
# output). R-322 left the llm-judge tier in the 2026-09-04 reclassification, so
# this now covers the severity-lookup FALLBACK: an id the judge returns that has
# no llm-judge row still resolves through its remaining row (advisory, warn) and
# must not ask. A judge that hallucinates a rule id must never gate a push.
S4=$(mkstub '{"violations":[{"rule":"R-322","confidence":0.95,"file":"x.ts","why":"long fn"}]}')
OUT4=$(CLAUDE_JUDGE_CMD="$S4" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
[ -z "$OUT4" ] || { echo "FAIL: a warn-severity id should not produce ask output; got: $OUT4"; exit 1; }

# R-325 joined the llm-judge tier on 2026-09-17 (audit P2-4): CLAUDE.md tagged
# it `judge` and reference.md documented exactly what the judge decides for it
# ("never destructure a method"), while the manifest carried no llm-judge row,
# so that half of the rule was evaluated by nothing. Its row is warn, because
# the eslint row remains the hard guarantee for the syntax half, so a
# high-confidence verdict must report without losing the push.
S4c=$(mkstub '{"violations":[{"rule":"R-325","confidence":0.95,"file":"x.ts","why":"method destructured off its object"}]}')
OUT4c=$(CLAUDE_JUDGE_CMD="$S4c" bash "$JUDGE" HEAD~1 HEAD 2>/dev/null || echo "exit=$?")
[ -z "$OUT4c" ] || { echo "FAIL: R-325 is warn severity and must not gate the push; got: $OUT4c"; exit 1; }
ERR4c=$(CLAUDE_JUDGE_CMD="$S4c" bash "$JUDGE" HEAD~1 HEAD 2>&1 >/dev/null || echo "exit=$?")
grep -q "R-325" <<< "$ERR4c" || { echo "FAIL: a warn-severity judge verdict must still reach stderr; got: $ERR4c"; exit 1; }

# An id with no manifest row at all defaults to error severity and DOES deny,
# so an unknown id is not a silent bypass of the gate.
S4b=$(mkstub '{"violations":[{"rule":"R-999","confidence":0.95,"file":"x.ts","why":"unknown id"}]}')
OUT4b=$(CLAUDE_JUDGE_CMD="$S4b" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
[ -n "$OUT4b" ] || { echo "FAIL: an unknown rule id should default to error severity and ask"; exit 1; }

# Python-only diff still reaches the judge (the diff scope includes *.py).
printf 'def generate():\n    pass\n' > generate.py; git add .; git commit -q -m y
S5=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.py","why":"vague filename"}]}')
OUT5=$(CLAUDE_JUDGE_CMD="$S5" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
grep -q '^exit=1$' <<< "$OUT5" || { echo "FAIL: py-only diff should reach the judge and ask"; exit 1; }

# Ruby-only and Go-only diffs reach the judge too (*.rb and *.go in scope).
printf 'def generate\nend\n' > generate.rb; git add .; git commit -q -m z
S6=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.rb","why":"vague filename"}]}')
OUT6=$(CLAUDE_JUDGE_CMD="$S6" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
grep -q '^exit=1$' <<< "$OUT6" || { echo "FAIL: rb-only diff should reach the judge and deny"; exit 1; }
printf 'package x\n\nfunc Generate() {}\n' > generate.go; git add .; git commit -q -m w
S7=$(mkstub '{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.go","why":"vague filename"}]}')
OUT7=$(CLAUDE_JUDGE_CMD="$S7" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
grep -q '^exit=1$' <<< "$OUT7" || { echo "FAIL: go-only diff should reach the judge and deny"; exit 1; }

# Multi-row manifest id (R-324 has eslint+ruff+golangci rows, all error): the
# severity lookup must not collapse to warn on the multiline jq result
# (2026-07-31 criticism audit P1).
S8=$(mkstub '{"violations":[{"rule":"R-324","confidence":0.9,"file":"generate.go","why":"magic number"}]}')
OUT8=$(CLAUDE_JUDGE_CMD="$S8" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
grep -q '^exit=1$' <<< "$OUT8" || { echo "FAIL: multi-row error rule should deny, not downgrade to warn"; exit 1; }

# PR #8 review (Copilot, claude/hooks/enforcement-guard-check.sh): the
# session-start guard counts a secret-tool or pass entry as a live judge, so the
# judge has to be able to read a key out of the same stores. While it resolved
# only ANTHROPIC_API_KEY and the macOS keychain, a Linux host with a provisioned
# entry saw no degraded-judge warning and still got a judge that fail-opened on
# every push. Every binary the resolution path touches is stubbed on PATH, so no
# real keychain is read and no request leaves the machine.
STUB_DIR=$(mktemp -d)
VERDICT='{"violations":[{"rule":"R-315","confidence":0.9,"file":"generate.ts","why":"vague filename"}]}'
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_DIR/security"
printf '#!/usr/bin/env bash\nprintf "%%s" %q\n' "$(jq -n --arg t "$VERDICT" '{content:[{text:$t}]}')" > "$STUB_DIR/curl"
chmod +x "$STUB_DIR/security" "$STUB_DIR/curl"

# judgeDecisionWithStore <store-name>: "ask" when the judge, with only that
# store holding a key, fails the run on the finding, or "none" when it passed. A single
# function because the stub setup and the jq read must both sit inside one
# assertion, and a pipeline cannot.
judgeDecisionWithStore() {
  local store="$1" out
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "sk-ant-stub-key"\n' > "$STUB_DIR/$store"
  chmod +x "$STUB_DIR/$store"
  out=$(env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD \
    PATH="$STUB_DIR:$PATH" \
    CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" bash "$JUDGE" HEAD~1 HEAD 2>/dev/null || echo "exit=$?")
  rm -f "$STUB_DIR/$store"
  if grep -q '^exit=1$' <<< "$out"; then echo ask; else echo none; fi
}

for store in secret-tool pass; do
  GOT=$(judgeDecisionWithStore "$store")
  [ "$GOT" = "ask" ] || { echo "FAIL: a key held by $store must reach the judge; got $GOT"; exit 1; }
done

# With no store holding a key the judge still fails open, and says so, so the
# stubs above cannot be passing for the wrong reason.
ERRNONE=$(env -u ANTHROPIC_API_KEY -u CLAUDE_JUDGE_CMD \
  PATH="$STUB_DIR:$PATH" \
  CLAUDE_JUDGE_KEYCHAIN_SERVICE="claude-test-no-such-service" bash "$JUDGE" HEAD~1 HEAD 2>&1 >/dev/null || echo "exit=$?")
grep -q "no API key" <<< "$ERRNONE" \
  || { echo "FAIL: with no store holding a key the judge must report that it skipped; got $ERRNONE"; exit 1; }
rm -rf "$STUB_DIR"

# Vue-only and JavaScript-only outgoing diffs must reach the judge.
for source_file in generate.vue generate.js; do
  printf 'export function generate(){}\n' > "$source_file"
  git add "$source_file"; git commit -q -m "add $source_file"
  SOURCE_VERDICT=$(mkstub "$(jq -n --arg file "$source_file" \
    '{violations:[{rule:"R-315",confidence:0.9,file:$file,why:"vague filename"}]}')")
  SOURCE_OUT=$(CLAUDE_JUDGE_CMD="$SOURCE_VERDICT" bash "$JUDGE" HEAD~1 HEAD || echo "exit=$?")
  grep -q '^exit=1$' <<< "$SOURCE_OUT" \
    || { echo "FAIL: $source_file-only diff should reach the judge and ask"; exit 1; }
done

# Each generated-only outgoing diff must be empty and exit silently. S1 would
# produce an ask if any excluded source file reached the judge.
GENERATED_FAILURES=0
# Both depths are pinned on purpose. The first implementation excluded with
# `**/dist/**` and no glob magic, which matches `apps/web/dist/x.ts` but NOT a
# top-level `dist/x.ts`, so generated output at the repository root was judged
# while identical output one directory down was skipped. A revert to that form
# passes the nested cases and fails the root ones, which is the whole point of
# listing both (2026-09-18).
for generated_file in dist/generated.ts apps/web/dist/generated.ts build/generated.ts \
  node_modules/example/generated.ts generated.gen.ts nested/deep/other.gen.ts vendor/app.min.js; do
  mkdir -p "$(dirname "$generated_file")"
  printf 'export function generate(){}\n' > "$generated_file"
  git add -f "$generated_file"; git commit -q -m "add $generated_file"
  GENERATED_OUT=$(CLAUDE_JUDGE_CMD="$S1" bash "$JUDGE" HEAD~1 HEAD 2>&1 || echo "exit=$?")
  [ -z "$GENERATED_OUT" ] \
    || { echo "FAIL: $generated_file-only diff should exit silently; got: $GENERATED_OUT"; GENERATED_FAILURES=$((GENERATED_FAILURES + 1)); }
done

# CLAUDE_JUDGE_CMD bypasses payload assembly and receives no request. Capture
# curl's -d argument instead, keeping the real manifest and reference text.
CAPTURE_DIR=$(mktemp -d)
mkcapture "$CAPTURE_DIR" "$CAPTURE_DIR/request.json"
REAL_MANIFEST="$CLAUDE_HARNESS_ROOT/enforce/manifest.json"
jq -e '.rules | any(.id == "R-334" and .tier == "llm-judge")' "$REAL_MANIFEST" >/dev/null \
  || { echo "FAIL: the real manifest must include R-334 at tier llm-judge"; exit 1; }
printf 'export function generateAgain(){}\n' >> generate.js
git add generate.js; git commit -q -m "change judged source for vocabulary fixtures"

# No design spec exists in this fixture repository. A captured request proves
# the judge ran; R-334 must be absent from its rules and the push must allow.
VOCAB_OUT=$(env -u CLAUDE_JUDGE_CMD \
  PATH="$CAPTURE_DIR:$PATH" ANTHROPIC_API_KEY="$(printf '%s' fixture key)" \
  CLAUDE_MANIFEST_FILE="$REAL_MANIFEST" \
  CLAUDE_JUDGE_USAGE_LOG="$CAPTURE_DIR/usage.log" bash "$JUDGE" HEAD~1 HEAD 2>&1 || echo "exit=$?")
[ -z "$VOCAB_OUT" ] || { echo "FAIL: no-glossary push should allow silently; got: $VOCAB_OUT"; exit 1; }
jq -e '.messages[0].content | fromjson | fromjson |
  (.rules | length > 0) and (.rules | contains("R-334") | not) and
  (.project_vocabulary == "")' "$CAPTURE_DIR/request.json" >/dev/null \
  || { echo "FAIL: no-glossary payload must omit R-334 and have empty project_vocabulary"; exit 1; }

# The glossary is read from the target repository even outside the source diff.
mkdir -p docs/superpowers/specs
printf '# Thing design\n\n## Domain vocabulary\nQuasarBasket names the distinctive aggregate root.\n\n## Scope\nUnrelated scope text.\n' \
  > docs/superpowers/specs/2026-01-01-thing-design.md
rm -f "$CAPTURE_DIR/request.json"
VOCAB_OUT=$(env -u CLAUDE_JUDGE_CMD \
  PATH="$CAPTURE_DIR:$PATH" ANTHROPIC_API_KEY="$(printf '%s' fixture key)" \
  CLAUDE_MANIFEST_FILE="$REAL_MANIFEST" \
  CLAUDE_JUDGE_USAGE_LOG="$CAPTURE_DIR/usage.log" bash "$JUDGE" HEAD~1 HEAD 2>&1 || echo "exit=$?")
[ -z "$VOCAB_OUT" ] || { echo "FAIL: glossary push should allow silently; got: $VOCAB_OUT"; exit 1; }
jq -e '.messages[0].content | fromjson | fromjson |
  (.rules | contains("R-334")) and
  (.project_vocabulary | contains("QuasarBasket names the distinctive aggregate root.")) and
  (.project_vocabulary | contains("Unrelated scope text.") | not)' "$CAPTURE_DIR/request.json" >/dev/null \
  || { echo "FAIL: glossary payload must include R-334 and the domain vocabulary section"; exit 1; }
# Truncation must be visible in the payload, not silent. Widening the diff
# filter to *.js, *.mjs and *.vue makes the input budget bite sooner, and a test
# asserting only "the judge was called" passes just as happily when the model
# reasoned about a prefix of the change. These two cases pin both directions so
# a passing suite can never hide that (2026-09-18).
rm -f "$CAPTURE_DIR/request.json"
printf 'export function smallChange(){}\n' >> generate.js
git add generate.js
git commit -q -m "test(fixture): a small judged change for the truncation cases"
UNTRUNCATED_OUT=$(env -u CLAUDE_JUDGE_CMD \
  PATH="$CAPTURE_DIR:$PATH" ANTHROPIC_API_KEY="$(printf '%s' fixture key)" \
  CLAUDE_MANIFEST_FILE="$REAL_MANIFEST" \
  CLAUDE_JUDGE_USAGE_LOG="$CAPTURE_DIR/usage.log" bash "$JUDGE" HEAD~1 HEAD 2>&1 || echo "exit=$?")
[ -z "$UNTRUNCATED_OUT" ] || { echo "FAIL: small-diff push should allow silently; got: $UNTRUNCATED_OUT"; exit 1; }
jq -e '.messages[0].content | fromjson | fromjson |
  (.diff_truncated == false) and (.diff | contains("smallChange"))' "$CAPTURE_DIR/request.json" >/dev/null \
  || { echo "FAIL: a diff inside the budget must be sent whole with diff_truncated false"; exit 1; }

# The same change under a one-hundred-byte budget: the flag must flip, so the
# model is told it is reasoning about a prefix rather than the whole change.
rm -f "$CAPTURE_DIR/request.json"
env -u CLAUDE_JUDGE_CMD \
  PATH="$CAPTURE_DIR:$PATH" ANTHROPIC_API_KEY="$(printf '%s' fixture key)" \
  CLAUDE_MANIFEST_FILE="$REAL_MANIFEST" \
  CLAUDE_JUDGE_DIFF_MAX_BYTES=100 \
  CLAUDE_JUDGE_USAGE_LOG="$CAPTURE_DIR/usage.log" bash "$JUDGE" HEAD~1 HEAD >/dev/null 2>&1 || true
jq -e '.messages[0].content | fromjson | fromjson |
  (.diff_truncated == true) and ((.diff | length) <= 100)' "$CAPTURE_DIR/request.json" >/dev/null \
  || { echo "FAIL: a diff over the budget must be truncated AND flagged diff_truncated true"; exit 1; }

rm -rf "$CAPTURE_DIR"
[ "$GENERATED_FAILURES" -eq 0 ] || exit 1

# The finding line itself reaches stdout, so a CI log names the rule and file.
OUTF=$(CLAUDE_JUDGE_CMD="$S1" bash "$JUDGE" HEAD~1 HEAD 2>/dev/null || echo "exit=$?")
grep -q 'R-315 \[generate.ts\]: vague filename' <<< "$OUTF" || { echo "FAIL: the finding line must reach stdout; got: $OUTF"; exit 1; }

# G1. Under GitHub Actions a warn finding is an annotation.
GH_ERR=$(GITHUB_ACTIONS=true CLAUDE_JUDGE_CMD="$S4c" bash "$JUDGE" HEAD~1 HEAD 2>&1 >/dev/null || true)
grep -q '^::warning::' <<< "$GH_ERR" || { echo "FAIL G1: expected ::warning::, got: $GH_ERR"; exit 1; }

echo "judge-diff.test.sh PASS"
