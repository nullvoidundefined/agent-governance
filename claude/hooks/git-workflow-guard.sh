#!/usr/bin/env bash
# git-workflow-guard.sh: the R-5xx rules that are decidable from a git or gh
# command plus the index. One PreToolUse(Bash) hook, six rules:
#   R-514  a push whose target branch is main/master asks first, and so does
#          `gh pr merge` (authorization is per turn, never standing)
#   R-512  `gh pr merge --merge` (`-m`) is denied, and so is `--rebase` (`-r`)
#          unless the PR is a bundle (the `bundle` label, a distinct `Refs:`
#          trailer on every commit, read from `gh pr view`); feature branches
#          squash-merge into one commit per feature
#   R-517  `gh pr merge` is denied unless the PR body, read from `gh pr view`,
#          carries a Markdown heading named "Codex review" whose section names
#          the `reviewer` that ran, the `model` it ran on, and the `range` it
#          read as a `<base>..<head>` expression whose head endpoint is the
#          head commit the same `gh pr view` reports (the blocking pre-merge
#          Codex review, proved by its artefact rather than by the heading),
#          and only one such section exists, or task-start's untracked
#          ledger records the trivial tier for the PR's own head branch in the
#          same origin repository, read in the merge's checkout or in a local
#          worktree on that head branch (never a body marker)
#   R-109  `gh pr merge` of a PR whose range (merge base with
#          origin/<baseRefName> .. headRefOid) touches a security surface, as
#          hooks/security-surface.sh decides, is denied unless the PR body
#          carries one `## Security review` section with a `reviewer`, a
#          `model` equal to securityReviewModel in
#          enforce/security-review-model.json, and a `range` whose head
#          endpoint is the PR head; a missing detector, an unresolvable range,
#          or a failed detector counts as security-touching (fail closed).
#          The section's findings are then read: a `Nothing found:` line
#          naming no values after `tried` denies (B-16); a findings table
#          (# | Severity | Control | Source | Worst value tried | Evidence |
#          Fix | Status) that cannot be parsed denies, and so does any `open`
#          row; a table with rows needs an `artefact` line whose file, read at
#          the PR head, is JSON grading every row's `#` at a severity no
#          higher than the table's (B-10); `fixed <sha>` must name a commit in
#          the PR range (B-11); and a `waived by owner <date>` row, when
#          nothing denies, turns the merge into an R-109 ask naming each
#          waived row, so the owner's prompt is the waiver channel (B-12)
#   R-511  advisory: a cross-cutting change (5+ files, 3+ directories) landing
#          directly on main wants its own branch
#   R-508  advisory: a commit that adds a user-facing surface or changes setup
#          and touches no README
#
# The global repo is exempt from the two main-branch rules: main IS its
# working branch, and its pushes are already gated by global-repo-push-guard
# for R-106. Recognition is delegated to repo-identity.sh (origin remote
# URL, or the legacy ~/.claude toplevel); when the helper cannot be
# sourced the repo is treated as non-exempt, which fails toward asking.
# Advisories print to stderr and never block.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL" = "Bash" ] || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
# A backslash-newline is a line continuation: join it first, so a command
# split across lines (`gh pr \<newline> merge 42`) reads as the one command
# the shell runs. An escaped backslash before the newline (`echo x\\`) is a
# literal backslash and ends the line, so it is set aside before the join and
# restored after it.
LINE_CONTINUATION=$'\\\n'
ESCAPED_BACKSLASH_NEWLINE=$'\\\\\n'
ESCAPED_BACKSLASH_MARK=$'\\\\\001'
NEWLINE_CHARACTER=$'\n'
# bash 5.2 turns on patsub_replacement, which processes backslashes and `&`
# in a replacement string; that turned the two-backslash mark back into a
# continuation on the Linux runners. Quoting the replacement is no fix, since
# bash 3.2 on macOS then inserts the quotes literally, so the option is
# switched off instead (bash before 5.2 has no such option and ignores this).
shopt -u patsub_replacement 2>/dev/null || true
CMD="${CMD//"$ESCAPED_BACKSLASH_NEWLINE"/$ESCAPED_BACKSLASH_MARK}"
CMD="${CMD//"$LINE_CONTINUATION"/ }"
CMD="${CMD//$'\001'/$NEWLINE_CHARACTER}"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD="$PWD"
# The directory `gh pr merge` itself runs from. A `git -C`/`--work-tree` on a
# push or commit elsewhere in the command redirects CWD below for the git
# rules, but never selects which PR view, ledger, or origin a merge is judged by.
MERGE_CWD="$CWD"

# `git -C <path> push` and `git --no-pager commit` are the same actions with a
# global option in front, and matching on adjacency alone lets them through.
# Strip the whole option class via git-invocation.sh (2026-09-16 audit P2-1),
# and let the repository-selecting options redirect the repository the rest of
# this hook inspects.
#
# The redirect used to be a regex that read `-C` alone, from the first git
# invocation in the command, with an unquoted path. `--work-tree`, a quoted
# path, and a `git -C /a fetch && git -C /b push` pairing all slipped past it
# and left the hook judging the ambient repository (2026-09-18 audit, defect
# 4). The shared parser in git-invocation.sh covers all of those shapes, so
# the extraction here is now one call against the UNSTRIPPED command.
# -f guard, not `source ... || true`: a failed source aborts the shell under
# set -e regardless of the || (observed 2026-09-16), a silent fail-open.
RAW_CMD="$CMD"
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
if [ -f "$GIT_INVOCATION_HELPER" ]; then
  source "$GIT_INVOCATION_HELPER"
  CMD=$(printf '%s' "$CMD" | strip_git_global_options)
  GIT_DIRECTORY=""
  for subcommand in push commit; do
    parse_git_target_options "$RAW_CMD" "$subcommand"
    GIT_DIRECTORY=$(read_git_target_directory)
    [ -n "$GIT_DIRECTORY" ] && break
  done
