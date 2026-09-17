---
name: protocol
description: Use when debugging a process failure, reviewing why a rule exists, or onboarding to the operating protocol.
argument-hint: [layer N | R-NNN | heading words]
---

```! bash ~/.claude/skills/protocol/scripts/section.sh $ARGUMENTS ```

With no argument the block above is all of `~/.claude/PROTOCOL.md`; with one it is only the matching part (a layer by number, every section that mentions a rule id, or the sections whose heading contains the words). When it reports no match it lists the headings; re-invoke with one of them. Loading the whole file costs roughly 11,000 tokens, so name the layer or the rule when the question is about one.
