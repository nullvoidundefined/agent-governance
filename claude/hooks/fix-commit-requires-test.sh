#!/usr/bin/env bash
# fix-commit-requires-test.sh
#
# PreToolUse hook for Claude Code Bash tool. Inspects `git commit -m`
# calls and blocks any whose subject starts with a fix-family prefix
# (fix:, fix(, bug:, bugfix:, hotfix:) unless the staged diff includes
# at least one test file. Enforces R-403 in ~/.claude/CLAUDE.md.
#
# Why this exists: R-403 says every bug-fix commit must contain both
# the failing test and the fix in the same commit. Without enforcement,
# the rule is honor-system and decays under pressure. "Optimism-driven
# debugging" (push and hope) is the specific failure mode this hook
# catches.
#
# How it works: Claude Code feeds hook stdin as JSON with shape
# { "tool_name": "Bash", "tool_input": { "command": "..." } }. This
# script extracts .tool_input.command, detects `git commit -m`, extracts
# the subject line, checks whether it matches a fix-family prefix, and
# if so runs `git diff --cached --name-only` to verify at least one
# staged file matches the test globs.
#
# Matched prefixes: fix:, fix(, bug:, bugfix:, hotfix:
# Matched test globs: *.test.*, *.spec.*, e2e/**, __tests__/**, test/**,
# tests/**, test_*.py, *_test.py, conftest.py, spec/**, *_spec.rb, *_test.go
#
# Editor-based commits (no -m) are NOT blocked because the subject is
# not available at PreToolUse time. R-403 enforcement for those relies
# on the honor system. This is an acknowledged gap; most Claude-driven
# commits use -m.
#
# Heredoc commits are supported: `git commit -m "$(cat <<'EOF' ... EOF)"`.
# The subject is extracted as the first non-empty line of the heredoc
# body. Without this support, the hook saw the subject as `$(cat` and
# silently passed every heredoc fix: commit through (the canonical
# commit pattern in this repo and many others).
#
# The hook also skips any `git commit` whose subject is docs:, chore:,
# refactor:, style:, test:, feat:, ci:, perf:, or build:. These are
# the expected non-fix categories and the relabel-to-escape path from
# R-403 ("If the fix genuinely needs no test, relabel as docs: or
# chore:"). The hook trusts the relabel at face value; R-403 expects
# the user to not abuse it, and the engineering audit retroactively
# catches relabels that hid gaps.
#
# To test manually:
#   echo '{"tool_input":{"command":"git commit -m \"fix: broken thing\""}}' | ~/.claude/hooks/fix-commit-requires-test.sh
# (With no staged test file: should print JSON with permissionDecision=deny.)
#
#   echo '{"tool_input":{"command":"git commit -m \"chore: tidy\""}}' | ~/.claude/hooks/fix-commit-requires-test.sh
# (Should print nothing and exit 0.)

# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Only care about `git commit -m "..."` invocations.
if ! grep -qE '(^|;|&|\|)[[:space:]]*git[[:space:]]+commit[[:space:]]' <<< "$CMD"; then
  exit 0
fi

