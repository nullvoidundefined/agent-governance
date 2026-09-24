#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# Verifies git-workflow-guard.sh: asks before a push to main and before any PR
# merge (R-514), denies a non-squash merge (R-512) except a rebase of a PR
# labeled bundle whose every commit carries a Refs: trailer, denies any merge
# whose PR body lacks a Codex review section naming the reviewer, the model,
# and a range containing the PR's head commit (R-517), and warns on a cross-cutting
# commit to main (R-511) and a surface-adding commit with no README (R-508),
# whose surface list covers every route the R-607 checklist triggers on.
set -euo pipefail
# Name the failing assertion: under set -e a bare `[ ... ]` exits silently,
# which left a CI failure with nothing but the file name to go on.
trap 'echo "FAIL git-workflow-guard.test.sh line $LINENO: $BASH_COMMAND" >&2' ERR
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/git-workflow-guard.sh"
payload() { jq -nc --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
decision() {
  local out
  out=$(payload "$1" "${2:-/x}" | "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
warning() { payload "$1" "${2:-/x}" | "$HOOK" 2>&1 >/dev/null; }
warns() {   # warns <rule> <command> <repo>
  case "$(warning "$2" "$3")" in *"$1"*) return 0 ;; *) echo "expected a $1 warning for: $2" >&2; return 1 ;; esac
}
silent_on() {   # silent_on <rule> <command> <repo>
  case "$(warning "$2" "$3")" in *"$1"*) echo "unexpected $1 warning for: $2" >&2; return 1 ;; *) return 0 ;; esac
}

# Bundle exception (R-512): `--rebase` passes only for a PR labeled `bundle`
# whose every commit carries a `Refs:` trailer, read from `gh pr view`. The gh
# call is stubbed through CLAUDE_GH_CMD so no fixture reaches GitHub.
STUB_DIR=$(mktemp -d)
# write_gh_stub: writes an executable gh stand-in that prints $2 as the
# `gh pr view` JSON and exits with status $3 (default 0).
write_gh_stub() {
  local stub_path="$STUB_DIR/$1"
  printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\nexit %s\n' "$2" "${3:-0}" >"$stub_path"
  chmod +x "$stub_path"
  printf '%s' "$stub_path"
}
# stubbed_decision: the hook's decision for command $1 with gh stubbed by $2.
stubbed_decision() {
  local out
  out=$(payload "$1" "$STUB_DIR" | CLAUDE_GH_CMD="$2" "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
# stubbed_reason: the hook's decision reason for command $1 with gh stubbed by $2.
stubbed_reason() {
  payload "$1" "$STUB_DIR" | CLAUDE_GH_CMD="$2" "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason'
}
# The PR's head commit, and a `## Codex review` section that is a review
# artefact: it names the reviewer, the model, and a range containing that head
# commit (IAN-286). CODEX_HEAD_OID is what every stub below reports as
# `headRefOid`, so a range line naming 8183e6b covers what would merge.
CODEX_HEAD_OID='8183e6b1f0c4d5a6b7c8d9e0f1a2b3c4d5e6f708'
CODEX_FIELDS='- reviewer: Codex\n- model: gpt-5-codex\n- range: c20e5a8..8183e6b'
CODEX_BODY='## Summary\nWork.\n\n## Codex review\n'"$CODEX_FIELDS"'\n- Two findings: one fixed in abc1234, one answered in the thread.\n\n## Testing\nGreen.'
# write_codex_stub <name> <body>: a gh stand-in answering with <body>, no
# labels or commits, and CODEX_HEAD_OID as the PR's head commit.
write_codex_stub() {
  write_gh_stub "$1" '{"body":"'"$2"'","labels":[],"commits":[],"headRefOid":"'"$CODEX_HEAD_OID"'"}'
}
BUNDLE_OK=$(write_gh_stub bundle-ok '{"body":"'"$CODEX_BODY"'","headRefOid":"'"$CODEX_HEAD_OID"'","labels":[{"name":"bundle"}],"commits":[{"messageHeadline":"feat(a): one","messageBody":"Body.\n\nRefs: IAN-1\nCo-Authored-By: X <x@example.com>"},{"messageHeadline":"fix(b): two","messageBody":"Body.\n\nRefs: IAN-22"}]}')
NO_LABEL=$(write_gh_stub no-label '{"labels":[{"name":"enhancement"}],"commits":[{"messageHeadline":"feat(a): one","messageBody":"Refs: IAN-1"},{"messageHeadline":"fix(b): two","messageBody":"Refs: IAN-2"}]}')
MISSING_REFS=$(write_gh_stub missing-refs '{"labels":[{"name":"bundle"}],"commits":[{"messageHeadline":"feat(a): one","messageBody":"Refs: IAN-1"},{"messageHeadline":"fix(b): two","messageBody":"No trailer here, Refs: IAN-2 inline only"}]}')
GH_FAILS=$(write_gh_stub gh-fails '' 1)
GH_GARBAGE=$(write_gh_stub gh-garbage 'not json')

[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$BUNDLE_OK")" = "ask" ]      # bundle + all Refs: past R-512, R-514 still asks
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$NO_LABEL")" = "deny" ]      # no bundle label
case "$(stubbed_reason 'gh pr merge 42 --rebase' "$NO_LABEL")" in *bundle*) ;; *) echo "no-label deny must name the bundle label" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$MISSING_REFS")" = "deny" ]  # one commit lacks a Refs: trailer line
case "$(stubbed_reason 'gh pr merge 42 --rebase' "$MISSING_REFS")" in *Refs:*) ;; *) echo "missing-refs deny must name the Refs: trailer" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$GH_FAILS")" = "deny" ]      # gh cannot answer: fail closed
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$GH_GARBAGE")" = "deny" ]    # unparseable answer: fail closed
[ "$(stubbed_decision 'gh pr merge --rebase' "$GH_FAILS")" = "deny" ]         # no PR number, gh still consulted
# The PR selector is the first positional argument, never a flag's value, and
# --repo is forwarded: this stub answers as a bundle only for `42 --repo o/r`.
SELECTOR_STUB="$STUB_DIR/selector"
printf '%s\n' '{"body":"'"$CODEX_BODY"'","headRefOid":"'"$CODEX_HEAD_OID"'","labels":[{"name":"bundle"}],"commits":[{"messageHeadline":"a","messageBody":"Refs: IAN-1"}]}' >"$STUB_DIR/bundle-ok.json"
printf '#!/usr/bin/env bash\n[ "$*" = "pr view 42 --repo o/r --json labels,commits,body,headRefName,headRefOid,isCrossRepository,url" ] || exit 1\ncat "%s"\n' "$STUB_DIR/bundle-ok.json" >"$SELECTOR_STUB"
chmod +x "$SELECTOR_STUB"
[ "$(stubbed_decision 'gh pr merge --subject 7 -R o/r --rebase 42' "$SELECTOR_STUB")" = "ask" ]
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$SELECTOR_STUB")" = "deny" ]   # --repo dropped: a different PR
[ "$(stubbed_decision 'gh pr merge 42 --merge' "$BUNDLE_OK")" = "deny" ]      # merge commits stay denied, bundle or not
[ "$(stubbed_decision 'gh pr merge 42 --merge --rebase' "$BUNDLE_OK")" = "deny" ]  # --merge wins over a bundle --rebase
# Short and bundled flags carry the same strategy as the long ones.
[ "$(stubbed_decision 'gh pr merge 42 -r' "$NO_LABEL")" = "deny" ]           # -r is --rebase
[ "$(stubbed_decision 'gh pr merge 42 -dr' "$NO_LABEL")" = "deny" ]          # bundled with -d
[ "$(stubbed_decision 'gh pr merge 42 -r' "$BUNDLE_OK")" = "ask" ]           # -r on a real bundle
[ "$(stubbed_decision 'gh pr merge 42 -m' "$BUNDLE_OK")" = "deny" ]          # -m is --merge
[ "$(stubbed_decision 'gh pr merge 42 -dm' "$BUNDLE_OK")" = "deny" ]         # bundled with -d
# A cd or GH_REPO in the command moves the merge somewhere the hook's gh view
# does not look, so the bundle check cannot vouch for it.
[ "$(stubbed_decision 'cd ../other && gh pr merge 42 --rebase' "$BUNDLE_OK")" = "deny" ]
[ "$(stubbed_decision 'GH_REPO=o/other gh pr merge 42 --rebase' "$BUNDLE_OK")" = "deny" ]
[ "$(stubbed_decision 'GH_REPO=o/other gh pr merge 42 --squash' "$BUNDLE_OK")" = "deny" ]  # R-517 cannot read that PR's body either
# Two commits naming the same ticket are one ticket's history, not a bundle.
SAME_TICKET=$(write_gh_stub same-ticket '{"labels":[{"name":"bundle"}],"commits":[{"messageHeadline":"feat(a): one","messageBody":"Refs: IAN-1"},{"messageHeadline":"fix(a): wip","messageBody":"Refs: IAN-1"}]}')
[ "$(stubbed_decision 'gh pr merge 42 --rebase' "$SAME_TICKET")" = "deny" ]
# A gh that hangs is cut off and denied, never left for the hook timeout (an
# empty hook output is an allow).
SLOW_GH="$STUB_DIR/slow-gh"
printf '#!/usr/bin/env bash\nsleep 30\ncat "%s"\n' "$STUB_DIR/bundle-ok.json" >"$SLOW_GH"
chmod +x "$SLOW_GH"
SLOW_START=$(date +%s)
SLOW_OUT=$(payload 'gh pr merge 42 --rebase' "$STUB_DIR" | CLAUDE_GH_CMD="$SLOW_GH" CLAUDE_GH_TIMEOUT_SECONDS=1 "$HOOK" 2>/dev/null)
[ "$(printf '%s' "$SLOW_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ]
[ $(($(date +%s) - SLOW_START)) -lt 10 ] || { echo "a hung gh must be cut off at the deadline" >&2; exit 1; }
# A merge-commit strategy is denied before any gh call: this stub leaves a
# marker file when consulted, and answers with a body that would pass R-517.
MARKER_GH="$STUB_DIR/marker-gh"
printf '#!/usr/bin/env bash\ntouch "%s"\ncat "%s"\n' "$STUB_DIR/gh-was-called" "$STUB_DIR/bundle-ok.json" >"$MARKER_GH"
chmod +x "$MARKER_GH"
[ "$(stubbed_decision 'gh pr merge 42 --merge' "$MARKER_GH")" = "deny" ]   # wrong strategy (R-512)
[ ! -e "$STUB_DIR/gh-was-called" ] || { echo "a --merge deny must not consult gh" >&2; exit 1; }

