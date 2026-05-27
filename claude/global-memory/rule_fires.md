# Rule fires log

Append-only. Two entry sources:
1. **Hook-written entries**: single-date `YYYY-MM-DD R-NNN <project> <context>` lines, appended by `~/.claude/hooks/session-end.sh` per R-305.
2. **Retrospective consolidations**: date-range `YYYY-MM-DD..YYYY-MM-DD R-NNN (N occurrences) <summary>` lines, written by the maintainer when collapsing many low-signal repeat fires into a single counted entry. These are read-only consolidations of prior hook output, not synthesized claims.

2026-04-08..2026-05-27 R-001 (36 occurrences, retrospective consolidation) no-em-dash.sh blocked Edit calls containing U+2014; replaced with colons or other punctuation on retry
2026-05-27 R-001 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-05-27 R-001 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
