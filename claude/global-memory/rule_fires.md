# Rule fires log

Append-only. Two entry sources:
1. **Hook-written entries**: single-date `YYYY-MM-DD R-NNN <context>` lines, appended by `~/.claude/hooks/session-end.sh` per R-603.
2. **Retrospective consolidations**: date-range `YYYY-MM-DD..YYYY-MM-DD R-NNN (N occurrences) <summary>` lines, written by the maintainer when collapsing many low-signal repeat fires into a single counted entry. These are read-only consolidations of prior hook output, not synthesized claims.

2026-04-08..2026-05-27 R-207 (36 occurrences, retrospective consolidation) no-em-dash.sh blocked Edit calls containing U+2014; replaced with colons or other punctuation on retry
2026-05-27 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-05-27 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-05-28 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-05-29 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-05-30 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-05-31 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-06-01 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-06-02 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-06-03 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-06-04 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-06-05 R-207 no-em-dash.sh blocked an Edit during CLAUDE.md trim; bullet list separators contained U+2014, replaced with colons on retry
2026-08-01 eslint-ast (auto-rollup: 1 deny fire(s) this session)
2026-08-01 R-315 (auto-rollup: 5 deny fire(s) this session)
2026-08-01 R-316 (auto-rollup: 1 deny fire(s) this session)
2026-08-01 R-403 (auto-rollup: 2 deny fire(s) this session)
2026-08-01 R-324 (auto-rollup: 1 deny fire(s) this session)
2026-08-01 R-207 (auto-rollup: 3 deny fire(s) this session)
2026-08-01 R-403 (auto-rollup: 1 deny fire(s) this session)
2026-08-01 R-207 (auto-rollup: 6 deny fire(s) this session)
2026-08-02 eslint-ast (auto-rollup: 2 deny fire(s) this session)
2026-08-02 ruff-ast (auto-rollup: 1 deny fire(s) this session)
2026-08-02 R-207 (auto-rollup: 3 deny fire(s) this session)
2026-08-03 R-506 (auto-rollup: 2 ask fire(s) this session)
2026-08-03 R-207 (auto-rollup: 5 deny fire(s) this session)
2026-08-05 R-505 (auto-rollup: 1 deny fire(s) this session)
2026-08-05 R-505 (auto-rollup: 1 deny fire(s) this session)
2026-08-05 eslint-ast (auto-rollup: 2 deny fire(s) this session)
2026-08-05 eslint-ast (auto-rollup: 2 deny fire(s) this session)
2026-08-05 R-403 (auto-rollup: 8 deny fire(s) this session)
2026-08-05 R-403 (auto-rollup: 8 deny fire(s) this session)
2026-08-05 R-506 (auto-rollup: 21 ask fire(s) this session)
2026-08-05 R-506 (auto-rollup: 21 ask fire(s) this session)
2026-08-05 R-207 (auto-rollup: 8 deny fire(s) this session)
2026-08-05 R-207 (auto-rollup: 8 deny fire(s) this session)
2026-08-07 R-312 (auto-rollup: 2 deny fire(s) this session)
2026-08-07 R-506 (auto-rollup: 2 ask fire(s) this session)
2026-08-07 R-207 (auto-rollup: 3 deny fire(s) this session)
2026-08-11 R-505 (auto-rollup: 1 deny fire(s) this session)
2026-08-11 eslint-ast (auto-rollup: 1 deny fire(s) this session)
2026-08-11 R-513 (auto-rollup: 2 ask fire(s) this session)
2026-08-11 R-506 (auto-rollup: 2 ask fire(s) this session)
2026-08-11 R-207 (auto-rollup: 2 deny fire(s) this session)
2026-08-17 R-505 (auto-rollup: 2 deny fire(s) this session)
2026-08-17 eslint-ast (auto-rollup: 3 deny fire(s) this session)
2026-08-17 R-403 (auto-rollup: 2 deny fire(s) this session)
2026-08-17 R-506 (auto-rollup: 12 ask fire(s) this session)
2026-08-17 R-207 (auto-rollup: 18 deny fire(s) this session)
2026-08-20 eslint-ast (auto-rollup: 1 deny fire(s) this session)
2026-08-20 R-403 (auto-rollup: 1 deny fire(s) this session)
2026-08-20 R-506 (auto-rollup: 2 ask fire(s) this session)
2026-08-20 R-207 (auto-rollup: 7 deny fire(s) this session)
2026-08-20 R-506 (auto-rollup: 2 ask fire(s) this session)
2026-08-20 R-207 (auto-rollup: 3 deny fire(s) this session)
2026-08-20 R-506 (auto-rollup: 1 ask fire(s) this session)
2026-08-20 R-207 (auto-rollup: 12 deny fire(s) this session)
2026-09-04 R-207 (auto-rollup: 3 deny fire(s) this session)
2026-09-04 R-501 (auto-rollup: 1 warn fire(s) this session)
2026-09-04 R-501 (auto-rollup: 3 warn fire(s) this session)
2026-09-04 R-501 (auto-rollup: 2 warn fire(s) this session)
2026-09-04 R-501 (auto-rollup: 4 warn fire(s) this session)
2026-09-04 R-105 (auto-rollup: 16 ask fire(s) this session)
2026-09-04 R-514 (auto-rollup: 3 ask fire(s) this session)
2026-09-04 R-207 (auto-rollup: 1 deny fire(s) this session)
2026-09-04 R-501 (auto-rollup: 2 warn fire(s) this session)
2026-09-04 R-514 (auto-rollup: 2 ask fire(s) this session)
