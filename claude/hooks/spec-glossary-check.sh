#!/usr/bin/env bash
# PostToolUse(Write) backstop for R-330: a superpowers spec design doc must
# carry the sections the slice loop and the conformance reviewer read from.
# Three sections, one reminder naming the missing ones:
#   ## Domain vocabulary   with at least one "chosen over:" entry (the original
#                          R-330 gate, 2026-07-07)
#   ## Acceptance criteria one numbered behavior per line, each a RED slice
#                          (R-412; added 2026-09-06 from the TDD harness
#                          assessment, decision 6)
#   ## Non-goals           what the critic must not report and the implementer
#                          must not build
# Since 2026-09-17 (skills audit, S-10) the same hook also reads a slice plan
# under docs/slices/slice-*.md, the Gate 1 artifact of the
# build-by-slice-require-review skill: every "### PR" block must carry the
# seven bold labels the skill's PR description format fixes (Context,
# Problem, Approach, Contents, Tests, Review focus, Size), and the plan must
# hold at least one such block. Since 2026-09-24 (IAN-352) it must also carry
# a line of its own beginning "**Merge mode:**", the record of which merge mode
# the owner chose for the slice at Gate 1, because merging on green CI is now
# the opt-in and the owner's own merge is the default (R-514). The check is
# anchored to the start of a line rather than a substring search of the whole
# document: the same bolded phrase quoted inside a PR block's prose would
# otherwise silence the reminder while no declaration exists (review finding 3
# on PR #132). One reminder names the missing mode line and each PR's missing
# labels together.
# Silent for every other path. Never blocks; a jq fault or malformed input
# exits 0 so the hook can never break a Write. The template with all headings
# is prompts/spec-template.md.
jq -rc '
  .tool_input as $i
  | ($i.file_path // "") as $p
  | ($i.content // "") as $c
  | if ($p | test("docs/superpowers/specs/.*-design\\.md$")) then
      ([
        (if (($c | test("## Domain vocabulary")) and ($c | test("chosen over:"))) then empty
         else "a \"## Domain vocabulary\" section listing each domain noun as `term - meaning - chosen over: <alternatives> because <reason>`" end),
        (if ($c | test("## Acceptance criteria")) then empty
         else "a \"## Acceptance criteria\" section with one numbered behavior per line (B-1, B-2, ...), each a slice the harness runs as RED then GREEN (R-412)" end),
        (if ($c | test("## Non-goals")) then empty
         else "a \"## Non-goals\" section naming what the spec deliberately leaves out" end)
      ]) as $missing
      | if ($missing | length) == 0 then empty
        else {hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("Spec "+$p+" is incomplete (R-330): it is missing "+($missing | join("; "))+". The headings and their intent are in ~/.claude/prompts/spec-template.md. No em dashes.")}}
        end
    elif ($p | test("(^|/)docs/slices/slice-[^/]*\\.md$")) then
      (["Context","Problem","Approach","Contents","Tests","Review focus","Size"]) as $labels
      | ($c | split("\n### ") | .[1:] | map(select(startswith("PR")))) as $blocks
      | ($blocks | map(
          . as $block
          | ($block | split("\n")[0]) as $heading
          | ($labels | map(select(("**" + . + ":**") as $needle | ($block | contains($needle)) | not))) as $absent
          | if ($absent | length) == 0 then empty else ($heading + " lacks " + ($absent | join(", "))) end
        )) as $problems
      | (if ($c | split("\n") | any(startswith("**Merge mode:**"))) then []
         else ["the plan has no \"**Merge mode:**\" line, so nothing records whether the owner reads and merges each PR (the default) or the session merges on green CI plus the R-517 review (the opt-in, R-514)"] end) as $mode
      | (($mode + $problems)) as $all
      | if ($blocks | length) == 0 then
          {hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("Slice plan "+$p+" has no \"### PR <n>: <title>\" block; build-by-slice-require-review lists every PR of the slice under one, each with the seven bold labels Context, Problem, Approach, Contents, Tests, Review focus, Size"+(if ($mode | length) == 0 then "." else ", and the plan itself carries a \"**Merge mode:**\" line recording the merge mode chosen at Gate 1 (R-514)." end))}}
        elif ($all | length) == 0 then empty
        else {hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("Slice plan "+$p+" is incomplete for Gate 1 (build-by-slice-require-review): "+($all | join("; "))+". Every PR block carries the seven bold labels Context, Problem, Approach, Contents, Tests, Review focus, Size, and the plan carries a \"**Merge mode:**\" line.")}}
        end
    else empty end
' 2>/dev/null || true
