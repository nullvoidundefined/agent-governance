#!/usr/bin/env bash
# push-golangci-gate.sh: on `git push`, run the bundled enforcement golangci
# config over the module when the outgoing diff touches Go files. Deny the push
# on any violation of the AST-tier rule analogs (R-324 mnd, R-329 nolintlint;
# mapping in enforce/golangci-enforce.yml) that sits on a line the diff adds.
# golangci-lint analyzes packages, not file lists, so the run covers ./... and
# the added-lines filter scopes the deny (--added-only parity, 2026-07-10,
# Ian-approved). Fails OPEN with a stderr note when golangci-lint is absent or
# its output is unparseable (v1/v2 flag drift; see the config header).
# The same run also executes the R-361/R-362 data-access checker
# (enforce/data-access/go/main.go) on the changed .go files; each half fails
# open on its own, so either tool being unavailable skips only that half.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

# shellcheck source=../enforce/resolve-outgoing-base.sh
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" && pwd)"
source "$ENFORCE_DIR/resolve-outgoing-base.sh"

INPUT=$(cat)
RAW_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
CMD="$RAW_CMD"
# Strip git global options so `git --no-pager push` matches like `git push`
# (2026-09-16 audit P2-1; the normalizer lives once in git-invocation.sh),
# then recover which repository the push names so that every query below
# runs against THAT repository (2026-09-18 audit, defect 4).
# -f guard, not `source ... || true`: a failed source aborts the shell under
# set -e regardless of the || (observed 2026-09-16), which is a silent
# fail-open for a guard.
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  # The target is read from the UNSTRIPPED command, because stripping is
  # exactly what throws it away (2026-09-18 audit, defect 4).
  parse_git_target_options "$RAW_CMD" push
fi
grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' <<< "$CMD" || exit 0

# Repo exemption: same allowlist as the other push gates (origin URL per line).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(run_git_on_target diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.go$' || true)
[ -z "$FILES" ] && exit 0

TOP="$(run_git_on_target rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$TOP" ] || exit 0
CONFIG="$ENFORCE_DIR/golangci-enforce.yml"