else
  # Fallback keeps the pre-helper coverage rather than none.
  CMD=$(printf '%s' "$CMD" | sed -E 's/git([[:space:]]+(-C|-c)[[:space:]]+[^[:space:];&|]+)+/git/g')
  GIT_DIRECTORY=$(printf '%s' "$RAW_CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' | head -1 | awk '{print $3}' || true)
fi
if [ -n "$GIT_DIRECTORY" ]; then
  case "$GIT_DIRECTORY" in /*) CWD="$GIT_DIRECTORY" ;; *) CWD="$CWD/$GIT_DIRECTORY" ;; esac
fi

# A `gh pr merge` may follow leading environment assignments
# (`GH_REPO=o/r gh pr merge ...`), which run the same merge.
GH_MERGE_PATTERN='(^|[;&|])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
# Whether a command runs a merge at all is decided by a quote-aware shell scan
# (shell-command-tokens.sh), never by a regex over the raw text: a regex
# missed merges hidden by braces, subshells, control flow, quoting, and
# escapes, and read merges into quoted commit messages and heredocs. The scan
# runs only when a copy of the command with quotes and backslashes removed
# mentions both gh and merge, so ordinary commands pay nothing for it. A
# missing helper is treated as a merge the hook cannot read, which denies.
SHELL_TOKENS_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-tokens.sh"
IS_SHELL_TOKENS_LOADED=0
if [ -f "$SHELL_TOKENS_HELPER" ]; then
  # shellcheck source=shell-command-tokens.sh
  source "$SHELL_TOKENS_HELPER" && IS_SHELL_TOKENS_LOADED=1
fi
UNQUOTED_CMD="${CMD//[\"\'\\]/}"
IS_MERGE_MENTIONED=0
[[ "$UNQUOTED_CMD" == *gh* && "$UNQUOTED_CMD" == *merge* ]] && IS_MERGE_MENTIONED=1
# A `merge` word built by expansion (`gh pr mer${x}ge`) never spells "merge",
# so gh and pr beside a `$` or backtick also start the scan.
IS_MERGE_CANDIDATE="$IS_MERGE_MENTIONED"
[[ "$UNQUOTED_CMD" == *gh* && "$UNQUOTED_CMD" == *pr* && "$UNQUOTED_CMD" == *[\$\`]* ]] && IS_MERGE_CANDIDATE=1
grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+(push|commit)([[:space:]]|$)' <<< "$CMD" ||
  [ "$IS_MERGE_CANDIDATE" -eq 1 ] || exit 0

ask() {
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$1" | grep -oE 'R-[0-9]{3}' | head -1)" "git-workflow-guard" "ask"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

deny() {
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "$(printf '%s' "$1" | grep -oE 'R-[0-9]{3}' | head -1)" "git-workflow-guard" "deny"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# parse_merge_arguments: reads the arguments of the one canonical merge the
# shell scan found (MERGE_WORDS, the words after `merge`), never a regex match
# in $CMD that a quoted mention could supply, and sets
# MERGE_HAS_MERGE_FLAG and MERGE_HAS_REBASE_FLAG (long, short, and bundled
# short forms such as `-dr`) plus MERGE_VIEW_ARGUMENTS, the `gh pr view`
# arguments naming the same PR: the first positional argument (a number, URL,
# or branch) and any --repo/-R. The values of merge's value-taking flags are
# skipped so a subject or head SHA is never mistaken for the PR or a strategy.
# The words come from the quote-aware scan, so a quoted value holding a space
# is one word, as the shell passes it.
parse_merge_arguments() {
  local merge_token short_flags short_flag skip_next=0 repo_next=0 pr_selector=""
  MERGE_HAS_MERGE_FLAG=0
  MERGE_HAS_REBASE_FLAG=0
  MERGE_VIEW_ARGUMENTS=()
  local -a merge_tokens=(${MERGE_WORDS[@]+"${MERGE_WORDS[@]}"})
  for merge_token in ${merge_tokens[@]+"${merge_tokens[@]}"}; do
    if [ "$repo_next" -eq 1 ]; then MERGE_VIEW_ARGUMENTS+=(--repo "$merge_token"); repo_next=0; continue; fi
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    case "$merge_token" in
      --merge | --merge=*) MERGE_HAS_MERGE_FLAG=1 ;;
      --rebase | --rebase=*) MERGE_HAS_REBASE_FLAG=1 ;;
      --repo) repo_next=1 ;;
      --repo=*) MERGE_VIEW_ARGUMENTS+=("$merge_token") ;;
      --subject | --body | --body-file | --author-email | --match-head-commit) skip_next=1 ;;
      --*) ;;
      -?*)
        short_flags="${merge_token#-}"
        while [ -n "$short_flags" ]; do
          short_flag="${short_flags:0:1}"
          short_flags="${short_flags:1}"
          case "$short_flag" in
            m) MERGE_HAS_MERGE_FLAG=1 ;;
            r) MERGE_HAS_REBASE_FLAG=1 ;;
            R) if [ -n "$short_flags" ]; then MERGE_VIEW_ARGUMENTS+=(--repo "$short_flags"); else repo_next=1; fi; break ;;
            t | b | F | A) [ -z "$short_flags" ] && skip_next=1; break ;;
          esac
        done ;;
      *) [ -z "$pr_selector" ] && pr_selector="$merge_token" ;;
    esac
  done
  [ -n "$pr_selector" ] && MERGE_VIEW_ARGUMENTS=("$pr_selector" ${MERGE_VIEW_ARGUMENTS[@]+"${MERGE_VIEW_ARGUMENTS[@]}"})
  return 0
}

# run_gh_view_with_deadline: runs `gh pr view` for the merge's PR from $MERGE_CWD,
# asking for the labels, commits, body, and the head branch, fork flag, and
# URL the R-517 trivial exemption checks, the head commit its range check
# reads, and the base branch the R-109 security range starts from, and prints
# its output, returning non-zero when gh fails or outlives
# CLAUDE_GH_TIMEOUT_SECONDS (default 15). The deadline keeps the guard
# fail-closed: a hook killed by the harness timeout prints nothing, and an
# empty PreToolUse output is an allow. Polls in 0.2s steps rather than using a
# `sleep N` watchdog, for the orphaned-sleep reason verification-gate.sh
# records beside its run_with_timeout.
run_gh_view_with_deadline() {
  local gh_command="${CLAUDE_GH_CMD:-gh}" deadline_steps waited_steps=0 view_output_file gh_pid gh_status
  deadline_steps=$(( ${CLAUDE_GH_TIMEOUT_SECONDS:-15} * 5 ))
  view_output_file=$(mktemp) || return 1
  (cd "$MERGE_CWD" && exec "$gh_command" pr view ${MERGE_VIEW_ARGUMENTS[@]+"${MERGE_VIEW_ARGUMENTS[@]}"} --json labels,commits,body,headRefName,headRefOid,baseRefName,isCrossRepository,url) >"$view_output_file" 2>/dev/null &
  gh_pid=$!
  while kill -0 "$gh_pid" 2>/dev/null; do
    if [ "$waited_steps" -ge "$deadline_steps" ]; then
      kill -KILL "$gh_pid" 2>/dev/null
      wait "$gh_pid" 2>/dev/null
      rm -f "$view_output_file"
      return 124
    fi
    sleep 0.2
    waited_steps=$((waited_steps + 1))
  done
  wait "$gh_pid"
  gh_status=$?
  cat "$view_output_file"
  rm -f "$view_output_file"
  return "$gh_status"
}

# read_merge_pr_view: fetches the merged PR's view once and sets PR_JSON on
# success or PR_VIEW_PROBLEM to the sentence saying why it could not be read.
# A command that changes directory or sets GH_REPO/GH_HOST merges a PR the
# hook's own gh view cannot see, so it is reported as unverifiable, as is a gh
# that errors, hangs, or answers with anything jq cannot read. CLAUDE_GH_CMD
# replaces gh for the fixture.
read_merge_pr_view() {
  PR_JSON=""
  PR_VIEW_PROBLEM=""
  if [ "$HAS_DIRECTORY_CHANGE" -eq 1 ] ||
    grep -qE '(^|[;&|(])[[:space:]]*(cd|pushd)([[:space:]]|$)|(^|[[:space:]])GH_(REPO|HOST)=' <<< "$CMD"; then
    PR_VIEW_PROBLEM="the command changes directory or sets GH_REPO/GH_HOST, so the hook cannot check the PR it merges; run the merge from the repository's own directory with no cd."
    return 0
  fi
  if ! PR_JSON=$(run_gh_view_with_deadline) ||
    ! printf '%s' "$PR_JSON" | jq -e '(.labels | type == "array") and (.commits | type == "array")' >/dev/null 2>&1; then
    PR_JSON=""
    PR_VIEW_PROBLEM="gh pr view could not return the PR's labels, commits, and body, so the PR is unverified."
  fi
  return 0
}

# read_bundle_verdict: prints "ok" when the PR being merged is a bundle PR
# (R-512's exception): it carries the `bundle` label and every commit message
# holds a `Refs: <KEY>` trailer line naming a ticket no other commit names.
# Otherwise prints the sentence naming the first missing condition, or the
# reason read_merge_pr_view could not read the PR.
read_bundle_verdict() {
  local pr_json="$PR_JSON"
  if [ -n "$PR_VIEW_PROBLEM" ]; then
    echo "$PR_VIEW_PROBLEM"
    return 0
  fi
  if ! printf '%s' "$pr_json" | jq -e 'any(.labels[]; .name == "bundle")' >/dev/null 2>&1; then
    echo "the PR has no \`bundle\` label."
    return 0
  fi
  if ! printf '%s' "$pr_json" | jq -e '(.commits | length) > 0 and all(.commits[];
      ((.messageHeadline // "") + "\n" + (.messageBody // "")) | test("(^|\n)Refs: [A-Z][A-Z0-9]+-[0-9]+"))' >/dev/null 2>&1; then
    echo "at least one commit has no \`Refs: <KEY>\` trailer line."
    return 0
  fi
  if ! printf '%s' "$pr_json" | jq -e '[.commits[] | ((.messageHeadline // "") + "\n" + (.messageBody // ""))
      | capture("(^|\n)Refs: (?<key>[A-Z][A-Z0-9]+-[0-9]+)").key] | length == (unique | length)' >/dev/null 2>&1; then
    echo "two or more commits name the same ticket in their \`Refs:\` trailer, which is one ticket's history rather than a bundle."
    return 0
  fi
  echo ok
}

# read_review_scan <body> <heading>: prints how many Markdown headings (any
# level, any case) whose text starts with <heading> ("Codex review" for R-517,
# "Security review" for R-109) the PR body holds, then the
# non-blank lines under the last one, up to the next heading. The count leads
# the output because two review sections are refused rather than merged: a
# reviewer line in one and a range in another satisfy nothing jointly, and an
# earlier stale section must not mask a later current one. A mention in prose
# is not a section, and a bare heading records no findings. Inline code spans
# keep their contents and lose only their backticks, since an object name in
# backticks is this repository's house style and deleting the span would empty
# the field it labels; a `<`, `>`, or `#` inside a span is held aside while
# comments and headings are recognised, so a span can neither open a comment
# nor pass for a heading. Lines inside
# a fenced code block count as neither heading nor content, so a template that
# quotes the section as an example does not pass for it; a fence closes only
# on a line holding nothing but a run of its own character at least as long
# as the one that opened it. HTML comments are removed the same way (inline
# ones stripped, a multi-line one skipped to its `-->`), after code spans are
# dropped, so a `<!--` quoted in a code span opens nothing.
# A heading is indented by at most three spaces, since four make it an
# indented code block. No regex intervals: older mawk lacks them.
read_review_scan() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v wanted_heading="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" '
    # hold_code_spans <text>: drops the backticks of every inline code span and
    # holds the characters inside it that the comment and heading rules react
    # to, so the span contributes its text and nothing else.
    function hold_code_spans(text,   out, tick, rest, close_tick, inside) {
      out = ""
      while (1) {
        tick = index(text, "`")
        if (tick == 0) return out text
        out = out substr(text, 1, tick - 1)
        rest = substr(text, tick + 1)
        close_tick = index(rest, "`")
        if (close_tick == 0) return out rest
        inside = substr(rest, 1, close_tick - 1)
        gsub("<", "\001", inside)
        gsub(">", "\002", inside)
        gsub("#", "\003", inside)
        out = out inside
        text = substr(rest, close_tick + 1)
      }
    }
    # release_code_spans <text>: puts those characters back, for the caller.
    function release_code_spans(text) {
      gsub("\001", "<", text)
      gsub("\002", ">", text)
      gsub("\003", "#", text)
      return text
    }
    in_fence {
      if ($0 ~ /^( |  |   )?(`+|~+)[ \t]*$/) {
        run = $0
        gsub(/[ \t]/, "", run)
        if (substr(run, 1, 1) == substr(fence, 1, 1) && length(run) >= length(fence)) in_fence = 0
      }
      next
    }
    { line = $0 }
    in_comment {
      comment_end = index(line, "-->")
      if (!comment_end) next
      in_comment = 0
      line = substr(line, comment_end + 3)
    }
    line == $0 && line ~ /^( |  |   )?(```|~~~)/ && match(line, /(`+|~+)/) && RLENGTH >= 3 {
      in_fence = 1
      fence = substr(line, RSTART, RLENGTH)
      next
    }
    {
      line = hold_code_spans(line)
      gsub(/<!--([^-]|-[^-]|--[^>])*-->/, "", line)
      comment_start = index(line, "<!--")
      if (comment_start) { in_comment = 1; line = substr(line, 1, comment_start - 1) }
    }
    line ~ /^( |  |   )?#+[ \t]/ {
      heading = tolower(line)
      sub(/^[ \t]*#+[ \t]+/, "", heading)
      in_section = (index(heading, wanted_heading) == 1)
      if (in_section) { headings++; section = "" }
      next
    }
    in_section && line ~ /[^ \t]/ { section = section release_code_spans(line) "\n" }
    END { print headings + 0; printf "%s", section }'
}

# read_review_field <section> <label>: prints the value of a review section's
# first `<label>: <value>` line, or nothing when no line carries that label
# with a value. A leading bullet and surrounding `**`/`__` emphasis are part of
# the labelling, not of the name, so `- **Reviewer:** Codex` reads as `Codex`.
read_review_field() {
  printf '%s\n' "$1" | awk -v label="$2" '
    {
      line = $0
      sub(/^[ \t]*/, "", line)
      sub(/^[-*+][ \t]+/, "", line)
      gsub(/\*\*/, "", line)
      gsub(/__/, "", line)
      colon = index(line, ":")
      if (!colon) next
      name = tolower(substr(line, 1, colon - 1))
      gsub(/[ \t]/, "", name)
      if (name != label) next
      value = substr(line, colon + 1)
      sub(/^[ \t]+/, "", value)
      sub(/[ \t]+$/, "", value)
      if (value == "") next
      print value
      exit
    }'
}

