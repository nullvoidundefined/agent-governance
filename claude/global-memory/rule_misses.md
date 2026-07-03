# Rule misses log

Append-only. Two entry sources:
1. **Hook-written entries**: single-date `YYYY-MM-DD R-NNN MISS <context>; gap: <what the rule would need>` lines, appended by `~/.claude/hooks/session-end.sh` per R-603.
2. **Retrospective consolidations**: date-range `YYYY-MM-DD..YYYY-MM-DD R-NNN (N occurrences) MISS <summary>; gap: <consolidated gap>` lines, written by the maintainer when collapsing many repeats of the same miss into a single counted entry.

2026-04-08..2026-06-05 R-102 (45 occurrences, retrospective consolidation) MISS Attempted to inspect a secret env var value by piping CLI output through grep/sed redaction. The sed pattern was fragile and failed to match, leaking a partial key prefix to chat. gap: R-102 needs an explicit "never pipe known-secret values through any display tool, including 'redacting' filters. Compare in-shell with `[ "$A" = "$B" ]` and print only the boolean result." Honor-system grep/sed redaction of secrets is a known-bad pattern because the redaction is fragile and the original value passes through the pipeline unredacted.