# Codex pre-merge review (R-517): every merge, squash included, reads the PR
# body and passes only when a Markdown heading named "Codex review" is followed
# by at least one non-blank line before the next heading.
CODEX_OK=$(write_codex_stub codex-ok ''"$CODEX_BODY"'')
CODEX_LOWER=$(write_codex_stub codex-lower 'Intro.\r\n\r\n### codex review\r\nReviewer: Codex\r\nModel: gpt-5-codex\r\nRange: c20e5a8..8183e6b\r\nNo findings; checked the spec criteria B-1 to B-4.\r\n')
CODEX_MISSING=$(write_codex_stub codex-missing '## Summary\nWork.\n\n## Testing\nGreen.')
CODEX_INLINE=$(write_codex_stub codex-inline '## Summary\nCodex review is pending.')
CODEX_EMPTY=$(write_codex_stub codex-empty '## Codex review\n\n   \n## Testing\nGreen.')
CODEX_NULL=$(write_gh_stub codex-null '{"body":null,"labels":[],"commits":[]}')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_OK")" = "ask" ]       # section present: on to R-514's ask
[ "$(stubbed_decision 'gh pr merge 42 --squash --delete-branch' "$CODEX_LOWER")" = "ask" ]  # any heading level, any case, CRLF
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_MISSING")" = "deny" ]  # no section
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_MISSING")" in *R-517*Codex\ review*) ;; *) echo "missing-section deny must name R-517 and the Codex review section" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_INLINE")" = "deny" ]   # a mention in prose is not a section
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_EMPTY")" = "deny" ]    # a heading with nothing under it
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_NULL")" = "deny" ]     # no body at all
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$GH_FAILS")" = "deny" ]       # gh cannot answer: fail closed
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$GH_GARBAGE")" = "deny" ]     # unparseable answer: fail closed
[ "$(stubbed_decision 'cd ../other && gh pr merge 42 --squash' "$CODEX_OK")" = "deny" ]  # the hook cannot see that PR
[ "$(stubbed_decision 'gh pr merge 42 -r' "$CODEX_OK")" = "deny" ]             # R-517 never waives R-512's bundle check
# A section quoted inside a fenced code block (a PR template's example) is not
# the section.
CODEX_FENCED=$(write_codex_stub codex-fenced '## Summary\nTemplate:\n```\n## Codex review\nexample text\n```\n## Testing\nGreen.')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_FENCED")" = "deny" ]
# One gh view vouches for one PR, so a command that merges two is denied.
[ "$(stubbed_decision 'gh pr merge 42 --squash && gh pr merge 43 --squash' "$CODEX_OK")" = "deny" ]
# --repo placed before the merge subcommand still merges; the hook cannot
# parse that shape, so it is denied (fail closed) rather than allowed unseen.
[ "$(stubbed_decision 'gh pr -R o/r merge 42 --squash' "$CODEX_OK")" = "deny" ]
[ "$(stubbed_decision 'gh --repo o/r pr merge 42 --squash' "$CODEX_OK")" = "deny" ]
[ "$(stubbed_decision 'gh pr --repo=o/r merge 42 --squash' "$CODEX_OK")" = "deny" ]
[ "$(stubbed_decision 'gh pr list --search merge' "$CODEX_OK")" = "none" ]      # not a merge
# Copilot round one: shapes that still merge but slipped past the matcher.
[ "$(stubbed_decision $'gh pr \\\n  merge 42 --squash' "$CODEX_MISSING")" = "deny" ]   # line continuation
[ "$(stubbed_decision $'gh pr \\\n  merge 42 --squash' "$CODEX_OK")" = "ask" ]         # ...and still reaches R-514 when clean
[ "$(stubbed_decision 'env GH_DEBUG=1 gh pr merge 42 --squash' "$CODEX_OK")" = "deny" ] # env wrapper, not parseable
[ "$(stubbed_decision 'command gh pr merge 42 --squash' "$CODEX_OK")" = "deny" ]       # command wrapper
[ "$(stubbed_decision '/usr/local/bin/gh pr merge 42 --squash' "$CODEX_OK")" = "deny" ] # gh by path
[ "$(stubbed_decision 'gh pr merge 42 --squash && gh pr -R o/r merge 43 --squash' "$CODEX_OK")" = "deny" ]  # mixed shapes
[ "$(stubbed_decision 'git commit -m "docs: explain gh pr merge"' "$CODEX_OK")" != "deny" ]  # quoted mention in a message
# A fence closes only on its own delimiter, and an indented code block is not a heading.
CODEX_MIXED_FENCE=$(write_codex_stub codex-mixed-fence '## Summary\n~~~\n```\n## Codex review\nexample\n~~~\n## Testing\nGreen.')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_MIXED_FENCE")" = "deny" ]
CODEX_INDENTED=$(write_codex_stub codex-indented '## Summary\nExample:\n\n    ## Codex review\n    example text\n\n## Testing\nGreen.')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_INDENTED")" = "deny" ]
CODEX_THREE_SPACES=$(write_codex_stub codex-three-spaces '   ## Codex review\n'"$CODEX_FIELDS"'\n- No findings.')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_THREE_SPACES")" = "ask" ]      # up to three spaces is still a heading
# Round-two review: a parenthesized mention is not a merge, and more wrapper
# shapes are recognized.
[ "$(stubbed_decision 'git commit -m "feat(enforce): deny (gh pr merge behind wrappers)"' "$CODEX_MISSING")" != "deny" ]
for wrapped in '\gh pr merge 42 --squash' '"gh" pr merge 42 --squash' 'timeout 30 gh pr merge 42 --squash' \
  'nice gh pr merge 42 --squash' 'bash -c "gh pr merge 42 --squash"' 'eval "gh pr merge 42 --squash"' \
  'echo 42 | xargs gh pr merge --squash' 'sudo -u me gh pr merge 42 --squash' 'env -C /tmp gh pr merge 42 --squash'; do
  [ "$(stubbed_decision "$wrapped" "$CODEX_OK")" = "deny" ] || { echo "wrapped merge not denied: $wrapped" >&2; exit 1; }