# is_hexadecimal_name <word>: true when the word is hexadecimal and nothing
# else, which is the shape of every abbreviated or full object name.
is_hexadecimal_name() {
  [ -n "$1" ] || return 1
  [ -z "$(printf '%s' "$1" | tr -d '0-9a-fA-F')" ]
}

# read_range_head <range line>: prints the head endpoint of the first
# `<base>..<head>` or `<base>...<head>` expression on the line, with trailing
# punctuation removed, and prints nothing when the line carries no such
# expression. Only the first expression is read, so a line that names several
# ranges is judged by the one it leads with rather than by whichever one
# happens to match. The base must be present: the shape is what says which
# diff was read, and a bare object name says only that somebody typed one.
read_range_head() {
  printf '%s' "$1" | awk '
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        dots = index(token, "..")
        if (dots < 2) continue
        head = substr(token, dots)
        sub(/^\.+/, "", head)
        sub(/[.,;:)\]}]+$/, "", head)
        if (head == "") continue
        print head
        exit
      }
    }'
}

# is_head_commit_prefix <endpoint> <head oid>: true when the range's head
# endpoint identifies the PR's head commit, which means it is at least seven
# characters (git's own abbreviation length, and short enough runs collide
# with ordinary words) and a prefix of the head commit's object name. The
# endpoint needs no separate hexadecimal check: anything that is not
# hexadecimal cannot equal a prefix of an object name.
# The comparison is textual rather than an ancestry lookup because the head
# commit of a PR need not exist in the checkout the merge runs from, where
# `git merge-base` would answer "no" for a range that is in fact current.
is_head_commit_prefix() {
  local endpoint head_oid
  endpoint=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  head_oid=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
  [ "${#endpoint}" -ge 7 ] || return 1
  [ "$endpoint" = "$(printf '%.*s' "${#endpoint}" "$head_oid")" ]
}

# read_codex_artefact_verdict <section>: prints "ok" when the Codex review
# section is a review artefact, otherwise the sentence naming what it is
# missing. The artefact is the reviewer that ran, the model it ran on, and the
# range it read, and that range's head endpoint must be the PR's head commit:
# a review of an older tree records that a review happened without saying
# anything about what would merge, so it does not satisfy R-517 (IAN-286, from
# PR #106, whose review reported against a commit two fixes behind the
# branch). The endpoint is what is compared, never any object name on the
# line, because a range whose BASE is the head reviewed everything except the
# head, and a head commit pasted into prose or a link reviewed nothing.
read_codex_artefact_verdict() {
  local section="$1" reviewer model range head_oid range_head
  reviewer=$(read_review_field "$section" reviewer)
  [ -n "$reviewer" ] ||
    { echo "its \`## Codex review\` section carries no \`reviewer\` line with a value, so nothing in the PR records who or what read the diff"; return 0; }
  model=$(read_review_field "$section" model)
  [ -n "$model" ] ||
    { echo "its \`## Codex review\` section carries no \`model\` line with a value, so nothing in the PR records which model the review ran on"; return 0; }
  range=$(read_review_field "$section" range)
  [ -n "$range" ] ||
    { echo "its \`## Codex review\` section carries no \`range\` line with a value, so nothing in the PR records which diff was read"; return 0; }
  head_oid=$(printf '%s' "$PR_JSON" | jq -r '.headRefOid // "" | strings' 2>/dev/null || true)
  is_hexadecimal_name "$head_oid" ||
    { echo "gh pr view returned no head commit for the PR, so the hook cannot tell whether the \`range\` line covers the state that would merge"; return 0; }
  range_head=$(read_range_head "$range")
  [ -n "$range_head" ] ||
    { echo "its \`## Codex review\` section gives the range as \`$range\`, which holds no \`<base>..<head>\` range expression, so nothing in the PR says which diff was read"; return 0; }
  is_head_commit_prefix "$range_head" "$head_oid" ||
    { echo "its \`## Codex review\` section gives the range as \`$range\`, whose head endpoint \`$range_head\` does not identify $(printf '%.7s' "$head_oid"), the commit this PR would merge, so the review read a tree other than the one that would merge"; return 0; }
  echo ok
}

# read_github_slug <url>: prints the lowercase owner/repo a GitHub remote or
# PR URL names (https, ssh, or scp-style), or nothing when it names none.
read_github_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
    sed -nE 's#^(https?://|ssh://)?([^@/]+@)?github\.com[:/]([^/]+)/([^/]+).*$#\3/\4#p' | sed -E 's/\.git$//'
}

# is_trivial_ledger_checkout <checkout> <head-branch> <pr-slug>: true when
# task-start's ledger (.claude/task-tier.json at the top of <checkout>) is
# untracked session state, records the trivial tier, and names <head-branch>,
# and <checkout>'s origin is the PR's repository <pr-slug>.
is_trivial_ledger_checkout() {
  local top ledger
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  ledger="$top/.claude/task-tier.json"
  [ -f "$ledger" ] || return 1
  git -C "$top" ls-files --error-unmatch .claude/task-tier.json >/dev/null 2>&1 && return 1
  jq -e --arg b "$2" '.tier == "trivial" and .branch == $b' "$ledger" >/dev/null 2>&1 || return 1
  [ "$(read_github_slug "$(git -C "$top" remote get-url origin 2>/dev/null)")" = "$3" ]
}

# list_head_branch_worktrees <head-branch>: prints the path of every local
# worktree checked out on refs/heads/<head-branch>, among the worktrees of the
# repository the merge runs from and of the repository ~/.claude/.sync-source
# names. Both repositories come from the tool call's cwd and the harness's own
# state, never from the command's text, so a session merging by URL from
# another repository (IAN-350) reaches the PR's checkout without a `cd`.
list_head_branch_worktrees() {
  local sync_source_file="$HOME/.claude/.sync-source" repository_root
  {
    printf '%s\n' "$MERGE_CWD"
    [ -f "$sync_source_file" ] && head -n 1 "$sync_source_file"
  } | while IFS= read -r repository_root; do
    [ -n "$repository_root" ] || continue
    git -C "$repository_root" worktree list --porcelain 2>/dev/null |
      awk -v ref="refs/heads/$1" '/^worktree /{path=substr($0, 10)} $0 == "branch " ref {print path}'
  done
}

# is_trivial_tier_pr: true when the merge is exempt from R-517's section as a
# trivial-tier PR. The only authority is task-start's ledger, checked by
# is_trivial_ledger_checkout first in the checkout the merge runs from
# ($MERGE_CWD, never a `git -C` target elsewhere in the command), then in each
# worktree on the PR's own head branch that list_head_branch_worktrees finds.
# The PR must come from a branch of that checkout's origin repository rather
# than a fork. Nothing in the PR body counts, since anyone can type a marker there.
is_trivial_tier_pr() {
  local head_branch pr_slug candidate_checkout
  head_branch=$(printf '%s' "$PR_JSON" | jq -r 'select(.isCrossRepository == false) | .headRefName // "" | strings' 2>/dev/null)
  [ -n "$head_branch" ] || return 1
  pr_slug=$(read_github_slug "$(printf '%s' "$PR_JSON" | jq -r '.url // "" | strings' 2>/dev/null)")
  [ -n "$pr_slug" ] || return 1
  is_trivial_ledger_checkout "$MERGE_CWD" "$head_branch" "$pr_slug" && return 0
  while IFS= read -r candidate_checkout; do
    is_trivial_ledger_checkout "$candidate_checkout" "$head_branch" "$pr_slug" && return 0
  done < <(list_head_branch_worktrees "$head_branch")
  return 1
}

# read_ledger_state: prints the tier and branch task-start's ledger in the
# merge's checkout now records, "no ledger", or "unreadable ledger" when the
# file exists but is not the JSON task-tier.sh writes, for the deny reason, so
# a ledger a later task overwrote is visible rather than silent.
read_ledger_state() {
  local top ledger
  top=$(git -C "$MERGE_CWD" rev-parse --show-toplevel 2>/dev/null) || { echo "no ledger"; return 0; }
  ledger="$top/.claude/task-tier.json"
  [ -f "$ledger" ] || { echo "no ledger"; return 0; }
  jq -er '"tier \(.tier // "?") for branch \(.branch // "?")"' "$ledger" 2>/dev/null || echo "unreadable ledger"
}

# read_codex_review_verdict: prints "ok" when the merged PR's body carries the
# R-517 review artefact or the PR is a ledger-verified trivial-tier PR,
# otherwise the sentence naming what is missing. The ledger is consulted only
# once the artefact has failed, so the common path costs no git calls.
read_codex_review_verdict() {
  local pr_body scan heading_count section verdict
  if [ -n "$PR_VIEW_PROBLEM" ]; then
    echo "$PR_VIEW_PROBLEM"
    return 0
  fi
  pr_body=$(printf '%s' "$PR_JSON" | jq -r '.body // "" | strings' 2>/dev/null || true)
  scan=$(read_review_scan "$pr_body" "Codex review")
  heading_count=$(printf '%s\n' "$scan" | head -1)
  section=$(printf '%s\n' "$scan" | tail -n +2)
  if [ "$heading_count" -gt 1 ]; then
    verdict="the PR body holds $heading_count \`## Codex review\` headings, and one PR carries one review, so the hook cannot say which of them describes the state that would merge; leave the one section the current review wrote"
  elif [ -n "$section" ]; then
    verdict=$(read_codex_artefact_verdict "$section")
  else
    verdict="the PR body has no \`## Codex review\` section with content under it"
  fi
  if [ "$verdict" = ok ]; then
    echo ok
    return 0
  fi
  if is_trivial_tier_pr; then
    echo ok
    return 0
  fi
  echo "$verdict, and task-start's ledger does not exempt it as a trivial-tier PR (the ledger holds: $(read_ledger_state); a later task-tier.sh set on this checkout replaces it)."
}

# The enforce directory beside this hook, resolved as the push gates resolve
# it; empty when it does not exist, which leaves the review model unreadable.
ENFORCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../enforce" 2>/dev/null && pwd)"
SECURITY_SURFACE_HELPER="$(dirname "${BASH_SOURCE[0]}")/security-surface.sh"

# resolve_security_range: sets SECURITY_TOP, SECURITY_BASE, and SECURITY_HEAD
# to the merge checkout's top level and the PR's range: the head is the
# headRefOid gh reports, resolved as a commit in that checkout, and the base
# is its merge base with origin/<baseRefName>. Returns non-zero when any of
# them cannot be resolved, never substituting the checkout's own HEAD.
resolve_security_range() {
  local base_ref_name
  SECURITY_TOP=$(git -C "$MERGE_CWD" rev-parse --show-toplevel 2>/dev/null) || return 1
  SECURITY_HEAD=$(printf '%s' "$PR_JSON" | jq -r '.headRefOid // "" | strings' 2>/dev/null) || return 1
  is_hexadecimal_name "$SECURITY_HEAD" || return 1
  git -C "$SECURITY_TOP" rev-parse --verify --quiet "$SECURITY_HEAD^{commit}" >/dev/null 2>&1 || return 1
  base_ref_name=$(printf '%s' "$PR_JSON" | jq -r '.baseRefName // "" | strings' 2>/dev/null) || return 1
  [ -n "$base_ref_name" ] || return 1
  SECURITY_BASE=$(git -C "$SECURITY_TOP" merge-base "refs/remotes/origin/$base_ref_name" "$SECURITY_HEAD" 2>/dev/null) || return 1
  [ -n "$SECURITY_BASE" ]
}

# is_security_touching_pr: true when the PR's range touches a security
# surface, as the sourced detector decides, and also whenever the answer
# cannot be had: a missing helper or an unresolvable range fails closed, and
# is_security_surface itself answers true when the detector fails.
is_security_touching_pr() {
  [ -f "$SECURITY_SURFACE_HELPER" ] || return 0
  # shellcheck source=security-surface.sh
  . "$SECURITY_SURFACE_HELPER" || return 0
  type is_security_surface >/dev/null 2>&1 || return 0
  resolve_security_range || return 0
  is_security_surface "$SECURITY_TOP" "$SECURITY_BASE" "$SECURITY_HEAD"
}

# read_security_review_model: prints securityReviewModel from
# enforce/security-review-model.json, or nothing when it cannot be read.
read_security_review_model() {
  [ -n "$ENFORCE_DIR" ] || return 0
  jq -er '.securityReviewModel | strings | select(length > 0)' "$ENFORCE_DIR/security-review-model.json" 2>/dev/null || true
}

# read_security_artefact_verdict <section>: prints "ok" when the Security
# review section names a reviewer, ran on exactly the strongest model
# securityReviewModel names, and read a range whose head endpoint is the PR's
# head commit; otherwise the sentence naming the first condition that failed.
read_security_artefact_verdict() {
  local section="$1" reviewer model expected_model range range_head
  reviewer=$(read_review_field "$section" reviewer)
  [ -n "$reviewer" ] ||
    { echo "its \`## Security review\` section carries no \`reviewer\` line with a value"; return 0; }
  expected_model=$(read_security_review_model)
  [ -n "$expected_model" ] ||
    { echo "the hook cannot read \`securityReviewModel\` from enforce/security-review-model.json, so no model can satisfy the review"; return 0; }
  model=$(read_review_field "$section" model)
  [ "$model" = "$expected_model" ] ||
    { echo "its \`## Security review\` section gives the model as \`$model\`, but the security review must run on \`$expected_model\`, the model securityReviewModel names"; return 0; }
  range=$(read_review_field "$section" range)
  range_head=$(read_range_head "$range")
  [ -n "$range_head" ] ||
    { echo "its \`## Security review\` section carries no \`range\` line holding a \`<base>..<head>\` expression"; return 0; }
  is_head_commit_prefix "$range_head" "$SECURITY_HEAD" ||
    { echo "its \`## Security review\` section's range head \`$range_head\` does not identify $(printf '%.7s' "$SECURITY_HEAD"), the commit this PR would merge, so the review is stale"; return 0; }
  echo ok
}

# read_empty_nothing_found_lines <section>: prints every `Nothing found:` line
# whose text after its last `tried` word is empty or punctuation, and every
# such line with no `tried` word at all, since neither names a value tried.
read_empty_nothing_found_lines() {
  awk '
    {
      line = $0
      sub(/^[ \t]*/, "", line)
      sub(/^[-*+][ \t]+/, "", line)
      gsub(/\*\*/, "", line)
      lowered = tolower(line)
      if (index(lowered, "nothing found:") != 1) next
      tried_end = 0
      for (start = 1; (found = index(substr(lowered, start), "tried")) > 0; start += found) {
        position = start + found - 1
        before = (position == 1) ? " " : substr(lowered, position - 1, 1)
        after = substr(lowered, position + 5, 1)
        if (before !~ /[a-z]/ && after !~ /[a-z]/) tried_end = position + 5
      }
      values = tried_end ? substr(line, tried_end) : ""
      gsub(/[ \t.,;:]/, "", values)
      if (values == "") print line
    }' <<< "$1"
}

# read_findings_rows <section>: prints one `<#>\t<SEVERITY>\t<status>` line
# per row of the section's findings table, nothing when it holds no table,
# and, when a table line breaks the expected header, separator, cell count,
# `#`, severity, or status shape, the reason alone with a non-zero return.
read_findings_rows() {
  awk '
    function trim(text) { sub(/^[ \t]+/, "", text); sub(/[ \t]+$/, "", text); return text }
    function fault(reason) { print reason; is_faulted = 1; exit 1 }
    /^[ \t]*\|/ {
      table_lines++
      line = trim($0)
      sub(/^\|/, "", line)
      sub(/\|$/, "", line)
      cell_count = split(line, cells, "|")
      if (cell_count != 8) fault("table line " table_lines " has " cell_count " cells rather than 8")
      for (i = 1; i <= 8; i++) { cells[i] = trim(cells[i]); gsub(/[ \t]+/, " ", cells[i]) }
      if (table_lines == 1) {
        header = tolower(cells[1] "|" cells[2] "|" cells[3] "|" cells[4] "|" cells[5] "|" cells[6] "|" cells[7] "|" cells[8])
        if (header != "#|severity|control|source|worst value tried|evidence|fix|status") fault("its header is not # | Severity | Control | Source | Worst value tried | Evidence | Fix | Status")
        next
      }
      if (table_lines == 2) {
        for (i = 1; i <= 8; i++) if (cells[i] !~ /^:?-+:?$/) fault("its second line is not a separator row")
        next
      }
      if (cells[1] !~ /^[0-9]+$/) fault("table line " table_lines " has no number in its # cell")
      severity = toupper(cells[2])
      if (severity !~ /^(CRITICAL|HIGH|MEDIUM|LOW)$/) fault("row " cells[1] " has severity " cells[2] ", not CRITICAL, HIGH, MEDIUM, or LOW")
      status = tolower(cells[8])
      if (status != "open" && status !~ /^fixed [0-9a-f]+$/ && status !~ /^waived by owner [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) fault("row " cells[1] " has status " cells[8] ", not open, fixed <sha>, or waived by owner <date>")
      print cells[1] "\t" severity "\t" status
    }
    END {
      if (is_faulted) exit 1
      if (table_lines == 1) { print "it has a header and no separator row"; exit 1 }
    }' <<< "$1"
}

# list_rows_with_status <rows> <status prefix>: prints `row <#>` for each row
# whose status starts with the prefix, joined by ", ", or nothing.
list_rows_with_status() {
  awk -F '\t' -v prefix="$2" 'index($3, prefix) == 1 { names = names (names == "" ? "" : ", ") "row " $1 } END { printf "%s", names }' <<< "$1"
}

# read_security_artefact_json <section>: prints the `artefact` line's file,
# read at the PR head (the checkout need not be on the PR branch), as compact
# JSON holding a findings array of objects with an id and a string severity;
# otherwise prints why it cannot and returns non-zero.
read_security_artefact_json() {
  local artefact_path artefact_text
  artefact_path=$(read_review_field "$1" artefact)
  [ -n "$artefact_path" ] ||
    { echo "its findings table has rows but the section carries no \`artefact\` line naming the reviewer's saved output"; return 1; }
  artefact_text=$(git -C "$SECURITY_TOP" show "$SECURITY_HEAD:$artefact_path" 2>/dev/null) ||
    { echo "its artefact \`$artefact_path\` cannot be read at the PR head $(printf '%.7s' "$SECURITY_HEAD")"; return 1; }
  jq -ce 'select((.findings | type) == "array" and all(.findings[]; type == "object" and has("id") and (.severity | type) == "string"))' <<< "$artefact_text" 2>/dev/null ||
    { echo "its artefact \`$artefact_path\` is not JSON holding a findings array with an id and a severity on every finding"; return 1; }
}

# read_severity_rank <severity>: prints 4 for CRITICAL down to 1 for LOW, and
# 0 for anything else.
read_severity_rank() {
  case "$1" in CRITICAL) echo 4 ;; HIGH) echo 3 ;; MEDIUM) echo 2 ;; LOW) echo 1 ;; *) echo 0 ;; esac
}