# The set of file:line pairs the outgoing diff adds; only these can deny.
ADDED=$(run_git_on_target diff -U0 --diff-filter=ACMR "$BASE"..HEAD -- '*.go' 2>/dev/null | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^@@/ {
    split($3, parts, ",")
    start = substr(parts[1], 2) + 0
    count = (length(parts) > 1) ? parts[2] + 0 : 1
    for (i = 0; i < count; i++) print file ":" (start + i)
  }')
[ -z "$ADDED" ] && exit 0

# The two halves choose their tools independently, so a missing golangci-lint
# or an untrusted repo skips only the golangci half and the data-access checker
# still runs, and a missing go toolchain skips only the checker. Each skip is a
# one-line stderr note, never a silent pass.
GOLANGCI=""
if [ -n "${CLAUDE_GOLANGCI_CMD:-}" ]; then
  # Explicit operator override: trusted by definition (test/dev configuration).
  GOLANGCI="$CLAUDE_GOLANGCI_CMD"
elif command -v golangci-lint >/dev/null 2>&1; then
  # SECURITY (2026-07-31 security audit P0): golangci-lint compiles the target
  # tree, and compilation of untrusted Go (cgo directives, toolchain edge
  # cases) is a code-execution surface. Unlike lint-only parsing, this cannot
  # be made safe by config, so the real binary runs ONLY in repos the operator
  # has explicitly trusted (origin URL per line, mirror of exempt-repos.txt).
  TRUSTED_FILE="$HOME/.claude/enforce/gate-trusted-repos.txt"
  ORIGIN_URL=$(run_git_on_target remote get-url origin 2>/dev/null || true)
  if [ -z "$ORIGIN_URL" ] || [ ! -f "$TRUSTED_FILE" ] || ! grep -qxF "$ORIGIN_URL" "$TRUSTED_FILE"; then
    echo "push-golangci-gate: repo not in enforce/gate-trusted-repos.txt, skipping golangci-lint (linting Go requires compiling the tree; add the origin URL to opt in)" >&2
  else
    GOLANGCI="golangci-lint"
  fi
else
  echo "push-golangci-gate: no golangci-lint on PATH, skipping golangci-lint" >&2
fi

# R-361/R-362: the data-access checker is a stdlib go/ast program. It compiles
# only its own main.go from the harness (GOTOOLCHAIN=local, so no toolchain is
# ever downloaded) and PARSES the target files without compiling them, which is
# why it runs in repositories the golangci half does not trust. CLAUDE_GO_CMD
# overrides the go binary for fixtures, mirroring CLAUDE_GOLANGCI_CMD.
GO_BIN="${CLAUDE_GO_CMD:-}"
if [ -z "$GO_BIN" ] && command -v go >/dev/null 2>&1; then GO_BIN="go"; fi
CHECKER_DIR="$ENFORCE_DIR/data-access/go"
[ -n "$GO_BIN" ] || echo "push-golangci-gate: no go on PATH, skipping the R-361/R-362 data-access checker" >&2

[ -n "$GOLANGCI" ] || [ -n "$GO_BIN" ] || exit 0

REPORT=""
if [ -n "$GOLANGCI" ]; then
  # v1 emits JSON with --out-format json; v2 moved to --output.json.path stdout.
  RESULTS=$(cd "$TOP" && $GOLANGCI run --config "$CONFIG" --out-format json ./... 2>/dev/null || true)
  printf '%s' "$RESULTS" | jq -e '.Issues | type == "array"' >/dev/null 2>&1 \
    || RESULTS=$(cd "$TOP" && $GOLANGCI run --config "$CONFIG" --output.json.path stdout ./... 2>/dev/null || true)
  if printf '%s' "$RESULTS" | jq -e '.Issues | type == "array"' >/dev/null 2>&1; then
    REPORT=$(printf '%s' "$RESULTS" | jq -r --arg added "$ADDED" '
      ($added | split("\n") | map(select(length > 0))) as $lines
      | [ .Issues[]
          | (.Pos.Filename + ":" + (.Pos.Line | tostring)) as $key
          | select($lines | index($key))
          | "\($key) \(.FromLinter) \(.Text)" ]
      | .[]' 2>/dev/null || true)
  else
    echo "push-golangci-gate: golangci-lint produced no parseable output, skipping it (fails open)" >&2
  fi
fi

DATA_ACCESS_REPORT=""
if [ -n "$GO_BIN" ] && [ -f "$CHECKER_DIR/main.go" ]; then
  # One compile per gate run into a temp dir, cached by the go build cache
  # after the first; cheaper than `go run` and it keeps file arguments from
  # being read as extra package sources.
  CHECKER_BUILD_DIR=$(mktemp -d)
  CHECKER_BIN="$CHECKER_BUILD_DIR/data-access-go"
  if (cd "$CHECKER_DIR" && GOFLAGS="" GOWORK=off GOTOOLCHAIN=local $GO_BIN build -o "$CHECKER_BIN" main.go) >/dev/null 2>&1; then
    # Changed files that still exist, as an indexed array (bash 3.2 safe).
    CHECK_FILES=()
    while IFS= read -r changed_file; do
      [ -n "$changed_file" ] && [ -f "$TOP/$changed_file" ] && CHECK_FILES+=("$changed_file")
    done <<< "$FILES"
    if [ "${#CHECK_FILES[@]}" -gt 0 ]; then
      FINDINGS=$(cd "$TOP" && "$CHECKER_BIN" "${CHECK_FILES[@]}" 2>/dev/null || true)
      if printf '%s' "$FINDINGS" | jq -e 'type == "array"' >/dev/null 2>&1; then
        DATA_ACCESS_REPORT=$(printf '%s' "$FINDINGS" | jq -r --arg added "$ADDED" '
          ($added | split("\n") | map(select(length > 0))) as $lines
          | [ .[]
              | (.file + ":" + (.line | tostring)) as $key
              | select($lines | index($key))
              | "\($key) \(.rule) \(.message)" ]
          | .[]' 2>/dev/null || true)
      else
        echo "push-golangci-gate: the data-access checker produced no parseable output, skipping it (fails open)" >&2
      fi
    fi
  else
    echo "push-golangci-gate: the data-access checker did not build, skipping it (fails open)" >&2
  fi
  rm -rf "$CHECKER_BUILD_DIR"
fi

if [ -n "$REPORT" ] || [ -n "$DATA_ACCESS_REPORT" ]; then
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  REASON="Go enforcement failed on the outgoing diff. Fix the violations:"
  if [ -n "$REPORT" ]; then
    log_rule_fire "golangci-ast" "push-golangci-gate" "deny"
    REASON="$REASON
golangci-lint (R-324/R-329/R-344 Go analogs; mapping in enforce/golangci-enforce.yml):
$REPORT"
  fi
  if [ -n "$DATA_ACCESS_REPORT" ]; then
    log_rule_fire "data-access-go" "push-golangci-gate" "deny"
    REASON="$REASON
data access (R-361 N+1, R-362 transactions; enforce/data-access/go/main.go):
$DATA_ACCESS_REPORT"
  fi
  jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