done
[ "$(stubbed_decision $'echo x\\\\\ngh pr merge 42 --squash' "$CODEX_MISSING")" = "deny" ]   # an escaped backslash does not join lines
# An HTML comment is not the section, and a fence does not close on a line with trailing text.
CODEX_COMMENTED=$(write_codex_stub codex-commented '## Summary\n\n<!--\n## Codex review\n<reviewer>, <range>, findings\n-->\n\n## Testing\nGreen.')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_COMMENTED")" = "deny" ]
CODEX_FENCE_TRAILING=$(write_codex_stub codex-fence-trailing '```\ncode\n``` trailing\n## Codex review\nreal content\n```')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_FENCE_TRAILING")" = "deny" ]
# Round three: merges are found by a quote-aware shell scan, not a regex, so
# control flow, quoting, and escapes cannot hide one, and a mention inside a
# quoted argument or a heredoc is never read as one.
for hidden in '{ gh pr merge 42 --squash; }' '( gh pr merge 42 --squash )' 'if true; then gh pr merge 42 --squash; fi' \
  'gh "pr" merge 42 --squash' "gh pr 'merge' 42 --squash" '"gh" "pr" "merge" 42 --squash' 'g\h pr merge 42 --squash' \
  'gh pr mer""ge 42 --squash' 'eval gh\ pr\ merge\ 42\ --squash' 'sh -c gh\ pr\ merge\ 42\ --squash' \
  'x=$(gh pr merge 42 --squash)' '{ cd ../other; } && gh pr merge 42 --squash' 'pushd ../other && gh pr merge 42 --squash'; do
  [ "$(stubbed_decision "$hidden" "$CODEX_OK")" = "deny" ] || { echo "hidden merge not denied: $hidden" >&2; exit 1; }
done
for mention in 'GIT_EDITOR=true git commit -m "fix(enforce): gh pr merge wrapper matcher"' \
  'time git commit -m "fix: deny gh pr merge behind wrappers"' \
  "bash -c 'git commit -m \"fix: deny gh pr merge behind wrappers\"'" \
  'env FOO=1 gh pr comment 42 --body "deny gh pr merge behind wrappers"' \
  'echo "; gh pr merge 42 --squash"' \
  $'cat > notes.md <<\'EOF\'\ntimeout 30 gh pr merge 42 --squash\nEOF'; do
  [ "$(stubbed_decision "$mention" "$CODEX_MISSING")" != "deny" ] || { echo "a mention was read as a merge: $mention" >&2; exit 1; }
