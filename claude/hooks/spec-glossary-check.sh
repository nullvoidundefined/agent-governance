#!/usr/bin/env bash
# PostToolUse(Write) backstop for R-330: a superpowers spec design doc must
# carry a committed domain glossary (the project's ubiquitous language) so that
# file/function/type naming has a settled vocabulary to conform to.
#
# When a *-design.md under docs/superpowers/specs/ is written without a
# "## Domain vocabulary" section containing at least one "chosen over:" entry,
# emit a non-blocking reminder. Silent for every other path. Never blocks; a jq
# fault or malformed input exits 0 so the hook can never break a Write.
jq -rc '
  .tool_input as $i
  | ($i.file_path // "") as $p
  | ($i.content // "") as $c
  | if ($p | test("docs/superpowers/specs/.*-design\\.md$"))
       and (($c | test("## Domain vocabulary")) and ($c | test("chosen over:")) | not)
    then {hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("Spec "+$p+" is missing its domain glossary (R-330). Add a \"## Domain vocabulary\" section listing each domain noun as `term - meaning - chosen over: <alternatives> because <reason>`. The spec is incomplete until the ubiquitous language is committed. No em dashes.")}}
    else empty end
' 2>/dev/null || true
