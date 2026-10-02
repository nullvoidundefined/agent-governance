---
name: PL1-PL20 process learnings (moved)
description: Pointer only; the incident-backed PL rules moved into the stack convention files on 2026-10-02 (IAN-568)
type: feedback
---

The PL1 to PL20 incident-backed rules from the 2026-04-05/06 debug session no longer live here. On 2026-10-02 (IAN-568) each surviving rule moved into the convention file for its stack, so it loads only when that stack is touched:

- PL1, PL2, PL15, PL19: `CLAUDE-DATABASE.md`, "Incident-backed rules".
- PL3, PL11, PL12, PL20: `CLAUDE-FRONTEND.md`, "Incident-backed rules".
- PL5 to PL9: `CLAUDE-FRONTEND-NEXT.md`, "Incident-backed rules".
- PL13: `CLOUD-DEPLOYMENT.md`, "Incident-backed rules".
- PL14: R-331 in `rulebook/reference.md` (grep a regenerated lockfile).
- PL16 to PL18: `CLAUDE-BACKEND.md`, "Incident-backed rules: billing apps".
- PL4: deleted 2026-10-02 (IAN-568); duplicated by `feedback_audit_autonomy.md` and R-802, R-804.
- PL10: deleted 2026-10-02 (IAN-568); superseded by R-214 and R-603, and the `ISSUES.md` it named does not exist.