# read_artefact_severity <artefact json> <#>: prints the uppercase severity of
# the artefact's one finding whose id is <#>, or nothing when none or several match.
read_artefact_severity() {
  jq -r --arg id "$2" '[.findings[] | select((.id | tostring) == $id) | .severity | ascii_upcase] | if length == 1 then .[0] else "" end' <<< "$1" 2>/dev/null
}

# read_severity_verdict <rows> <artefact json>: prints "ok" when every row's
# severity is at least the artefact's for the same id (B-10), otherwise the
# sentence naming the first row that is downgraded or has no artefact match.
read_severity_verdict() {
  local row_id row_severity row_status artefact_severity artefact_rank
  while IFS=$'\t' read -r row_id row_severity row_status; do
    artefact_severity=$(read_artefact_severity "$2" "$row_id") ||
      { echo "the hook could not read row $row_id's severity from the artefact"; return 0; }
    artefact_rank=$(read_severity_rank "$artefact_severity")
    [ "$artefact_rank" -gt 0 ] ||
      { echo "row $row_id has no single finding with id $row_id and a known severity in the artefact"; return 0; }
    [ "$(read_severity_rank "$row_severity")" -ge "$artefact_rank" ] ||
      { echo "row $row_id is graded $row_severity in the table but $artefact_severity in the artefact, and a finding is never downgraded"; return 0; }
  done <<< "$1"
  echo ok
}

