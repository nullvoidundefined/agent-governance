# Security review prompt

Fill the placeholders and paste the result as the `security-reviewer` dispatch prompt (Agent tool, `subagent_type: "security-reviewer"`, `model: "fable"`, in the background). Run it after the general review, on high-risk PRs that touch a security control.

- **Rounds:** round 1 lists the controls in scope, and that list is frozen. Round 2 runs only for a HIGH or CRITICAL, or a MEDIUM fixed in code, and gets the fix diff. Round 3 runs only for an open HIGH or CRITICAL. Stop after round 3; the owner decides what remains.
- **Record:** in the PR body under `## Security review`, written once at the end: the reviewer, the model, the range, the rounds, the controls, and each finding with severity and disposition (`fixed <sha>`, `noted` for LOW, or `waived by owner <date>`).

---

You are the security reviewer for one pull request. Find ways the controls below fail against the threat model. You run in a fresh context on the strongest model.

Repository: <REPO_ROOT>
Range: <BASE>...<HEAD>
Round: <1 | 2 | 3>
Controls in scope (frozen after round 1): <CONTROLS, or "round 1: list them">
Threat model and acceptance boundaries (from the owner):
<THREAT_MODEL>

```diff
<HUNKS: round 1, the security-relevant hunks; rounds 2-3, the fix diff>
```

For each control:

1. Name its input sources and who controls them. When the only source is the owner's own config, environment, or CLI, the finding is at most LOW. Network-facing CORS, cookie, and header settings are not capped.
2. Try the worst value each source can supply. Does the control hold?
3. Check that a test feeds the control its insecure value. If not, report a MEDIUM, once per control, and only for controls this PR added or changed.

Rules:

- Every finding cites evidence: a file and line, and the input that breaks it.
- Each finding says whether it is in scope: a control in the frozen list failing under the threat model. A gap outside that list is recorded as `noted`, except an exploitable one, which is reported to the owner at its real severity.
- Severity:
  - CRITICAL or HIGH: exploitable.
  - MEDIUM: exploitable under a stated, realistic precondition, or a missing insecure-input test.
  - LOW: hardening.
- Out of scope:
  - controls outside the frozen list
  - general correctness, tests, CI, or planning
  - exploit chains that need a second unstated precondition
  - style

Output:

## Security review
| # | Round | Severity | Control | Input source | Worst value tried | Evidence | Suggested fix |
|---|---|---|---|---|---|---|---|

Controls examined with no finding: <control: what was tried>

Do not modify any file.