# Extract the subject from `-m "..."` or `-m '...'`, from a `-m "$(cat <<'EOF'
# ... EOF)"` body, or from `-F -` fed by a heredoc. The last form was invisible
# until 2026-09-17 (audit P2-7): it carries the subject in the command text
# exactly like the others, it is the form the agents working in this repo
# actually use, and while the extractor keyed on -m alone R-403 was inert for
# every one of those commits. `-F <file>` stays out of reach, because the
# message is on disk and not in the command. Perl is used because grep is
# line-oriented and cannot see through a multi-line heredoc.
#
# Two properties this extractor has to hold, both reported on PR #8. It reads
# only from the `git commit` token onward and only as far as the first command
# separator, so a `-m` or a heredoc belonging to some other command in the same
# Bash call is neither mistaken for this commit's message (a false deny) nor
# accepted in place of it (a silent R-403 bypass). And it returns the first
# non-empty line for every form, not just the heredoc ones: the `-m` branch used
# to return the whole message, so a body line or trailer starting with `fix:`
# made a docs: commit deny.
SUBJECT=$(printf '%s' "$CMD" | perl -0777 -ne '
  sub first_line {
    my ($text) = @_;
    for my $line (split /\n/, $text) {
      return $line if $line !~ /^\s*$/;
    }
    return "";
  }
  exit unless /(git\s+commit\b.*)/s;
  my $tail = $1;
  if ($tail =~ /\Agit\s+commit\b[^\n;&|]*?-m\s+(["'\''])((?:(?!\1).)*)\1/s) {
    my $body = $2;
    if ($body =~ /\$\(\s*cat\s+<<-?\s*['\''"]?(\w+)['\''"]?[ \t]*\n(.*?)\n[ \t]*\1[ \t]*\)/s) {
      print first_line($2);
    } else {
      print first_line($body);
    }
  } elsif ($tail =~ /\Agit\s+commit\b[^\n;&|]*?-F\s+-[^\n;&|]*?<<-?\s*['\''"]?(\w+)['\''"]?[ \t]*\n(.*?)\n[ \t]*\1[ \t]*$/ms) {
    print first_line($2);
  }
')
if [ -z "$SUBJECT" ]; then
  exit 0
fi

# Only enforce on fix-family prefixes.
if ! grep -qE '^(fix:|fix\(|bug:|bugfix:|hotfix:)' <<< "$SUBJECT"; then
  exit 0
fi

# Check staged files, UNIONED with paths named in `git add` segments of the
# same command: a chained `git add X && git commit -m "fix: ..."` runs this
# hook before anything is staged, so the index snapshot alone is bypassable
# (2026-07-31 engineering audit P1). -A/--all/. arguments fall back to the
# working-tree change list.
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
ADD_SEGMENTS=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+add[[:space:]]+[^;&|]+' || true)
if [ -n "$ADD_SEGMENTS" ]; then
  ADD_PATHS=$(printf '%s\n' "$ADD_SEGMENTS" | sed -E 's/^git[[:space:]]+add[[:space:]]+//' | tr ' ' '\n' | grep -v '^$' || true)
  if grep -qE '^(-A|--all|\.)$' <<< "$ADD_PATHS"; then
    ADD_PATHS="$ADD_PATHS
$(git status --porcelain 2>/dev/null | awk '{print $NF}')"
  fi
  STAGED="$STAGED
$ADD_PATHS"
fi
if [ -z "$(printf '%s' "$STAGED" | tr -d '[:space:]')" ]; then
  exit 0
fi

# Match against the R-403 test globs. Python: tests/ trees (R-313) plus the
# pytest filename conventions test_*.py and *_test.py. Ruby: spec/ trees and
# *_spec.rb (RSpec). Go: co-located *_test.go (R-313 Go exception).
if grep -qE '(\.test\.|\.spec\.|^e2e/|/e2e/|^__tests__/|/__tests__/|^tests?/|/tests?/|(^|/)test_[^/]*\.py$|_test\.py$|(^|/)conftest\.py$|^spec/|/spec/|_spec\.rb$|_test\.go$)' <<< "$STAGED"; then
  # A test file is present; commit may proceed.
  exit 0
fi

# No test file staged. Block with a reason citing R-403.
LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-403" "fix-commit-requires-test" "deny"
jq -n --arg subject "$SUBJECT" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("fix-commit-requires-test hook BLOCKED this commit: the subject \"" + $subject + "\" starts with a fix-family prefix (fix:, fix(, bug:, bugfix:, or hotfix:) but the staged diff contains no test file. Rule R-403 in ~/.claude/CLAUDE.md requires every bug-fix commit to include both the failing test and the fix in the same commit. The path: (1) write a test that reproduces the failure, (2) confirm it FAILS, (3) make the smallest change that addresses the root cause, (4) confirm the test PASSES, (5) stage BOTH the test and the fix, (6) commit. If this commit genuinely needs no test change (e.g., a pure docs fix), relabel the subject as docs: or chore: instead. Be honest about the relabel: R-403 says the check is whether relabeling would hide a gap a future auditor would catch. If yes, keep fix: and add the test.")
  }
}'

exit 0
