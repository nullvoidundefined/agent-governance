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
# Silent for every other path. Never blocks; a jq fault or malformed input
# exits 0 so the hook can never break a Write. The template with all headings
# is prompts/spec-template.md.
jq -rc '
  .tool_input as $i
  | ($i.file_path // "") as $p
  | ($i.content // "") as $c
  | if ($p | test("docs/superpowers/specs/.*-design\\.md$")) | not then empty else
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
    end
' 2>/dev/null || true