done
# Inline HTML comments and a `<!--` in a code span do not hide a real section.
CODEX_HEADING_COMMENT=$(write_codex_stub codex-heading-comment '## Codex review <!-- required -->\n'"$CODEX_FIELDS"'\n- No findings.')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_HEADING_COMMENT")" = "ask" ]
CODEX_LINE_COMMENT=$(write_codex_stub codex-line-comment '## Codex review\n'"$CODEX_FIELDS"'\n- No findings. <!-- generated -->')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_LINE_COMMENT")" = "ask" ]
CODEX_CODE_SPAN=$(write_codex_stub codex-code-span '## Codex review\n'"$CODEX_FIELDS"'\n- Fixed the `<!--` handling.\n## Testing\nGreen.')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_CODE_SPAN")" = "ask" ]
# The section is a review artefact, not a ritual heading (IAN-286). It names the
# reviewer that ran, the model it ran on, and the range reviewed; each missing
# line denies. A range that does not contain the PR's head commit denies too: a
# review of an older tree records that a review happened without vouching for
# what would merge, and R-517 wants the second thing.
# codex_artefact <lines>: the JSON-escaped body of a PR whose only section is
# `## Codex review` carrying <lines>. The newlines stay the two characters JSON
# decodes, never real ones, which would not parse.
codex_artefact() {
  printf '%s' '## Codex review\n'"$1"
}
CODEX_NO_REVIEWER=$(write_codex_stub codex-no-reviewer "$(codex_artefact '- model: gpt-5-codex\n- range: c20e5a8..8183e6b\n- No findings.')")
CODEX_NO_MODEL=$(write_codex_stub codex-no-model "$(codex_artefact '- reviewer: Codex\n- range: c20e5a8..8183e6b\n- No findings.')")
CODEX_NO_RANGE=$(write_codex_stub codex-no-range "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- No findings.')")
CODEX_BLANK_REVIEWER=$(write_codex_stub codex-blank-reviewer "$(codex_artefact '- reviewer:\n- model: gpt-5-codex\n- range: c20e5a8..8183e6b\n- No findings.')")
CODEX_STALE_RANGE=$(write_codex_stub codex-stale-range "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: 4f2a1b9..c20e5a8\n- Two HIGH findings, both fixed.')")
CODEX_SHORT_RANGE=$(write_codex_stub codex-short-range "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: c20e5a8..8183e6')")
# Two behaviours the parser documents and the suite did not pin: mutating
# `dots < 2` to `dots < 1` reintroduced a base-less `..<head>`, and deleting
# the trailing-punctuation strip left `c20e5a8..8183e6b.` accepted; both left
# the suite green (R-517 re-review of PR #119).
CODEX_NO_BASE_RANGE=$(write_codex_stub codex-no-base-range "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: ..8183e6b')")
CODEX_PUNCT_RANGE=$(write_codex_stub codex-punct-range "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: c20e5a8..8183e6b.')")
CODEX_FULL_OID=$(write_codex_stub codex-full-oid "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: c20e5a8..'"$CODEX_HEAD_OID"'\n- No findings.')")
CODEX_BOLD_FIELDS=$(write_codex_stub codex-bold-fields "$(codex_artefact '**Reviewer:** Claude subagent (fable), fallback: Codex usage limit reached\n**Model:** fable\n**Range:** c20e5a8..8183e6b\nNo findings; checked B-1 to B-4.')")
CODEX_RANGE_ELSEWHERE=$(write_codex_stub codex-range-elsewhere "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- No findings.\n\n## Testing\n- range: c20e5a8..8183e6b')")
CODEX_NO_HEAD_OID=$(write_gh_stub codex-no-head-oid '{"body":"'"$CODEX_BODY"'","labels":[],"commits":[]}')
# A conforming artefact reaches R-514's ask; the abbreviation may be any length
# from seven characters up to the whole object name, and the labels may be
# bulleted, bold, or bare.
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_FULL_OID")" = "ask" ]
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_BOLD_FIELDS")" = "ask" ]
# Each missing line denies, and the deny names the line that is missing, so the
# reader is told which of the three to add rather than to re-read the rule.
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_NO_REVIEWER")" = "deny" ]
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_NO_REVIEWER")" in *no\ \`reviewer\`\ line*) ;; *) echo "a section with no reviewer line must be denied by name" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_NO_MODEL")" = "deny" ]
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_NO_MODEL")" in *no\ \`model\`\ line*) ;; *) echo "a section with no model line must be denied by name" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_NO_RANGE")" = "deny" ]
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_NO_RANGE")" in *no\ \`range\`\ line*) ;; *) echo "a section with no range line must be denied by name" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_BLANK_REVIEWER")" = "deny" ]   # a label with no value names nobody
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_RANGE_ELSEWHERE")" = "deny" ]  # a range line under another heading is not this section's
# The head commit has to be the range's head ENDPOINT. A hexadecimal run
# anywhere on the line is not evidence of anything: it passes for the head
# commit pasted into prose or a link, and for a range that puts the head in
# the BASE position, which is a review of everything except the head.
CODEX_HEAD_AS_BASE=$(write_codex_stub codex-head-as-base "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: 8183e6b..440aaf4\n- No findings.')")
CODEX_BARE_SHA=$(write_codex_stub codex-bare-sha "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: 8183e6b\n- No findings.')")
CODEX_SHA_IN_PROSE=$(write_codex_stub codex-sha-in-prose "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: read the branch at 8183e6b by hand\n- No findings.')")
CODEX_SHA_IN_LINK=$(write_codex_stub codex-sha-in-link "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: see https://github.com/o/r/commit/8183e6b for what I read\n- No findings.')")
CODEX_URL_RANGE=$(write_codex_stub codex-url-range "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: https://github.com/o/r/compare/c20e5a8..8183e6b\n- No findings.')")
CODEX_TRIPLE_DOT=$(write_codex_stub codex-triple-dot "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: origin/main...8183e6b\n- No findings.')")
CODEX_BACKTICK_RANGE=$(write_codex_stub codex-backtick-range "$(codex_artefact '- reviewer: `Codex`\n- model: `gpt-5-codex`\n- range: `c20e5a8..8183e6b`\n- No findings.')")
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_HEAD_AS_BASE")" = "deny" ]
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_HEAD_AS_BASE")" in *head\ endpoint*) ;; *) echo "a head-in-base-position deny must name the head endpoint" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_BARE_SHA")" = "deny" ]
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_BARE_SHA")" in *range\ expression*) ;; *) echo "a range line with no range expression must be denied by name" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_SHA_IN_PROSE")" = "deny" ]
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_SHA_IN_LINK")" = "deny" ]
# A range expression inside a compare link, a three-dot range, and a range in
# backticks are all real ranges, and backticks are this repository's house
# style for an object name.
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_URL_RANGE")" = "ask" ]
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_TRIPLE_DOT")" = "ask" ]
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_BACKTICK_RANGE")" = "ask" ]
# One PR, one review section. Two headings leave the hook unable to say which
# section describes the state that would merge, and a pair that is complete
# only when read together is not a review of anything.
CODEX_DUPLICATE=$(write_codex_stub codex-duplicate "$(codex_artefact '- reviewer: Codex\n- model: gpt-5-codex\n- range: 4f2a1b9..c20e5a8\n- Two findings.\n\n## Codex review\n- reviewer: Codex\n- model: gpt-5-codex\n- range: c20e5a8..8183e6b\n- No findings.')")
CODEX_SPLIT=$(write_codex_stub codex-split "$(codex_artefact '- reviewer: Codex\n\n## Codex review\n- model: gpt-5-codex\n- range: c20e5a8..8183e6b\n- No findings.')")
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_DUPLICATE")" = "deny" ]
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_DUPLICATE")" in *headings*) ;; *) echo "a duplicate-section deny must name the headings it found" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_SPLIT")" = "deny" ]
# The markup exclusions have something real to suppress: each of these carries
# a complete, current artefact inside markup that is not the PR's own claim.
EXCLUDED_ARTEFACT='- reviewer: Codex\n- model: gpt-5-codex\n- range: c20e5a8..8183e6b\n- No findings.'
CODEX_FENCED_ARTEFACT=$(write_codex_stub codex-fenced-artefact '## Summary\nTemplate:\n```\n## Codex review\n'"$EXCLUDED_ARTEFACT"'\n```\n## Testing\nGreen.')
CODEX_INDENTED_ARTEFACT=$(write_codex_stub codex-indented-artefact '## Summary\nExample:\n\n    ## Codex review\n    - reviewer: Codex\n    - model: gpt-5-codex\n    - range: c20e5a8..8183e6b\n\n## Testing\nGreen.')
CODEX_COMMENTED_ARTEFACT=$(write_codex_stub codex-commented-artefact '## Summary\n\n<!--\n## Codex review\n'"$EXCLUDED_ARTEFACT"'\n-->\n\n## Testing\nGreen.')
CODEX_EXAMPLE_AND_REAL=$(write_codex_stub codex-example-and-real '## Summary\nTemplate:\n```\n## Codex review\n'"$EXCLUDED_ARTEFACT"'\n```\n\n## Codex review\n'"$EXCLUDED_ARTEFACT")
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_FENCED_ARTEFACT")" = "deny" ]
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_INDENTED_ARTEFACT")" = "deny" ]
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_COMMENTED_ARTEFACT")" = "deny" ]
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_EXAMPLE_AND_REAL")" = "ask" ]   # the excluded copy is not a second section
# A stale range is the PR #106 case: the review reported against c20e5a8 while
# the branch had moved to 8183e6b. It denies, and the deny names the head
# commit the range has to cover, so the remedy is to re-run the review rather
# than to retype the line.
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_NO_BASE_RANGE")" = "deny" ] || { echo "a base-less ..<head> is not a range and must deny" >&2; exit 1; }
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_PUNCT_RANGE")" = "ask" ] || { echo "a range with trailing punctuation must still be read" >&2; exit 1; }
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_STALE_RANGE")" = "deny" ]
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_STALE_RANGE")" in *8183e6b*) ;; *) echo "a stale-range deny must name the head commit the range misses" >&2; exit 1 ;; esac
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_SHORT_RANGE")" = "deny" ]      # six characters is too ambiguous to match a head
# The head commit comes from the one gh pr view the hook already makes; a gh
# that does not report it leaves the range uncheckable, which fails closed.
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_NO_HEAD_OID")" = "deny" ]
CODEX_GARBAGE_HEAD=$(write_gh_stub codex-garbage-head '{"body":"'"$CODEX_BODY"'","labels":[],"commits":[],"headRefOid":"not-a-commit"}')
[ "$(stubbed_decision 'gh pr merge 42 --squash' "$CODEX_GARBAGE_HEAD")" = "deny" ]     # a head that is not an object name is no head
case "$(stubbed_reason 'gh pr merge 42 --squash' "$CODEX_NO_HEAD_OID")" in *head\ commit*) ;; *) echo "an unreadable head commit must be denied by name" >&2; exit 1 ;; esac