# is_range_commit <sha>: true when the abbreviated or full object name
# resolves to one commit in SECURITY_BASE..SECURITY_HEAD; an ambiguous name,
# a missing object, or a failed ancestry lookup is false.
is_range_commit() {
  local commit_oid ancestry_status
  is_hexadecimal_name "$1" && [ "${#1}" -ge 7 ] || return 1
  commit_oid=$(git -C "$SECURITY_TOP" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || return 1
  git -C "$SECURITY_TOP" merge-base --is-ancestor "$commit_oid" "$SECURITY_HEAD" 2>/dev/null || return 1
  git -C "$SECURITY_TOP" merge-base --is-ancestor "$commit_oid" "$SECURITY_BASE" 2>/dev/null
  ancestry_status=$?
  [ "$ancestry_status" -eq 1 ]
}

# read_fixed_commit_verdict <rows>: prints "ok" when every `fixed <sha>` row
# names a commit in the PR range (B-11), otherwise the sentence naming the row.
read_fixed_commit_verdict() {
  local row_id row_severity row_status fixed_sha
  while IFS=$'\t' read -r row_id row_severity row_status; do
    case "$row_status" in fixed\ *) ;; *) continue ;; esac
    fixed_sha="${row_status#fixed }"
    is_range_commit "$fixed_sha" ||
      { echo "row $row_id is marked fixed by \`$fixed_sha\`, which is not a commit in the PR range $(printf '%.7s' "$SECURITY_BASE")..$(printf '%.7s' "$SECURITY_HEAD")"; return 0; }
  done <<< "$1"
  echo ok
}

