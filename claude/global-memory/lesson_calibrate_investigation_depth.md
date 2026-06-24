---
name: lesson_calibrate_investigation_depth
description: Calibrate audit/investigation depth to stakes and to prior context. The second audit of the same session can reuse patterns from the first instead of re-investigating from scratch. Set a token budget upfront for any investigation, and stop when the evidence is sufficient.
type: feedback
---

**Calibrate investigation depth to the actual stakes, and reuse context from prior investigations in the same session.**

**Why:** On 2026-04-08 two audits ran back-to-back in the same session: the frontend first, then the backend. The frontend audit was comprehensive and appropriate for a C-grade surface the user had not looked at before. The backend audit was ALSO comprehensive when it did not need to be: by the time it ran, the session already had the full architectural picture from the frontend audit, the CLAUDE.md files were loaded, the convention files were in context, and the user's priorities were known. The backend audit could have been substantially lighter (focused on specific audit findings the user was most worried about) and still produced the same actionable output. Running it at full frontend-audit depth cost probably 80-100k tokens that did not need to be spent.

**How to apply:**

- **Set a token budget before starting.** Ask: is this a greenfield investigation where I know nothing, a targeted check where I am verifying a specific concern, or a follow-on investigation where I already have most of the context? Calibrate depth to the answer.
  - Greenfield audit (never seen the codebase): full depth, comprehensive investigation, worth 200k+ tokens.
  - Targeted check (specific concern): focused investigation, 30-60k tokens, five to ten files.
  - Follow-on investigation (same session, same user, related surface): reuse prior context aggressively, investigate only the delta, 20-40k tokens.
- **Reuse what the session already knows.** If an earlier investigation in the same session loaded the conventions, explored the architecture, and surfaced the main findings, do not re-explore. Explicitly note what is carried over ("I already have the CLAUDE.md conventions, the top-level architecture, and the known pain points from the frontend audit; skipping those") and investigate only the new surface.
- **Stop when the evidence is sufficient, not when the checklist is complete.** A thorough audit has a checklist of sections to cover. But if the answers to half those sections are obvious from the first few file reads, do not belabor the remaining sections. The audit report should still have the sections (for structure), but the evidence-gathering work for each can be proportional to how much is actually in question.
- **Prefer a second, shorter audit later over a massive audit now.** If a surface looks fine on a light pass but you are not certain, file a note and come back in a separate session with a targeted follow-up. A 30k-token check today plus a 30k-token targeted follow-up next week is cheaper than a 150k-token comprehensive audit that might not reveal anything new.

**When full-depth investigation IS correct:**

- First look at a codebase
- Pre-launch sweeps where missing something costs customer trust
- Security audits (missing something costs incidents)
- Criticism audits (the whole point is to look where nobody else is looking)
- Post-incident investigations where the failure mode is unknown

**When reduced depth is correct:**

- Second audit of a related surface in the same session
- Routine recurring audits (weekly, monthly cadence)
- Audits with a narrow brief ("focus on X")
- Audits where the user already knows the main concerns and just wants validation

**Evidence:** the 2026-04-08 backend audit ran at full frontend-audit depth when it could have been ~40% of the size for the same actionable output. The backend was graded B+ and the three real findings (session invalidation, AI output-scoring calibration, worker timeout) would have surfaced in a targeted investigation focused on auth, AI output parsing, and worker reliability. The full architecture sweep added context but not new findings.