# Trivial-tier exemption (R-517): a PR with no Codex review section merges only
# when task-start's ledger (.claude/task-tier.json, untracked, in the checkout
# the merge runs from) records the trivial tier for the PR's own head branch,
# the PR belongs to that checkout's origin repository, and its head is not a
# fork. A trivial marker typed into the PR body proves nothing on its own.
TRIVIAL_REPO=$(mktemp -d)
git -C "$TRIVIAL_REPO" init -q
git -C "$TRIVIAL_REPO" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
git -C "$TRIVIAL_REPO" remote add origin https://github.com/o/r.git
git -C "$TRIVIAL_REPO" checkout -q -b fix/typo
printf '.claude/task-tier.json\n' >"$TRIVIAL_REPO/.gitignore"
TIER_SCRIPT="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-tier.sh"
# task-tier.sh requires --ticket above trivial whenever $HOME/.claude/TICKET-TRACKER.json
# exists, so every call runs under a HOME with no tracker; with the real HOME the
# fixture passed in CI and failed on any machine that has a tracker configured.
TRACKERLESS_HOME=$(mktemp -d)
# set_tier <tier>: records <tier> for the checked-out branch through task-start's own script.
set_tier() { (cd "$TRIVIAL_REPO" && HOME="$TRACKERLESS_HOME" bash "$TIER_SCRIPT" set "$1" "fixture reason" >/dev/null 2>&1); }
# trivial_decision: the hook's decision for command $1, run from TRIVIAL_REPO with gh stubbed by $2,
# under a HOME with no .sync-source so the live harness checkout is never scanned.
trivial_decision() {
  local out
  out=$(payload "$1" "$TRIVIAL_REPO" | HOME="$TRACKERLESS_HOME" CLAUDE_GH_CMD="$2" "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
NO_SECTION_FIELDS='"labels":[],"commits":[],"isCrossRepository":false,"url":"https://github.com/o/r/pull/42"'
TRIVIAL_PR=$(write_gh_stub trivial-pr '{"body":"## Summary\nTypo.","headRefName":"fix/typo",'"$NO_SECTION_FIELDS"'}')
FORGED_MARKER=$(write_gh_stub forged-marker '{"body":"## Summary\nTypo.\n\nTier: trivial\n<!-- r517: trivial -->","headRefName":"fix/typo",'"$NO_SECTION_FIELDS"'}')
OTHER_BRANCH_PR=$(write_gh_stub other-branch-pr '{"body":"## Summary\nWork.","headRefName":"feat/big",'"$NO_SECTION_FIELDS"'}')
FORK_PR=$(write_gh_stub fork-pr '{"body":"## Summary\nTypo.","headRefName":"fix/typo","labels":[],"commits":[],"isCrossRepository":true,"url":"https://github.com/o/r/pull/42"}')
OTHER_REPO_PR=$(write_gh_stub other-repo-pr '{"body":"## Summary\nTypo.","headRefName":"fix/typo","labels":[],"commits":[],"isCrossRepository":false,"url":"https://github.com/o/other/pull/42"}')
# No ledger: a forged trivial marker in the body is still denied.
[ "$(trivial_decision 'gh pr merge 42 --squash' "$FORGED_MARKER")" = "deny" ]
[ "$(trivial_decision 'gh pr merge 42 --squash' "$TRIVIAL_PR")" = "deny" ]
# A non-trivial branch is still denied.
set_tier standard
[ "$(trivial_decision 'gh pr merge 42 --squash' "$TRIVIAL_PR")" = "deny" ]
[ "$(trivial_decision 'gh pr merge 42 --squash' "$FORGED_MARKER")" = "deny" ]
# The trivial ledger for this branch exempts the section; R-514 still asks.
set_tier trivial
[ "$(trivial_decision 'gh pr merge 42 --squash' "$TRIVIAL_PR")" = "ask" ]
[ "$(trivial_decision 'gh pr merge 42 --squash' "$CODEX_OK")" = "ask" ]           # a section still passes
# The ledger covers only its own branch, repository, and non-fork head.
[ "$(trivial_decision 'gh pr merge 42 --squash' "$OTHER_BRANCH_PR")" = "deny" ]
[ "$(trivial_decision 'gh pr merge 42 --squash' "$FORK_PR")" = "deny" ]
NO_FORK_FLAG_PR=$(write_gh_stub no-fork-flag-pr '{"body":"## Summary\nTypo.","headRefName":"fix/typo","labels":[],"commits":[],"url":"https://github.com/o/r/pull/42"}')
[ "$(trivial_decision 'gh pr merge 42 --squash' "$NO_FORK_FLAG_PR")" = "deny" ]    # an unknown fork flag is not "not a fork"
[ "$(trivial_decision 'gh pr merge 42 --squash' "$OTHER_REPO_PR")" = "deny" ]
# The exemption never waives R-512 or the fail-closed reads.
[ "$(trivial_decision 'gh pr merge 42 --merge' "$TRIVIAL_PR")" = "deny" ]
[ "$(trivial_decision 'gh pr merge 42 -r' "$TRIVIAL_PR")" = "deny" ]
[ "$(trivial_decision 'gh pr merge 42 --squash' "$GH_FAILS")" = "deny" ]
[ "$(trivial_decision 'cd . && gh pr merge 42 --squash' "$TRIVIAL_PR")" = "deny" ]
# A `git -C` redirect elsewhere in the command never selects whose ledger,
# origin, or PR view the merge is judged by: the merge runs from the payload's
# cwd, whose ledger here records the standard tier.
OTHER_TRIVIAL_REPO=$(mktemp -d)
git -C "$OTHER_TRIVIAL_REPO" init -q
git -C "$OTHER_TRIVIAL_REPO" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
git -C "$OTHER_TRIVIAL_REPO" remote add origin https://github.com/o/r.git
git -C "$OTHER_TRIVIAL_REPO" checkout -q -b fix/typo
printf '.claude/task-tier.json\n' >"$OTHER_TRIVIAL_REPO/.gitignore"
(cd "$OTHER_TRIVIAL_REPO" && HOME="$TRACKERLESS_HOME" bash "$TIER_SCRIPT" set trivial "fixture reason" >/dev/null 2>&1)
git -C "$TRIVIAL_REPO" checkout -q -b feat/next
set_tier standard
[ "$(trivial_decision "git -C $OTHER_TRIVIAL_REPO push origin fix/typo && gh pr merge 42 --squash" "$TRIVIAL_PR")" = "deny" ]
# A later task's ledger overwrote the trivial one: the deny names what the
# ledger now holds, so the overwrite is visible.
TRIVIAL_REASON=$(payload 'gh pr merge 42 --squash' "$TRIVIAL_REPO" | CLAUDE_GH_CMD="$TRIVIAL_PR" "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$TRIVIAL_REASON" in *standard*feat/next*) ;; *) echo "trivial deny must name the ledger's tier and branch: $TRIVIAL_REASON" >&2; exit 1 ;; esac
rm -rf "$OTHER_TRIVIAL_REPO"
printf 'not json' >"$TRIVIAL_REPO/.claude/task-tier.json"
TRIVIAL_REASON=$(payload 'gh pr merge 42 --squash' "$TRIVIAL_REPO" | CLAUDE_GH_CMD="$TRIVIAL_PR" "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$TRIVIAL_REASON" in *unreadable\ ledger*) ;; *) echo "an unparseable ledger must be named as unreadable, not absent: $TRIVIAL_REASON" >&2; exit 1 ;; esac
git -C "$TRIVIAL_REPO" checkout -q fix/typo
set_tier trivial
# A ledger committed to the branch is not task-start's session state.
rm -f "$TRIVIAL_REPO/.gitignore"
git -C "$TRIVIAL_REPO" add .claude/task-tier.json
git -C "$TRIVIAL_REPO" -c user.email=t@example.com -c user.name=T commit -q -m "ledger"
[ "$(trivial_decision 'gh pr merge 42 --squash' "$TRIVIAL_PR")" = "deny" ]
rm -rf "$TRIVIAL_REPO"
# Cross-repository sessions (IAN-350): a session whose cwd is another
# repository merges by URL, and its cwd checkout holds no ledger for the PR. The
# hook then finds the worktree checked out on the PR's head branch among the
# worktrees of the cwd repository and of the repository ~/.claude/.sync-source
# names, and applies the unchanged ledger, branch, origin, and fork checks there.
# fixture_repo <owner/repo>: prints a fresh repository on main with one commit and that GitHub origin.
fixture_repo() {
  local repo
  repo=$(mktemp -d)
  git -C "$repo" init -q --initial-branch=main
  git -C "$repo" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
  git -C "$repo" remote add origin "https://github.com/$1.git"
  printf '%s' "$repo"
}
# add_trivial_worktree <repo>: adds a worktree of <repo> on fix/typo whose ledger records trivial, prints its path.
add_trivial_worktree() {
  local worktree
  worktree="$(mktemp -d)/fix-typo"
  git -C "$1" worktree add -q -b fix/typo "$worktree"
  (cd "$worktree" && HOME="$TRACKERLESS_HOME" bash "$TIER_SCRIPT" set trivial "fixture reason" >/dev/null 2>&1)
  printf '%s' "$worktree"
}
# sync_home <repo>: prints a HOME whose .claude/.sync-source names <repo>.
sync_home() {
  local home
  home=$(mktemp -d)
  mkdir -p "$home/.claude"
  printf '%s\n' "$1" >"$home/.claude/.sync-source"
  printf '%s' "$home"
}
# cross_decision <cwd> <home> <gh stub>: the decision for merging the PR by URL from <cwd> under <home>.
cross_decision() {
  local out
  out=$(payload 'gh pr merge https://github.com/o/r/pull/42 --squash' "$1" | HOME="$2" CLAUDE_GH_CMD="$3" "$HOOK" 2>/dev/null)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
GOVERNANCE_REPO=$(fixture_repo o/r)
GOVERNANCE_WORKTREE=$(add_trivial_worktree "$GOVERNANCE_REPO")
SESSION_REPO=$(fixture_repo o/template)
GOVERNANCE_HOME=$(sync_home "$GOVERNANCE_REPO")
# The #127 case: cwd is another repository, the PR's worktree belongs to the sync source.
[ "$(cross_decision "$SESSION_REPO" "$GOVERNANCE_HOME" "$TRIVIAL_PR")" = "ask" ]
# The same merge with no sync source to scan finds no ledger and denies.
[ "$(cross_decision "$SESSION_REPO" "$TRACKERLESS_HOME" "$TRIVIAL_PR")" = "deny" ]
# From the repository's main checkout, its own worktree on the head branch is found.
[ "$(cross_decision "$GOVERNANCE_REPO" "$TRACKERLESS_HOME" "$TRIVIAL_PR")" = "ask" ]
# A fork PR and a PR on a branch no worktree holds still deny.
[ "$(cross_decision "$SESSION_REPO" "$GOVERNANCE_HOME" "$FORK_PR")" = "deny" ]
[ "$(cross_decision "$SESSION_REPO" "$GOVERNANCE_HOME" "$OTHER_BRANCH_PR")" = "deny" ]
# A trivial ledger on the head branch in a worktree of a different repository denies.
FOREIGN_REPO=$(fixture_repo o/other)
FOREIGN_WORKTREE=$(add_trivial_worktree "$FOREIGN_REPO")
[ "$(cross_decision "$SESSION_REPO" "$(sync_home "$FOREIGN_REPO")" "$TRIVIAL_PR")" = "deny" ]
[ "$(cross_decision "$FOREIGN_REPO" "$TRACKERLESS_HOME" "$TRIVIAL_PR")" = "deny" ]
# A ledger in the head-branch worktree that names another branch denies.
jq '.branch = "fix/other"' "$GOVERNANCE_WORKTREE/.claude/task-tier.json" >"$GOVERNANCE_WORKTREE/ledger.tmp"
mv "$GOVERNANCE_WORKTREE/ledger.tmp" "$GOVERNANCE_WORKTREE/.claude/task-tier.json"
[ "$(cross_decision "$SESSION_REPO" "$GOVERNANCE_HOME" "$TRIVIAL_PR")" = "deny" ]
# A ledger committed to the head branch is not task-start's session state.
(cd "$GOVERNANCE_WORKTREE" && HOME="$TRACKERLESS_HOME" bash "$TIER_SCRIPT" set trivial "fixture reason" >/dev/null 2>&1)
[ "$(cross_decision "$SESSION_REPO" "$GOVERNANCE_HOME" "$TRIVIAL_PR")" = "ask" ]
git -C "$GOVERNANCE_WORKTREE" add -f .claude/task-tier.json
git -C "$GOVERNANCE_WORKTREE" -c user.email=t@example.com -c user.name=T commit -q -m "ledger"
[ "$(cross_decision "$SESSION_REPO" "$GOVERNANCE_HOME" "$TRIVIAL_PR")" = "deny" ]
rm -rf "$GOVERNANCE_REPO" "$(dirname "$GOVERNANCE_WORKTREE")" "$SESSION_REPO" "$GOVERNANCE_HOME" "$FOREIGN_REPO" "$(dirname "$FOREIGN_WORKTREE")"
# Round four: a merge fed to a shell on stdin, a backtick substitution, and a
# merge spelled through an expansion are unreadable, so they deny.
for hidden in $'bash <<\'EOF\'\ngh pr merge 42 --squash\nEOF' $'sh -s <<EOF\ngh pr merge 42 --squash\nEOF' \
  'echo "gh pr merge 42 --squash" | bash' 'x=`gh pr merge 42 --squash`' "gh pr \$'merge' 42 --squash" \
  'gh pr mer${x:-}ge 42 --squash' 'gh pr ${m:-merge} 42 --squash' 'g=gh; $g pr merge 42 --squash' \
  'cmd="gh pr merge 42 --squash"; $cmd'; do
  [ "$(stubbed_decision "$hidden" "$CODEX_OK")" = "deny" ] || { echo "FAIL: hidden merge not denied: $hidden" >&2; exit 1; }
done
# The flags come from the merge that runs, never from a quoted mention before it.
[ "$(stubbed_decision "echo 'x gh pr merge 41 y'; gh pr merge 42 --merge" "$CODEX_OK")" = "deny" ]
for mention in 'git merge highlight-branch' 'echo "through merged"' 'bash scripts/run.sh --gh-merge-check'; do
  [ "$(stubbed_decision "$mention" "$CODEX_MISSING")" != "deny" ] || { echo "FAIL: a mention was read as a merge: $mention" >&2; exit 1; }
done
# With the shell scan helper missing, the hook still denies a real merge and
# leaves an ordinary command alone.
NO_HELPER_HOOKS=$(mktemp -d)
cp "$CLAUDE_HARNESS_ROOT"/hooks/*.sh "$NO_HELPER_HOOKS/"
rm -f "$NO_HELPER_HOOKS/shell-command-tokens.sh"
no_helper_decision() {
  local out
  out=$(payload "$1" "$STUB_DIR" | CLAUDE_GH_CMD="$CODEX_OK" bash "$NO_HELPER_HOOKS/git-workflow-guard.sh" 2>/dev/null)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
[ "$(no_helper_decision 'gh pr merge 42 --squash')" = "deny" ]
[ "$(no_helper_decision 'git merge highlight-branch')" = "none" ]
[ "$(no_helper_decision 'echo "through merged"')" = "none" ]
rm -rf "$NO_HELPER_HOOKS"
[ "$(decision 'gh pr view 42')" = "none" ]                 # read-only gh call untouched

# Fixture repo on main, with a remote-free push and a feature branch to compare.
REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
mkdir -p "$REPO/src/routes" "$REPO/src/handlers" "$REPO/src/services"
: >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "chore: seed"

[ "$(decision 'git push' "$REPO")" = "ask" ]                    # implicit target is main (R-514)
[ "$(decision 'git push origin main' "$REPO")" = "ask" ]        # explicit target
[ "$(decision 'git push origin HEAD:main' "$REPO")" = "ask" ]   # refspec form
[ "$(decision 'git push origin HEAD' "$REPO")" = "ask" ]         # HEAD resolves to the checked-out branch
[ "$(decision 'git push origin refs/heads/main' "$REPO")" = "ask" ]     # fully qualified ref
[ "$(decision 'git push origin +main' "$REPO")" = "ask" ]               # force marker on the refspec
[ "$(decision "git -C $REPO push origin main" /tmp)" = "ask" ]          # -C form names the repo, not the cwd
# Every other shape that names a target repository (2026-09-18 audit, defect 4).
# The old extraction read `-C` alone, from the FIRST git invocation, with an
# unquoted path, so each of these was judged against the cwd instead.
[ "$(decision "git --work-tree $REPO push origin main" /tmp)" = "ask" ]
[ "$(decision "git --work-tree=$REPO push origin main" /tmp)" = "ask" ]
[ "$(decision "git -c core.pager=cat -C $REPO push origin main" /tmp)" = "ask" ]
[ "$(decision "git -C /nowhere fetch && git -C $REPO push origin main" /tmp)" = "ask" ]
QUOTED_REPO="$REPO with spaces"
cp -R "$REPO" "$QUOTED_REPO"
[ "$(decision "git -C \"$QUOTED_REPO\" push origin main" /tmp)" = "ask" ]
[ "$(decision 'git push origin feature/scoring' "$REPO")" = "ask" ] && exit 1  # a feature branch is not gated
# The governance repo is exempt wherever it lives: identity is the origin
# remote (repo-identity.sh), so the fixture builds a sandbox repo carrying the
# governance remote instead of depending on the real checkout's path (that
# path-coupled form went stale the first time the repo moved, 2026-09-17).
GOV_REPO=$(cd "$(mktemp -d)" && pwd -P)
git -C "$GOV_REPO" init -q -b main
git -C "$GOV_REPO" remote add origin "https://github.com/nullvoidundefined/agent-governance.git"
[ "$(decision 'git push' "$GOV_REPO")" = "none" ]  # global repo exempt (by origin remote): R-106 owns its pushes

# R-511: five files across three directories staged on main.
for path in src/routes/jobs.ts src/routes/users.ts src/handlers/scoreJob.ts src/services/score.ts src/services/rank.ts; do
  : >"$REPO/$path"
done
git -C "$REPO" add src
warns R-511 'git commit -m "refactor: regroup"' "$REPO"
# R-508: the staged routes are new surface and no README is staged.
warns R-508 'git commit -m "feat: scoring"' "$REPO"
# Staging the README silences R-508 but not R-511.
printf 'docs\n' >"$REPO/README.md"
git -C "$REPO" add README.md
silent_on R-508 'git commit -m "feat: scoring"' "$REPO"
warns R-511 'git commit -m "feat: scoring"' "$REPO"

# A path holding an apostrophe must not crash the advisory pass.
: >"$REPO/src/services/o'brien.ts"
git -C "$REPO" add "src/services/o'brien.ts"
warns R-511 'git commit -m "refactor: regroup"' "$REPO"
git -C "$REPO" rm -q --cached "src/services/o'brien.ts"
rm -f "$REPO/src/services/o'brien.ts"

# A narrow commit on a feature branch warns about neither.
git -C "$REPO" commit -qm "feat: scoring"
git -C "$REPO" checkout -q -b feature/next
: >"$REPO/src/services/notify.ts"
git -C "$REPO" add src/services/notify.ts
[ -z "$(warning 'git commit -m "feat: notify"' "$REPO")" ]
git -C "$REPO" commit -qm "feat: notify"

# IAN-118: R-508 covers the Nuxt, Nitro, and FastAPI surfaces, and agrees with
# the R-607 checklist: every path the checklist's built-in triggers treat as a
# new route is a surface here too. A plain Vue component is not a surface.
# stage_only <path>: stages exactly one new file, nothing else.
stage_only() {
  mkdir -p "$REPO/$(dirname "$1")"; : >"$REPO/$1"; git -C "$REPO" add -- ":(literal)$1"
}
# unstage_path <path>: removes the file staged by stage_only.
unstage_path() {
  git -C "$REPO" rm -q --cached -- ":(literal)$1"; rm -f "$REPO/$1"
}
for surface in 'app/pages/index.vue' 'app/pages/trips/[id].vue' 'server/api/trips.get.ts' \
  'server/routes/health.ts' 'app/routers/trips.py' 'apps/client/web/app/pages/about.vue' \
  'app/trips/page.tsx' 'src/app/api/trips/route.ts'; do
  stage_only "$surface"
  warns R-508 'git commit -m "feat: surface"' "$REPO"
  unstage_path "$surface"
done
for non_surface in 'app/components/TripCard.vue' 'app/composables/useTrips.ts' 'app/services/trips.py'; do
  stage_only "$non_surface"
  silent_on R-508 'git commit -m "feat: component"' "$REPO"
  unstage_path "$non_surface"
done
# Parity: read the checklist's built-in triggers and require the guard to fire
# on each sample path any of them matches.
CHECKLIST_TRIGGERS=$(sed -n '/^BUILTIN_TRIGGERS=(/,/^)/p' "$CLAUDE_HARNESS_ROOT/enforce/require-feature-checklist.sh" | sed -n "s/^  '\(.*\)'$/\1/p")
TRIGGER_ARGS=()
while IFS= read -r trigger; do TRIGGER_ARGS+=(-e "$trigger"); done <<<"$CHECKLIST_TRIGGERS"
[ "${#TRIGGER_ARGS[@]}" -ge 10 ]
PARITY_CHECKED=0
for sample in 'app/pages/trips/index.vue' 'server/api/users/[id].post.ts' 'server/routes/feed.xml.ts' \
  'app/routers/users.py' 'src/routes/trips.ts' 'src/handlers/trips.js' 'app/(shop)/cart/page.jsx' \
  'src/app/api/health/route.js' 'app/components/Nav.vue'; do
  # A here-string, not a pipe: a SIGPIPE under pipefail would skip a sample.
  grep -qE "${TRIGGER_ARGS[@]}" <<<"$sample" || continue
  PARITY_CHECKED=$((PARITY_CHECKED + 1))
  stage_only "$sample"
  warns R-508 'git commit -m "feat: parity"' "$REPO"
  unstage_path "$sample"
done
[ "$PARITY_CHECKED" -eq 8 ]
rm -rf "$REPO"

echo "git-workflow-guard.test.sh PASS"