# read_table_verdict <section> <rows>: prints "ok" or the deny sentence for a
# parsed findings table with rows: no open row, a readable artefact, no
# downgraded severity, and every fix in range; else "waived: <rows>" when a
# row is waived, so the caller asks the owner.
read_table_verdict() {
  local open_rows artefact_json verdict waived_rows
  open_rows=$(list_rows_with_status "$2" open)
  [ -z "$open_rows" ] || { echo "its findings table still has $open_rows open"; return 0; }
  artefact_json=$(read_security_artefact_json "$1") || { echo "$artefact_json"; return 0; }
  verdict=$(read_severity_verdict "$2" "$artefact_json")
  [ "$verdict" = ok ] || { echo "$verdict"; return 0; }
  verdict=$(read_fixed_commit_verdict "$2")
  [ "$verdict" = ok ] || { echo "$verdict"; return 0; }
  waived_rows=$(list_rows_with_status "$2" "waived by owner")
  [ -z "$waived_rows" ] || { echo "waived: $waived_rows"; return 0; }
  echo ok
}

# read_security_findings_verdict <section>: prints "ok" when the Security
# review's findings clear R-109, "waived: <rows>" when only an owner waiver
# stands between them and the merge, and otherwise the deny sentence. A
# section with no table and no Nothing-found line is not judged here.
read_security_findings_verdict() {
  local empty_lines rows
  empty_lines=$(read_empty_nothing_found_lines "$1") ||
    { echo "the hook could not read the section's Nothing found lines"; return 0; }
  [ -z "$empty_lines" ] ||
    { echo "its line \`$(printf '%s\n' "$empty_lines" | head -n 1)\` names no values after \`tried\`, so it records no test of the control"; return 0; }
  rows=$(read_findings_rows "$1") ||
    { echo "its findings table cannot be parsed ($rows), so every finding in it counts as open"; return 0; }
  [ -n "$rows" ] || { echo ok; return 0; }
  read_table_verdict "$1" "$rows"
}

# read_security_review_verdict: prints "ok" when the PR touches no security
# surface or its body carries one current Security review artefact whose
# findings clear R-109, "waived: <rows>" when only owner waivers remain, and
# otherwise the sentence naming what is missing. An undecidable range reads
# as security-touching and, with no resolvable head, can satisfy nothing.
read_security_review_verdict() {
  local pr_body scan heading_count section artefact_verdict
  SECURITY_HEAD=""
  SECURITY_BASE=""
  is_security_touching_pr || { echo ok; return 0; }
  [ -n "$SECURITY_HEAD" ] && [ -n "$SECURITY_BASE" ] ||
    { echo "the hook could not resolve the PR's range (its head commit is not in this checkout, origin/<base> is missing, or the detector is absent), so it treats the PR as security-touching and cannot tell which tree a review read; fetch the PR head and origin and merge again"; return 0; }
  pr_body=$(printf '%s' "$PR_JSON" | jq -r '.body // "" | strings' 2>/dev/null || true)
  scan=$(read_review_scan "$pr_body" "Security review")
  heading_count=$(printf '%s\n' "$scan" | head -1)
  section=$(printf '%s\n' "$scan" | tail -n +2)
  if [ "$heading_count" -gt 1 ]; then
    echo "the PR body holds $heading_count \`## Security review\` headings, so the hook cannot say which one describes the state that would merge"
  elif [ -n "$section" ]; then
    artefact_verdict=$(read_security_artefact_verdict "$section")
    [ "$artefact_verdict" = ok ] || { echo "$artefact_verdict"; return 0; }
    read_security_findings_verdict "$section"
  else
    echo "the PR touches a security surface and its body has no \`## Security review\` section with content under it"
  fi
}

