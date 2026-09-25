# Security review prompt

**Purpose:** the prompt for the R-109 security review, dispatched to the read-only `security-reviewer` subagent (`agents/security-reviewer.md`) on the model named by the `securityReviewModel` key in `enforce/security-review-model.json`. The reviewer enumerates every security control in the flagged hunks, every input source that reaches each control, and the worst value each source accepts, and returns a `## Security review` section that the merge gate parses (spec `2026-09-25-security-first-gate-design`, B-15 and B-16).

**How to use:** copy everything below the line into a scratch file (never into the repository), replace `{{FLAGGED_HUNKS}}`, `{{SPEC_SECURITY_SECTION}}`, `{{RANGE}}`, `{{MODEL}}`, and `{{ARTEFACT_PATH}}`, and dispatch the `security-reviewer` subagent with the filled text. Paste the section it returns into the PR body unchanged.

**Model and artefact:** the dispatcher reads the `securityReviewModel` key from `claude/enforce/security-review-model.json` and passes that value both as the Agent tool's `model` parameter and as `{{MODEL}}`; the agent's frontmatter names no model. The dispatcher fills `{{ARTEFACT_PATH}}` with the path where it will save the reviewer's raw output.

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

1. List every security control in the flagged hunks: authentication, authorization, session and cookie handling, CORS, CSP and other security headers, rate limits, input validation, output encoding, SQL construction, secret handling, and redirects. Name each control by `file:line`. A hunk that changes an input source (a settings field, an environment read, a parsed header) brings the control that consumes that source into scope, even when the control sits outside the hunks; find it and list it. When the range carries no security control at all, you must write the required line `No security control in range: <paths inspected>` in place of the table, naming every path you inspected.
2. For each control, list every input source that reaches it: environment variables and settings, request headers, request body, query string, database rows, and defaults written in code. Trace each source from where it is read to where the control uses it.
3. For each source, try the worst value it accepts: `*`, `null`, empty, oversized, mixed case, and injection (SQL, header, path, and script). State what the control does with each value: refuses it, accepts it, or fails open.
4. For each control, name the test that feeds it its insecure value, as `file:line` and the test title. When no test feeds the control its insecure value, report a MEDIUM finding for the missing test.
5. Never grade a finding down because configuration is trusted. An operator's typo in an environment variable or a settings file is a worst value; judge the control by what it does with that value.
6. Report every finding as a row of the findings table below, with its severity (CRITICAL, HIGH, MEDIUM, or LOW), `file:line` evidence, the fix, and its status. Status is `open` when you write it; the author later changes it to `fixed <sha>` or `waived by owner <date>`.
7. Number the rows from 1 in output order. After you return the section, only the Status cell may be edited; no row is removed or renumbered.
8. For a control with no finding, write one line below the table: `Nothing found: <control>: sources <sources>: tried <values>`, where `<sources>` lists the input sources and `<values>` lists the worst values you tried against it. Every source you enumerated for that control in step 2 must appear on its Nothing found line. A Nothing found line that names no values is not acceptable, and the merge gate rejects a section that carries one.

## Output

Return exactly this section as your final message, and nothing else. Copy `{{MODEL}}` verbatim into the model line and `{{ARTEFACT_PATH}}` verbatim into the artefact line; do not substitute your own description of either.

## Security review

- reviewer: security-reviewer subagent
- model: {{MODEL}}
- range: <base>..<head>
- artefact: {{ARTEFACT_PATH}}

| # | Severity | Control | Source | Worst value tried | Evidence | Fix | Status |
|---|---|---|---|---|---|---|---|
| 1 | <CRITICAL, HIGH, MEDIUM, or LOW> | <control> | <input source> | <value> | `file:line` | <fix> | `open` |

Nothing found: <control>: sources <sources>: tried <values>

When the range has no security control, the table and the Nothing found lines are replaced by this one line:

No security control in range: <paths inspected>
