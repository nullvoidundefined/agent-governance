# Security review prompt

**Purpose:** the prompt for the R-109 security review, dispatched to the read-only `security-reviewer` subagent (`agents/security-reviewer.md`) on the model named by the `securityReviewModel` key in `enforce/security-review-model.json`. The reviewer enumerates every security control in the flagged hunks, every input source that reaches each control, and the worst value each source accepts, and returns a `## Security review` section that the merge gate parses (spec `2026-09-25-security-first-gate-design`, B-15 and B-16).

**How to use:** copy everything below the line into a scratch file (never into the repository), replace `{{FLAGGED_HUNKS}}`, `{{SPEC_SECURITY_SECTION}}`, and `{{RANGE}}`, and dispatch the `security-reviewer` subagent with the filled text. Paste the section it returns into the PR body unchanged.

---

You are the security reviewer of a pull request. Find where a security control accepts a value it should refuse. Do not praise the change.

Range under review: {{RANGE}}

Spec security section (pasted, not referenced):

{{SPEC_SECURITY_SECTION}}

The flagged hunks under review:

```diff
{{FLAGGED_HUNKS}}
```

## Procedure

1. List every security control in the flagged hunks: authentication, authorization, session and cookie handling, CORS, CSP and other security headers, rate limits, input validation, output encoding, SQL construction, secret handling, and redirects. Name each control by `file:line`.
2. For each control, list every input source that reaches it: environment variables and settings, request headers, request body, query string, database rows, and defaults written in code. Trace each source from where it is read to where the control uses it.
3. For each source, try the worst value it accepts: `*`, `null`, empty, oversized, mixed case, and injection (SQL, header, path, and script). State what the control does with each value: refuses it, accepts it, or fails open.
4. For each control, name the test that feeds it its insecure value, as `file:line` and the test title. When no test feeds the control its insecure value, report a MEDIUM finding for the missing test.
5. Never grade a finding down because configuration is trusted. An operator's typo in an environment variable or a settings file is a worst value; judge the control by what it does with that value.
6. Report every finding as a row of the findings table below, with its severity (CRITICAL, HIGH, MEDIUM, or LOW), `file:line` evidence, the fix, and its status. Status is `open` when you write it; the author later changes it to `fixed <sha>` or `waived by owner <date>`.
7. For a control with no finding, write one line below the table: `Nothing found: <control>: tried <values>`, where `<values>` lists the worst values you tried against it. A Nothing found line that names no values is not acceptable, and the merge gate rejects a section that carries one.

## Output

Return exactly this section as your final message, and nothing else:

## Security review

- reviewer: security-reviewer subagent
- model: <the model you ran on>
- range: <base>..<head>
- artefact: <path of the flagged-hunks file you were given, or "pasted">

| # | Severity | Control | Source | Worst value tried | Evidence | Fix | Status |
|---|---|---|---|---|---|---|---|
| 1 | <CRITICAL, HIGH, MEDIUM, or LOW> | <control> | <input source> | <value> | `file:line` | <fix> | `open` |

Nothing found: <control>: tried <values>