# classify_merge_commands <command> <is-nested>: walks the command's simple
# commands and, for each that runs `gh pr merge`, adds one to MERGE_TOTAL and,
# when its words are exactly `gh pr merge ...` with no wrapper, keyword,
# path, or option ahead of `merge`, one to MERGE_CANONICAL. It sets
# HAS_DIRECTORY_CHANGE for any cd, pushd, or popd, and scans the string given
# to eval or to bash/sh/zsh -c as a nested command (depth-limited), whose
# merges are never canonical.
classify_merge_commands() {
  local command_text="$1" is_nested="${2:-0}" token is_heredoc_next=0
  local -a command_tokens=() words=()
  [ "${CLASSIFY_DEPTH:-0}" -lt 4 ] || { MERGE_TOTAL=$((MERGE_TOTAL + 1)); return 0; }
  CLASSIFY_DEPTH=$(( ${CLASSIFY_DEPTH:-0} + 1 ))
  scan_command_tokens "$command_text"
  command_tokens=(${TOKENS[@]+"${TOKENS[@]}"})
  for token in ${command_tokens[@]+"${command_tokens[@]}"}; do
    if [ "$is_heredoc_next" -eq 1 ]; then
      is_heredoc_next=0
      is_shell_consumer "${words[@]+"${words[@]}"}" && classify_merge_commands "$token" 1
      continue
    fi
    case "$token" in
      "$HEREDOC_TOKEN") is_heredoc_next=1 ;;
      "$SEPARATOR_TOKEN") classify_simple_command "$is_nested" ${words[@]+"${words[@]}"}; words=() ;;
      *) words+=("$token") ;;
    esac
  done
  classify_simple_command "$is_nested" ${words[@]+"${words[@]}"}
  CLASSIFY_DEPTH=$((CLASSIFY_DEPTH - 1))
}

# is_shell_consumer <word>...: true when the simple command, past its leading
# assignments, is a shell or eval that would run a heredoc fed to it.
is_shell_consumer() {
  while [ "$#" -gt 0 ] && [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done
  case "${1:-}" in */*) set -- "${1##*/}" ;; esac
  case "${1:-}" in bash | sh | zsh | eval | source | .) return 0 ;; esac
  return 1
}

# count_unreadable_merge: records a merge the scan cannot read (a script fed
# on stdin, or a word built by expansion); it is never canonical, so the
# merge path denies it.
count_unreadable_merge() {
  MERGE_TOTAL=$((MERGE_TOTAL + 1))
}

# classify_simple_command <is-nested> <word>...: the per-command half of
# classify_merge_commands. A subcommand or `merge` slot of a gh command built
# by expansion ($, or a backtick) is counted as an unreadable merge rather
# than trusted, and so, when the command mentions merge at all, is a command
# word built by expansion or a shell reading its script from stdin.
classify_simple_command() {
  local is_wrapped="$1" word script=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      '{' | '}' | '!' | if | then | else | elif | do | while | until | time) is_wrapped=1; shift ;;
      *) [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || break; shift ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  if [ "$IS_MERGE_MENTIONED" -eq 1 ]; then
    case "$1" in *'$'* | *'`'*) count_unreadable_merge; return 0 ;; esac
  fi
  case "${1##*/}" in
    cd | pushd | popd) HAS_DIRECTORY_CHANGE=1; return 0 ;;
    eval) shift; classify_merge_commands "$*" 1; return 0 ;;
    bash | sh | zsh)
      shift
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -*c*) script="${2:-}"; break ;;
          -*) shift ;;
          *) return 0 ;;
        esac
      done
      if [ -n "$script" ]; then
        classify_merge_commands "$script" 1
      elif [ "$IS_MERGE_MENTIONED" -eq 1 ]; then
        count_unreadable_merge
      fi
      return 0 ;;
    env | command | exec | sudo | nohup | nice | timeout | xargs | stdbuf | caffeinate)
      is_wrapped=1
      while [ "$#" -gt 0 ] && [ "${1##*/}" != "gh" ]; do shift; done
      [ "$#" -gt 0 ] || return 0 ;;
  esac
  if [ "$IS_MERGE_MENTIONED" -eq 1 ]; then
    case "$1" in *'$'* | *'`'*) count_unreadable_merge; return 0 ;; esac
  fi
  [ "${1##*/}" = "gh" ] || return 0
  [ "$1" = "gh" ] || is_wrapped=1
  shift
  while [ "$#" -gt 0 ] && [ "${1#-}" != "$1" ]; do
    is_wrapped=1
    case "$1" in -R | --repo) shift ;; esac
    shift
  done
  case "${1:-}" in *'$'* | *'`'*) count_unreadable_merge; return 0 ;; esac
  [ "${1:-}" = "pr" ] || return 0
  shift
  while [ "$#" -gt 0 ] && [ "${1#-}" != "$1" ]; do
    is_wrapped=1
    case "$1" in -R | --repo) shift ;; esac
    shift
  done
  case "${1:-}" in *'$'* | *'`'*) count_unreadable_merge; return 0 ;; esac
  [ "${1:-}" = "merge" ] || return 0
  shift
  MERGE_TOTAL=$((MERGE_TOTAL + 1))
  if [ "$is_wrapped" -eq 0 ]; then
    MERGE_CANONICAL=$((MERGE_CANONICAL + 1))
    MERGE_WORDS=("$@")
  fi
  return 0
}

# R-512, R-517, R-109, and R-514 on the merge path. A merge-commit strategy is
# denied from the command alone, before any gh call. Every other merge
# consults gh once, from the command's working directory: a rebase for the
# bundle conditions, and every merge for the Codex review section in the PR
# body and, when its range touches security code, the Security review section.
MERGE_TOTAL=0
MERGE_CANONICAL=0
MERGE_WORDS=()
HAS_DIRECTORY_CHANGE=0
if [ "$IS_MERGE_CANDIDATE" -eq 1 ]; then
  if [ "$IS_SHELL_TOKENS_LOADED" -eq 1 ]; then
    classify_merge_commands "$CMD" 0
  elif grep -qE 'gh[^;&|]*[[:space:]]pr[^;&|]*[[:space:]]merge([[:space:]]|$)' <<< "$UNQUOTED_CMD"; then
    MERGE_TOTAL=1
  fi
fi
if [ "$MERGE_TOTAL" -gt 0 ]; then
  MERGE_COUNT="$MERGE_TOTAL"
  PARSEABLE_MERGE_COUNT=$(grep -oE "$GH_MERGE_PATTERN" <<< "$CMD" | wc -l | tr -d ' ')
  [ "$MERGE_COUNT" -le 1 ] && [ "$MERGE_CANONICAL" -eq 1 ] && [ "$PARSEABLE_MERGE_COUNT" -eq 1 ] || [ "$MERGE_COUNT" -gt 1 ] ||
    deny "R-517: this merge runs gh inside a brace group, subshell, control-flow keyword, eval or sh -c string, behind a wrapper or path, with quoted or escaped words, or with an option such as --repo/-R before the merge subcommand, a shape the hook cannot parse, so it cannot check the PR's Codex review section (R-517), strategy (R-512), or authorization (R-514). Re-run it as a bare \`gh pr merge <n> --squash [--repo <owner/repo>]\` on its own line."
  [ "$MERGE_COUNT" -le 1 ] ||
    deny "R-517: this command runs $MERGE_COUNT merges, and the hook reads one PR's body per merge command, so the others would merge without their Codex review being checked. Merge one PR per command."
  parse_merge_arguments
  if [ "$MERGE_HAS_MERGE_FLAG" -eq 1 ]; then
    deny "This merges the PR with a strategy R-512 does not allow. Feature branches squash-merge: one commit per feature on main, so the branch's work-in-progress history stays off the trunk. Re-run with --squash."
  fi
  read_merge_pr_view
  if [ "$MERGE_HAS_REBASE_FLAG" -eq 1 ]; then
    BUNDLE_VERDICT=$(read_bundle_verdict)
    [ "$BUNDLE_VERDICT" = "ok" ] ||
      deny "This rebase-merges the PR, which R-512 allows only for a bundle PR, and $BUNDLE_VERDICT A bundle carries the \`bundle\` label and one commit per ticket, each with its own \`Refs: <KEY>\` trailer line, so every ticket keeps exactly one commit on main. Otherwise re-run with --squash."
  fi
  CODEX_REVIEW_VERDICT=$(read_codex_review_verdict)
  [ "$CODEX_REVIEW_VERDICT" = "ok" ] ||
    deny "R-517: no PR merges before the blocking Codex review, and $CODEX_REVIEW_VERDICT Run the review with ~/.claude/prompts/codex-pr-review-prompt.md (or its recorded fallback when Codex is unavailable), fix or answer every finding, and add a \`## Codex review\` section to the PR body carrying a \`reviewer\` line, a \`model\` line, a \`range\` line covering the commit this PR would merge, and the findings with their dispositions; then merge again."
  SECURITY_REVIEW_VERDICT=$(read_security_review_verdict)
  case "$SECURITY_REVIEW_VERDICT" in
    ok) ;;
    "waived: "*)
      ask "R-109: the Security review marks ${SECURITY_REVIEW_VERDICT#waived: } as waived by owner, and a waived security finding merges only on the owner's confirmation. Confirm each waived row and this merge (R-514) now, or say so and the merge waits." ;;
    *)
      deny "R-109: a PR that touches security code merges only after a Security review on the strongest model, and $SECURITY_REVIEW_VERDICT. Run the security-reviewer agent on the PR's range, fix or answer every finding, and add a \`## Security review\` section to the PR body carrying a \`reviewer\` line, a \`model\` line naming securityReviewModel, a \`range\` line covering the commit this PR would merge, an \`artefact\` line naming the reviewer's saved output, and the findings table with every row \`fixed <sha>\` in range or \`waived by owner <date>\`; then merge again." ;;
  esac
  ask "R-514: merging a PR needs explicit user authorization in the current turn, and 'merge when ready' from an earlier turn is not it. Confirm this specific merge now, or say so and it waits."
fi

TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
# Identity is defined once in repo-identity.sh (2026-09-16 audit item 5).
# -f guard: a failed source aborts the shell under set -e even behind ||.
REPO_IDENTITY_HELPER="$(dirname "${BASH_SOURCE[0]}")/repo-identity.sh"
is_global_repo=0
if [ -f "$REPO_IDENTITY_HELPER" ]; then
  source "$REPO_IDENTITY_HELPER"
  if is_governance_repo "$TOP"; then
    is_global_repo=1
  fi
fi
BRANCH=$(git -C "$TOP" symbolic-ref --short HEAD 2>/dev/null || true)
on_trunk=0
case "$BRANCH" in main | master) on_trunk=1 ;; esac

# R-514 on the push path: the target branch is the explicit refspec when one is
# given, and the checked-out branch otherwise.
if [ "$is_global_repo" -eq 0 ] && grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+push([[:space:]]|$)' <<< "$CMD"; then
  PUSH_ARGS=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+push[^;&|]*' | head -1 |
    sed -E 's/^git[[:space:]]+push[[:space:]]*//' | tr ' ' '\n' | grep -vE '^(-.*)?$' || true)
  REFSPEC=$(printf '%s\n' "$PUSH_ARGS" | sed -n '2p')
  # Resolve the refspec to a branch name rather than pattern-matching its text:
  # `HEAD`, `refs/heads/main`, `+main`, and `HEAD:refs/heads/main` all name the
  # same destination as a bare `main`, and matching literally missed all four.
  TARGET="$BRANCH"
  if [ -n "$REFSPEC" ]; then
    TARGET="${REFSPEC##*:}"
    TARGET="${TARGET#+}"
    TARGET="${TARGET#refs/heads/}"
    [ "$TARGET" = "HEAD" ] && TARGET="$BRANCH"
  fi
  case "$TARGET" in
    main | master)
      ask "R-514: this pushes straight to $TARGET, which is only for an express request after the risks are named. The default path is a branch and a PR. Confirm the direct push, or redirect it to a feature branch." ;;
  esac
fi

# Commit-time advisories. Staged paths are unioned with any `git add` argument
# in the same command, because a chained `git add X && git commit` runs this
# hook before anything reaches the index.
grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+commit([[:space:]]|$)' <<< "$CMD" || exit 0
CHANGED=$(git -C "$TOP" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
ADDED=$(git -C "$TOP" diff --cached --name-only --diff-filter=A 2>/dev/null || true)
if grep -qE 'git[[:space:]]+add[[:space:]]' <<< "$CMD"; then
  WORKING=$(git -C "$TOP" status --porcelain 2>/dev/null || true)
  CHANGED="$CHANGED
$(printf '%s\n' "$WORKING" | awk 'NF {print $NF}')"
  ADDED="$ADDED
$(printf '%s\n' "$WORKING" | awk '/^(\?\?|A)/ {print $NF}')"
fi
CHANGED=$(printf '%s\n' "$CHANGED" | grep -v '^$' | sort -u || true)
[ -z "$CHANGED" ] && exit 0

# R-511: breadth is the signal. A change touching this many files across this
# many directories is the cross-cutting refactor that wants its own branch.
if [ "$is_global_repo" -eq 0 ] && [ "$on_trunk" -eq 1 ]; then
  FILE_COUNT=$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')
  # dirname per line, not via xargs: a path holding a quote or a space makes
  # xargs exit non-zero, and under pipefail that took the whole advisory with it.
  DIR_COUNT=$(while IFS= read -r changed_path; do
    [ -n "$changed_path" ] && dirname "$changed_path"
  done <<<"$CHANGED" | sort -u | wc -l | tr -d ' ')
  if [ "$FILE_COUNT" -ge 5 ] && [ "$DIR_COUNT" -ge 3 ]; then
    echo "git-workflow-guard: this commit spans $FILE_COUNT files across $DIR_COUNT directories on $BRANCH. R-511 runs a cross-cutting change on its own branch, one at a time, so it can be reviewed and reverted as a unit." >&2
  fi
fi

# R-508: a new route, handler, page, or setup change is user-facing by
# definition, and the README is where a user finds out. The route patterns
# cover every stack the R-607 checklist (enforce/require-feature-checklist.sh,
# BUILTIN_TRIGGERS) treats as a new route: Next.js pages and route handlers,
# Nuxt pages, Nitro server/api and server/routes, FastAPI routers, and Express
# routes and handlers. That script is copied standalone into product
# repositories, so it cannot source a shared list; the git-workflow-guard
# fixture reads its triggers and fails when this list stops covering them.
R508_SURFACE_PATTERNS=(
  '(^|/)(routes|handlers)/'
  '(^|/)(page|route)\.(tsx|ts|jsx|js)$'
  '(^|/)app/pages/.+\.vue$'
  '(^|/)server/api/'
  '(^|/)app/routers/[^/]+\.py$'
  '(^|/)features/'
  '(^|/)\.env\.example$'
  '(^|/)docker-compose[^/]*\.ya?ml$'
  '(^|/)Dockerfile$'
)
SURFACE_GREP_ARGS=()
for surface_pattern in "${R508_SURFACE_PATTERNS[@]}"; do SURFACE_GREP_ARGS+=(-e "$surface_pattern"); done
SURFACE=$(printf '%s\n' "$ADDED" | grep -v '^$' |
  grep -E "${SURFACE_GREP_ARGS[@]}" | head -3 || true)
if [ -n "$SURFACE" ] && ! grep -qiE '(^|/)README[^/]*$' <<< "$CHANGED"; then
  echo "git-workflow-guard: this commit adds a user-facing surface ($(printf '%s' "$SURFACE" | tr '\n' ' ')) and touches no README. R-508 updates the README in the same commit as the feature, structure, or setup change." >&2
fi
exit 0
