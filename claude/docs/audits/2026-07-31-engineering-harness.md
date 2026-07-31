# Engineering Audit: full `~/.claude` harness (2026-07-31)

## Scope and method

`~/.claude` on `main`, HEAD `71c044a` (`docs(rulebook): record the Ruby and Go analogs and exceptions for the enforced rules`), working tree clean, 4 commits ahead of `origin/main`.

Surfaces read: `CLAUDE.md`, all nine `CLAUDE-*.md` convention files plus `CLOUD-DEPLOYMENT.md` frontmatter, `rulebook/` (reference, agents, audits, cost), `rules/` (symlinks + `session-types.md`), `hooks/` (30 scripts + `clean-code-scan.mjs`), `hooks/tests/`, `enforce/` (configs, `lint.mjs`, `manifest.json`, 27 fixture tests), `agents/` + `audits/` role files, `prompts/`, `settings.json` + `settings.local.json`, `PROTOCOL.md`, `README.md`, `SETUP.md`, `ISSUES.md`, `docs/`. Excluded per dispatch: `projects/`, `sessions/`, and the other runtime trees; `global-memory/` inspected at structure level only; `[client-project]/` listed but not read.

Method: ran both fixture suites (`enforce/tests/run-tests.sh` 27/27 green in 32s, `hooks/tests/run-tests.sh` 7/7 green); verified the two 2026-07-31 P1 fixes and the P2 latency fix stand; executed `session-start.sh` live and inspected its emitted context; reproduced the R-403 staging bypass in a scratch repo; machine-diffed every rule ID and enforcer tag across `CLAUDE.md`, `rulebook/*.md`, and `enforce/manifest.json`; ran the credential-exposure sweep across the tracked tree, all git refs, shell history, vendor CLI config presence, and session transcripts (counts and masked context only, no values read into this report).

Prior-audit verification (dispatch item 1), all confirmed fixed and holding:

- `hooks/structure-gate.sh:46-54` now starts the scan at `app/` for Python and at `app|lib` / `internal|cmd|pkg` for Ruby / Go, so R-306/R-311/R-312 fire in the documented layouts.
- `hooks/enforcement-guard-check.sh:17-23,34` now maps all four AST prefixes (`eslint:`, `ruff:`, `rubocop:`, `golangci:`) in both directions, and `enforce/tests/enforcement-guard-check.test.sh` cases 4-5 pin the ruff, rubocop, and golangci gates.
- `enforce/tests/hook-latency.test.sh:17` now models all four push gates in `BASH_HOOKS`.
- `enforce/tests/manifest.test.sh` gained the `GATE_ARTIFACTS` closure check requiring each prefix's gate script and config to exist.

The Ruby/Go parity commits (`39b5954`, `6386053`, `3b328bd`, `71c044a`) spot-checked: hooks, manifest, settings registration, and fixtures are mutually consistent. The gaps they left are documentation, not enforcement (see P2-4 and P2-5).

---

## P0

### P0-1: a full-length, high-entropy Anthropic API key is stored in plaintext in a session transcript

The mandated credential sweep found one match that is not a placeholder:

```
FILE: ~/.claude/projects/-Users-[REDACTED]-Desktop-code-personal-projects-hacker-news-langchain/
      b7a2b69e-ad5e-48ae-a3b1-e2bf90fa142d/subagents/agent-a3a1f2c56a17ecf54.jsonl
  line 120, match length 108, distinct characters 48
  mtime 2026-07-31 12:49, size 847749 bytes
```

Masked context around the match (the value itself is removed, every other pattern hit in the window is masked):

```
..."type":"tool_result","content":"ANTHROPIC_API_KEY=[ANTHROPIC_MATCH]","is_error":false}...
```

The shape is decisive: a `sk-ant-api03-` prefix, 108 characters total, 48 distinct characters in the body (placeholders in this repo's fixtures are a single repeated `A`, distinct = 1), sitting in a `tool_result` whose content is `ANTHROPIC_API_KEY=<value>`. A command printed the live key and the raw tool output was persisted to the transcript. The file was last written today at 12:49.

Every other hit in the sweep is clean and was verified as such rather than assumed:

| Surface | Result |
|---|---|
| Tracked working tree | 2 files match: `hooks/secret-scan.sh` (the pattern definitions themselves) and `enforce/tests/credential-mutation-guard.test.sh` (all-`A` fixture). Compliant. |
| Git history, all refs | 5 commits touch the `sk-ant-api03-` literal, 3 touch `AKIA`; every one is a hook, guard, fixture, or audit-role file adding a pattern definition (`6cc5340`, `157b931`, `4b4ff74`, `2a05357`, `43277d4`). No credential in history. |
| `~/.zsh_history` (658 KB), `~/.bash_history` | 0 matches. |
| Vendor CLI configs | `~/.railway/config.json` (20 KB) and `~/.config/gh/hosts.yml` (4 KB) present; both left unread and unscanned per R-102 and the dispatch's explicit prohibition. Not scanned is recorded here rather than silently omitted; run the grep yourself in your own terminal. `~/.vercel/auth.json`, `~/.stripe/config.toml`, `~/.netrc`, `~/.anthropic` absent. |
| Session transcripts, all projects | 17 files match the broad pattern set; classified by entropy and masked context. All but one are placeholders (all-`A` fixtures from this repo's own tests, 9 files) or false positives (see P3-4). One real-like match: the P0 above. |

Governing rule: R-102/R-103, and the Credential Exposure Scan section of `agents/audit-engineering.md` ("Treat any full-length match as a P0 blocker").

Direction (three steps, all required, none performed by this audit): (a) rotate the key at the Anthropic console, never via a CLI that puts it on argv; (b) purge the persistence surface, which here means deleting that subagent JSONL (and checking whether the same command ran in the parent session transcript in the same project directory); (c) close the emission path, because the leak is structural, not a slip: `hooks/redact-output.sh` sets `suppressOutput: true` and re-emits a redacted copy as `additionalContext`, which protects what the model sees but does not change what Claude Code writes to the JSONL. Its pattern line 53 (`(SECRET|TOKEN|PASSWORD|CREDENTIAL|API[_-]?KEY|...)[=:][[:space:]]*[A-Za-z0-9_/+=~.-]{20,}`) would have matched this exact string, so the model most likely saw `[REDACTED]` while the transcript kept the plaintext. To confirm: whether the emitting command is identifiable from the same transcript (a `printenv`, `cat .env`, `railway variables`, or a deploy script echo), because the durable fix is a `PreToolUse` deny on that command shape, not a `PostToolUse` redaction that arrives after the value is already recorded.

---

## P1

### P1-1: the SessionStart hook cannot find the handoff doc at its own canonical path, and silently injects a stale audit report instead

`hooks/session-start.sh:46-54`:

```
46	# Look for the most recent handoff doc under $PWD/docs/audits/.
47	# Prefer session-handoff files; fall back to the newest dated audit.
48	HANDOFF=""
49	if [ -d "docs/audits" ]; then
50	  HANDOFF=$(ls -1t docs/audits/*session-handoff*.md 2>/dev/null | head -1 || true)
51	  if [ -z "$HANDOFF" ]; then
52	    HANDOFF=$(ls -1t docs/audits/????-??-??-*.md 2>/dev/null | head -1 || true)
53	  fi
54	fi
```

R-602 fixes the canonical location elsewhere: "Write handoffs to `docs/session-handoff/session-handoff.md` (overwrite)", and R-001 step 5 says "read `docs/session-handoff/session-handoff.md` if present". The hook never looks there. Run live in this repo, which has a current handoff at `docs/session-handoff/session-handoff.md` (4159 bytes, written 2026-07-31 03:34):

```
$ echo '{}' | bash hooks/session-start.sh | jq -r '.hookSpecificOutput.additionalContext' | grep -A2 'Most recent handoff'
## Most recent handoff doc (auto-loaded per R-001)

Path: docs/audits/2026-07-31-engineering.md
```

Two failures in one: the actual handoff is never loaded, and the fallback silently promotes an unrelated 188-line audit report into the session-start context labelled "Most recent handoff doc", spending context on the wrong document while the session believes R-001 step 5 was satisfied mechanically. The `session-start.sh:19` header comment ("the most recent handoff doc under `$PWD/docs/audits/`") is itself the runbook-vs-code drift: it documents the pre-restructure path as if it were current.

Governing rule: R-001 (step 5), R-602.

Direction: point the primary lookup at `docs/session-handoff/session-handoff.md` and decide deliberately whether the dated-audit fallback should exist at all (injecting an audit report under a "handoff" label is worse than injecting nothing). To confirm: whether any consumer still writes `docs/audits/*session-handoff*.md` (grep the skills and the session-end path), and whether `README.md:126`'s claim that the session "writes a handoff doc to `docs/audits/YYYY-MM-DD-session-handoff.md`" is a third stale path that needs the same correction. The reason this survived: `session-start.sh` has no fixture test (recorded as a P3 deferral in `ISSUES.md:11` since 2026-07-03), so nothing failed when the path convention moved.

### P1-2: the R-403 and R-507 commit guards are defeated by the `git add X && git commit` idiom this framework's own template prescribes

`hooks/fix-commit-requires-test.sh:90-96`:

```
90	# Check staged files. If git is not available or there is no staged
91	# diff, skip silently (the commit will fail for unrelated reasons and
92	# this hook should not add confusing noise).
93	STAGED=$(git diff --cached --name-only 2>/dev/null || true)
94	if [ -z "$STAGED" ]; then
95	  exit 0
96	fi
```

The hook runs at `PreToolUse`, before the command executes. When the staging and the commit are chained in one Bash call, the index is still empty when the hook looks, so `STAGED` is empty and the guard exits silently. Reproduced in a scratch repo (harness at `/private/tmp/.../scratchpad/r403case.sh`):

```
index entries before: 0
--- CASE A: chained add+commit, nothing staged yet ---
RESULT A: ALLOWED (hook emitted nothing)
--- CASE B: file staged first, bare commit ---
RESULT B: deny
```

Case A is `git add a.ts && git commit -m "fix: broken thing"` with no test file anywhere in the repo. `git commit -am "fix: ..."` fails the same way for the same reason. `hooks/conflict-markers.sh:16` (R-507) has the identical defect:

```
16	MARKERS=$(git diff --cached 2>/dev/null | grep -E '^[+](<{7}|={7}|>{7})' || true)
17	if [ -z "$MARKERS" ]; then
18	  exit 0
19	fi
```

This is not a hypothetical idiom. `prompts/subagent-branch-setup.md` (the R-702 reusable block) instructs every git-touching dispatch to use exactly this shape:

```
  git add <files> && \
  git commit -m "<subject>"
```

and R-702 itself mandates "verification and commit chained with `&&`". The framework's own dispatch template therefore routes agents down the path where two mechanical guards do not fire. It also explains the unpaired-fix history in P1-5: heredoc subject parsing landed 2026-05-27 (`157b931`), before all four unpaired `fix:` commits, so subject extraction was not the escape route.

Governing rule: R-403 (`hook:fix-commit-requires-test`), R-507 (`hook:conflict-markers`).

Direction: make the guards evaluate what the command will stage, not what is staged now, by parsing the `git add` targets out of the chained command and unioning them with the current index (or by treating an empty index on a chained `add`+`commit` as "unknown" and asking rather than allowing). To confirm: whether Claude Code exposes a `PreToolUse` re-entry after each `&&` segment (it does not, to my knowledge, which is why the parse has to happen in the hook); and whether tightening this to `ask` rather than `deny` on the unknown case is the right trade, given the guard must not block legitimate non-fix commits. Add fixture cases for the chained form to both `enforce/tests/` files; the current fixtures only exercise the pre-staged shape, which is why both suites are green while the guard is bypassable.

### P1-3: the entire LLM-judge enforcement tier is inert on this machine

`hooks/llm-rule-judge.sh:29-33`:

```
29	  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
30	    echo "llm-rule-judge: ANTHROPIC_API_KEY unset, skipping semantic gate" >&2
31	    exit 0
32	  fi
```

Checked in this environment:

```
$ [ -n "${ANTHROPIC_API_KEY:-}" ] && echo SET || echo UNSET
UNSET
```

Seven rules name `[judge]` as their only or primary enforcer in `CLAUDE.md` (R-315, R-316, R-317, R-318, R-320, R-322, R-325), and `enforce/manifest.json:40-46` records three of them at `"severity": "error"` in the `llm-judge` tier. With the key unset, every one of them is honor-system, and the only signal is a stderr line inside a push that succeeds. `README.md:56` describes the design goal as migrating prose rules to mechanical enforcement; this tier reads as mechanical in `CLAUDE.md` and in the manifest while being prose in practice.

The framework has a guard for exactly this class of drift, and it does not cover this case: `hooks/enforcement-guard-check.sh` verifies that every manifest-required hook is *registered* in `settings.json` and that every cited enforcer has a manifest entry. Registration is not operability. `llm-rule-judge.sh` is registered, so the guard is silent.

Governing rule: R-516 (the meta-rule that a rule with no working enforcement depends on recall), and the manifest's own `llm-judge` tier declaration.

Direction: extend the SessionStart guard from "is it registered" to "can it run", asserting the prerequisites each registered enforcer needs (the judge's API key, `node` for `clean-code-scan.mjs`, `jq` for everything) and warning loudly when one is absent; alternatively make the judge fail closed on push for `severity: error` rules. To confirm: whether the key is deliberately unset (a cost decision, in which case the honest fix is to demote those seven rules' tags in `CLAUDE.md` and the manifest to `manual` rather than leaving a mechanical claim standing), and whether Claude Code injects the key into hook environments differently from the Bash tool environment, which would make this a false positive; that check is a single `env | grep -c ANTHROPIC_API_KEY` inside a hook.

### P1-4: nothing runs the harness's own test suites

34 fixture tests exist (27 in `enforce/tests/`, 7 in `hooks/tests/`) and both runners work. Nothing triggers them:

```
$ ls -a ~/.claude | grep -iE 'github|gitlab|circle|travis|lefthook|husky'
none
$ git config core.hooksPath
(unset)
$ ls .git/hooks | grep -v sample
(no active git hooks)
```

There is no CI config, no `pre-push` hook, and no `PreToolUse` gate that runs either suite before a push of this repo. `hooks/global-repo-push-guard.sh` fires on push but only scans the outgoing diff for secrets and the real home path. R-509 ("run the full suite at pre-push") is therefore unenforced for the one repo whose entire purpose is enforcement, and the checks that live only in the suite go unrun: `enforce/tests/claude-md-lint.test.sh` (the CLAUDE.md 200-line budget and the CLAUDE.md-to-reference.md ID parity invariant) and `enforce/tests/manifest.test.sh` (manifest closure) are structural guards that currently execute only when a human remembers to type the command.

Governing rule: R-509; the audit role's standing authority to declare a missing operational basic a blocker.

Direction: wire both runners into a pre-push path that cannot be forgotten, most cheaply as a branch in the existing `global-repo-push-guard.sh` (it already detects "this push is from `~/.claude`") that runs both suites and denies on failure. To confirm: the suites take 32s and 4s here, so the added push latency is about 36s; check that against `enforce/tests/hook-latency.test.sh`'s budget philosophy before choosing between deny-on-red and warn-on-red, and confirm the guard's `deny` path is acceptable for a suite that shells out to `uvx ruff` and `node` (both fail open today).

### P1-5: the PreCompact hook injects a stale rule list that contradicts the current corpus

`hooks/pre-compact.sh:17-24` is the context the framework preserves at the moment a session is most likely to lose its rules:

```
17	1. Named exports only. Never export default (except Next.js App Router convention files and Storybook).
18	2. Alphabetical ordering is mandatory for type definitions, keys, props, imports.
19	3. One commit per task. Never accumulate across tasks.
20	4. Worktree per task. Never work directly on main.
21	5. Model routing: Sonnet default, Opus for complex/security/ambiguous, Haiku for trivial.
22	6. Never deploy without explicit user sign-off. Staging first, then ask before production.
23	7. CSRF: X-Requested-With header pattern. No token endpoint.
24	8. Shared types in packages/types/, shared constants in packages/constants/.
```

Item 8 contradicts the current architecture rule outright. `rulebook/reference.md:109-110`:

```
109	  - Shared packages take the project-agnostic `@repo/*` scope with canonical names: `@repo/types`, `@repo/constants`, ...
110	  - Never a project-scoped `@<project>/shared-types`; always `@repo/types`.
```

Item 4 has no basis in the corpus. R-501 is conditional ("Check for a parallel session on the same working tree before the first edit; **if one is active**, move to a worktree"), and R-512/R-514 both assume commits land on `main`. Item 2 overstates R-323 ("Sort sibling keys deterministically **where order is semantically free**; never reorder where position carries meaning") and contradicts `reference.md:248`, which requires React hooks in a fixed order and explicitly "never alphabetized". Item 5's "Sonnet default" is not what R-903 says. Only 4 of the 12 items carry a rule ID, so a compacted session cannot check any of the rest against the reference file.

Meanwhile the rules most expensive to lose are absent from the list entirely: R-102/R-103 (secrets), R-101 (destructive DB), R-207 (em dash), R-403 (test-first fixes).

Governing rule: the whole R-3xx/R-5xx/R-9xx corpus this file claims to summarize; R-206 (model-facing instructions) for the ID-less phrasing.

Direction: regenerate the injected list from the rule corpus rather than maintaining a hand-written parallel copy (the same failure mode `audits/engineering.md:5` records for the mirrored role files: "The two copies drifted"), and pick the surviving set by enforcement tier rather than by memory, preferring the rules with no mechanical backstop. To confirm: whether `PreCompact` `additionalContext` has a practical size ceiling that forces a short list, and which rules actually get violated post-compaction (`global-memory/rule_misses.md` is the evidence source; that log should decide the list, not intuition).

### P1-6: three unpaired `fix:` commits in the trailing 30 days

Scanning the last 60 commits (2026-06-26 to 2026-07-31, 54 of them inside 30 days) for fix-family subjects and checking each for a paired test-file change:

```
UNPAIRED 266d05e 2026-07-07 fix(enforce): mirror trivago Prettier group boundaries in import/order pathGroups
           enforce/eslint.config.mjs
UNPAIRED 7ffaffc 2026-07-03 fix(rules): drop phantom R-503 manifest entry and codify R-505 subject format
           CLAUDE.md
           enforce/manifest.json
UNPAIRED 9c01327 2026-07-03 fix(agents): migrate audit-role rule citations missed by the ID renumber
           agents/audit-*.md (9 files)
UNPAIRED 0ff5c68 2026-06-26 fix(enforce): exempt __tests__/__fixtures__/__mocks__ dirs from structure-gate and source-only lint rules
           enforce/eslint.config.mjs
           hooks/structure-gate.sh
```

Nine other fix-family commits in the window are correctly paired. Three unpaired land inside the trailing 30 days, which is the P1 threshold in the Bug Fix Discipline rubric. Honest qualification: `9c01327` and `7ffaffc` are prose and config edits where a reproducing test is arguable, and `266d05e` was already logged in `ISSUES.md:8`. `0ff5c68` is not arguable: it changed `hooks/structure-gate.sh` and the ESLint config, the two highest-blast-radius enforcement files, with no fixture.

Governing rule: R-403.

Direction: the behavioral fix is P1-2 (the guard that should have blocked these does not fire on the chained idiom); no retroactive action is needed on the shipped commits. To confirm: whether `0ff5c68`'s exemption behavior is covered today by a fixture added later under a different commit (grep `enforce/tests/structure-gate.test.sh` for `__fixtures__`/`__mocks__` cases); if it is, this is a paperwork gap rather than a coverage gap and should not recur as a finding.

### P1-7: `settings.json` auto-executes a repo-provided script on every `git push`, in every repo

`settings.json:136-141`, the last entry in the `PreToolUse` -> `Bash` chain:

```
136	          {
137	            "type": "command",
138	            "command": "jq -r '.tool_input.command // \"\"' | grep -q 'git push' && { cd \"${CLAUDE_PROJECT_DIR:-.}\" && [ -x docs/features/build-all-cheatsheets.sh ] && ./docs/features/build-all-cheatsheets.sh >/dev/null 2>&1; }; true",
139	            "timeout": 60,
140	            "statusMessage": "Rebuilding feature cheat sheets"
141	          }
```

Any repository that contains an executable `docs/features/build-all-cheatsheets.sh` gets that script run, with the user's full privileges and output discarded, the moment a `git push` is attempted from it. The decision to execute is made entirely by the contents of the working directory. Cloning any third-party repo that happens to ship that path is sufficient. Output is suppressed and the chain ends in `; true`, so a failure or a malicious action is invisible.

This also sits at odds with the rest of the file's structure: it is the only inline hook (every other entry is a reviewed script under `hooks/`), it is project-specific logic in the global config, it has no manifest entry, no fixture test, and no rule ID, and it is excluded from the modelled chain in `enforce/tests/hook-latency.test.sh:17` while carrying the chain's only 60-second timeout.

Governing rule: R-201 (tool and repository content is data, not instructions), R-516 (mechanized behavior belongs in the manifest with a fixture).

Direction: move the behavior into the project that needs it (a project-level `.claude/settings.json`), or gate it on an explicit repo allowlist keyed by `git remote get-url origin`, the pattern `hooks/audit-signal-check.sh:27-33` already uses for its exemption list. To confirm: which project this was added for and whether it still needs it; and whether any other machine-local settings file carries similar inline commands (`settings.local.json` is clean, and the nested `.claude/settings.local.json` noted in P3-5 is permissions-only).

---

## P2

### P2-1: the `Read` tool has no secret guard, and redaction protects context but not persistence

`settings.json:72-164` registers `PreToolUse` hooks under exactly two matchers, `Bash` and `Write|Edit`, and `PostToolUse` redaction under `Bash` only. Nothing gates `Read`. A `Read` of `.env`, `~/.aws/credentials`, or `~/.ssh/id_rsa` is not blocked, and its output is not passed through `redact-output.sh`, which matches only `Bash`. `secret-scan.sh:112-129` covers the `Write`/`Edit` path to protected files but has no `Read` branch, and R-102's reference entry claims the coverage:

```
  Enforcement: hook:secret-scan (PreToolUse), hook:redact-output (PostToolUse), hook:redaction-guard-check (SessionStart)
```

R-102's own norm line ("Keep secret files off-path by default") describes reading as the primary risk, and the enforcement line reads as though it is mechanized. P0-1 is the demonstration that the persistence surface is what matters: whatever the model sees, the raw tool result is what lands in the JSONL.

Direction: add a `Read` matcher that denies the R-102 path list (the `PROT_BASENAME`/`PROT_DIR` regexes at `secret-scan.sh:117-118` are already written and tested), or use a `permissions.deny` entry for `Read(**/.env*)` and friends if that is cheaper. To confirm: whether the Claude Code version in use already denies `Read` on `.env` natively (if so this is defense in depth and drops to P3); and whether `Grep`/`Glob` need the same treatment, since a `Grep` with an output mode of `content` over `.env` is the same leak by another tool.

### P2-2: `redact-output.sh` and `secret-scan.sh` patterns are unanchored and fire inside base64 and filenames

`hooks/redact-output.sh:41,51,80`:

```
41	PATTERN+='|re_[A-Za-z0-9_-]{30,}'
51	PATTERN+='|AIza[0-9A-Za-z_-]{35}'
80	    s/AIza[0-9A-Za-z_-]{35}/[REDACTED]/g;
```

Neither alternative is anchored to a token boundary. In the transcript sweep, the `AIza` pattern matched inside base64 payloads (masked context: `...btjhGWGxZirQJuGfDFM4xC0Wb0nXgyyTPqftsUYgVqDaEXD67MUfnId2FWegQKdp+ZEv6E3+MJCH9ZM/...`) and the `re_` pattern matched inside a file path (`git diff --no-index /tmp/p[RESEND_MATCH]`). Two consequences: the redaction hook silently corrupts legitimate Bash output by replacing a 39-character slice of a base64 blob with `[REDACTED]`, and every future credential scan starts with false positives that cost triage time (this audit spent a full pass distinguishing them, and the noise is exactly what makes a real P0 easy to wave off).

Direction: anchor each alternative on a non-token boundary (a leading `(^|[^A-Za-z0-9_/+=-])` guard, or `\b` where the pattern's first character allows it), and keep the pattern text identical across the three copies. To confirm: that anchoring does not break the existing fixtures in `enforce/tests/redact-output.test.sh` and `hooks/tests/global-repo-push-guard.test.sh`, both of which build tokens with a `ghp_`/`AAAA` prefix that a boundary guard must still match; and whether the three duplicated pattern blocks (`secret-scan.sh:48-69`, `global-repo-push-guard.sh:62-83`, verified byte-identical today; `redact-output.sh:30-53`, which carries two extra patterns) should finally be extracted to one sourced file, which `global-repo-push-guard.sh:14-16` already flags as accepted debt.

### P2-3: `CLAUDE.md` enforcer tags omit the Python, Ruby, and Go analogs the manifest and reference carry

Machine-diffing the bracketed tag in `CLAUDE.md` against the `Enforcement:` line in `rulebook/reference.md` for all 76 rules gives four substantive divergences, all in the same direction:

```
  R-324
    CLAUDE.md : [eslint:no-magic-numbers]
    reference : eslint:no-magic-numbers (numbers); ruff:PLR2004 via push-ruff-gate (Python comparisons); golangci:mnd via push-golangci-gate (Go); manual (strings)
  R-326
    CLAUDE.md : [eslint:no-restricted-syntax]
    reference : eslint:no-restricted-syntax; ruff:E731 via push-ruff-gate (Python)
  R-327
    CLAUDE.md : [eslint:no-nested-ternary]
    reference : eslint:no-nested-ternary; rubocop:Style/NestedTernaryOperator via push-rubocop-gate (Ruby)
  R-329
    CLAUDE.md : [eslint:no-explicit-any, eslint:ban-ts-comment]
    reference : eslint:no-explicit-any, eslint:ban-ts-comment; ruff:ANN401 + PGH003/PGH004 via push-ruff-gate (Python); golangci:nolintlint via push-golangci-gate (Go)
```

None of these four rules carries a `[ts]` stack tag, so all four are cross-stack, but the always-loaded file names only the TypeScript enforcer. A session doing Python or Go work reads `[eslint:no-magic-numbers]` and reasonably concludes the rule is a TypeScript concern. `CLAUDE.md`'s own preamble makes the tag load-bearing: "The trailing bracket names the enforcer". Two smaller instances of the same drift: R-102's tag omits `hook:redaction-guard-check`, and R-314's omits the `manual (tree mirroring)` half.

Direction: extend the four tags to name the analog gates (`[eslint:no-magic-numbers, ruff:PLR2004, golangci:mnd]`), accepting the line-length cost, or add one line to the preamble stating that the bracket names the TypeScript enforcer and that stack analogs live in `reference.md`. To confirm: the `enforce/tests/claude-md-lint.test.sh` 200-line budget (currently 118 lines, so there is headroom), and whether the ID-parity invariant in that test should be extended to enforcer-tag parity, which would have caught this mechanically.

### P2-4: `README.md` structural drift

Concrete, checked against the tree:

- `README.md:94-98` documents `rules/` as holding `session-types.md`, `agents.md`, `audits.md`, `cost.md`. Actual `rules/`: nine convention-file symlinks plus `session-types.md`; `agents.md`/`audits.md`/`cost.md` moved to `rulebook/` in the 2026-07-29 restructure. The word `rulebook` appears exactly once in the whole README (line 122).
- `README.md:60-117` repo layout omits `rulebook/`, `enforce/`, `ISSUES.md`, `CLAUDE-PYTHON.md`, `CLAUDE-RUBY.md`, `CLAUDE-GO.md`.
- `README.md:32` "the 26 hook scripts under `hooks/`, the 6 convention files"; actual counts are 30 hook scripts (plus `clean-code-scan.mjs`) and 9 `CLAUDE-*.md` convention files (10 with `CLOUD-DEPLOYMENT.md`). `README.md:47` and `:93` repeat the 26 and "18 more gates".
- `README.md:7` links `docs/audits/2026-04-08-criticism.md`; `docs/audits/` contains only the three dated engineering reports. Dead link in the "read this alongside the manifesto" callout.
- `README.md:51` attributes git hygiene to "`CLAUDE.md` R-401 family"; the git block is R-5xx.
- `README.md:126` describes handoffs at `docs/audits/YYYY-MM-DD-session-handoff.md`, contradicting R-602 (the same stale path as P1-1).

Direction: one pass reconciling the layout block, the counts, and the three path claims; the counts are cheap to derive at edit time rather than assert. To confirm: whether the counts should be in the README at all, since every one of them has drifted at least once.

### P2-5: `SETUP.md` drift, including a prerequisite that is missing and a verification step that runs 7 of 34 tests

`SETUP.md:36-41`:

```
36	## Stacks
37	
38	Two convention tracks load on demand by detected stack (see `rules/session-types.md`):
39	
40	- **TypeScript/Node** (`package.json`): ...
41	- **Python** (`pyproject.toml` / `requirements.txt` / `setup.py`): `CLAUDE-PYTHON.md`.
```

`rules/session-types.md:20-27` (updated by `39b5954` the same day) lists four tracks including `Gemfile` -> `CLAUDE-RUBY.md` and `go.mod` -> `CLAUDE-GO.md`. The setup doc a new machine follows is a track behind.

`SETUP.md:9` states "**python3** is needed only by `ntfy-notify.sh` (notifications). Everything else runs without it." Both claims are wrong: `enforce/tests/manifest.test.sh` shells out to `python3` for the closure check, and `node` is required but never listed as a prerequisite at all, though `hooks/clean-code-reminder.sh:23` depends on it:

```
23	summary=$(node "$(dirname "$0")/clean-code-scan.mjs" "$file_path" 2>/dev/null) || exit 0
```

That line fails open, so on a machine without `node` the R-322 advisory is silently dead, which is the same class of failure as P1-3.

`SETUP.md:45-51` offers this as the install verification:

```
for t in ~/.claude/hooks/tests/*.test.sh; do bash "$t"; done
```

That runs 7 of the 34 fixture tests; the 27 in `enforce/tests/` (including the manifest closure and CLAUDE.md lint invariants) are never executed by the documented verification.

Direction: add Ruby and Go to the Stacks section, add `node` to prerequisites with the honest statement of what silently degrades without it, and point the verification at both runners. To confirm: the minimum `node` version `clean-code-scan.mjs` needs, and whether `ruff`/`rubocop`/`golangci-lint` belong in prerequisites as optional-per-stack (each push gate fails open with a stderr note, which is a deliberate choice worth documenting rather than leaving implicit).

### P2-6: the Ruby and Go tracks shipped without the `README.md` update R-508 requires

```
$ git show --stat 39b5954
feat(conventions): add Ruby on Rails and Go stack tracks
 CLAUDE-GO.md           | 127 +++++
 CLAUDE-RUBY.md         | 153 +++++
 CLAUDE.md              |   2 +-
 rules/go.md            |   1 +
 rules/ruby.md          |   1 +
 rules/session-types.md |   4 +-
```

R-508: "Update `README.md` in the same commit when adding a user-facing feature or changing structure or setup." Two new stack tracks, two new auto-loading symlinks, and two new convention files are a structural change by any reading; no `README.md` or `SETUP.md` change is in this commit or in the three that follow it (`6386053`, `3b328bd`, `71c044a` touch hooks, tests, manifest, settings, reference, and ISSUES only). P2-4 and P2-5 are the resulting drift.

Direction: fold the README and SETUP updates into the current effort rather than a separate documentation pass. To confirm: whether R-508 should be mechanized for this repo specifically (a `PreToolUse` check that a commit touching `CLAUDE-*.md` or `rules/` also stages `README.md`), given it has now been missed silently.

### P2-7: the auto-loading convention files do not cover `services/` or `clients/`

`CLAUDE-BACKEND.md:1-11` frontmatter:

```
paths:
  - "**/src/handlers/**"
  - "**/src/repositories/**"
  - "**/src/middleware/**"
  - "**/src/routes/**"
  - "**/src/workers/**"
  - "**/src/dependencyInjection/**"
  - "**/src/schemas/**"
  - "**/src/prompts/**"
```

`CLAUDE-FRONTEND.md:1-9` frontmatter:

```
paths:
  - "**/*.tsx"
  - "**/src/components/**"
  - "**/src/features/**"
  - "**/src/state/**"
  - "**/src/hooks/**"
  - "**/src/api/**"
```

Neither lists `**/src/services/**` or `**/src/clients/**`, the two directories R-306 designates as the destination for all function-only modules ("function-only modules go to `services/` (business logic), `clients/` (third-party wrappers), or `api/`") and that R-307 and R-319 govern in detail. Editing `src/services/scoreCandidate.ts` auto-loads no convention file; the frontend `**/*.tsx` glob catches component work but not a `.ts` service or client module. The Python, Ruby, and Go tracks do not have this gap because they match on file extension (`**/*.py`, `**/*.rb`, `**/*.go`).

Direction: add the two globs to the backend file, and decide whether the TypeScript tracks should match on extension the way the newer tracks do (the risk being both files loading on every `.ts` edit; the current directory-based split exists to avoid that). To confirm: whether `src/config/`, `src/constants/`, and `src/types/` deserve the same treatment, and whether Claude Code's `paths:` matcher supports negation, which would allow an extension match minus the frontend directories.

### P2-8: two high-severity advisories in the enforcement toolchain, and ESLint a major version behind

```
$ cd ~/.claude/enforce && npm outdated
Package            Current  Wanted  Latest
eslint              9.39.4  9.39.5  10.8.0
typescript-eslint   8.62.0  8.65.0  8.65.0

$ npm audit --omit=dev
brace-expansion: DoS via unbounded expansion length causing an out-of-memory process crash (GHSA-mh99-v99m-4gvg)
js-yaml  4.0.0 - 4.2.0  Severity: high
js-yaml: YAML merge-key chains can force quadratic CPU consumption (GHSA-52cp-r559-cp3m)
2 high severity vulnerabilities
```

These dependencies execute on every `git push` from every TypeScript repo via `push-eslint-gate.sh` -> `lint.mjs`. Exploitability is low (the inputs are the operator's own source), but both advisories are DoS-class against the gate itself, and a hung or OOM-killed gate is a silently skipped check, not a loud failure.

Direction: run `npm audit fix` and take the ESLint 9 patch; treat the ESLint 10 major as a separate, tested change since the flat-config API surface `lint.mjs` uses (`cwd: "/"`, `basePath`) is exactly what majors move. To confirm: that `enforce/tests/eslint.test.sh`, `one-export-barrel.test.sh`, `import-direction.test.sh`, and `foreign-rule-stubs.test.sh` all stay green after the bump, and that `package-lock.json` is committed with it.

### P2-9: broad `allow` entries make the `ask` and `deny` permission lists bypassable

`settings.json:4-68` allows `Bash(bash *)`, `Bash(sh *)`, `Bash(cd *)`, `Bash(curl *)`, `Bash(node *)`, `Bash(perl *)`, `Bash(xargs *)` unconditionally, while the `ask` list gates specific commands:

```
58	    "ask": [
59	      "Bash(git commit --no-verify*)",
60	      "Bash(git commit -n *)",
61	      "Bash(git push --force*)",
...
67	      "Bash(rm -rf *)"
68	    ]
```

Permission matching is on the command string, so `bash -c "git push --force"` or `sh -c "rm -rf ~/x"` matches an `allow` prefix and never reaches the `ask` entry. The hook layer still sees the full string and is the real guard, which is why this is P2 and not higher, but the permission lists read as protection they do not provide. Related: `settings.json:306` sets `"skipDangerousModePermissionPrompt": true`, removing the confirmation step in front of dangerous mode, which sits awkwardly beside R-203 ("never bypass a guard without the word 'approved' from the user in the current turn").

Direction: decide explicitly whether the `ask` list is a real control or documentation; if real, the shell-wrapper entries need matching `ask` patterns, or the interpreters need to come off the blanket `allow`. To confirm: whether Claude Code's matcher inspects the full command string for nested invocations in the current version (test with a single `sh -c` wrapper around an `ask`-listed command), because the answer decides whether this is a real hole or a cosmetic one.

### P2-10: the notifier ships the project directory name to a public third-party endpoint and sources `.env`

`hooks/ntfy-notify.sh:8-9,21-29`:

```
 8	env_file="$HOME/.claude/.env"
 9	[ -f "$env_file" ] && . "$env_file"
...
21	cwd = d.get("cwd") or ""
22	proj = os.path.basename(cwd.rstrip("/")) if cwd else ""
...
29	curl -fsS -H "Title: Claude Code" -d "$message" "ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
```

Every Stop and Notification event posts `<message> (<project-directory-name>)` to `ntfy.sh` on an unauthenticated topic. ntfy.sh topics are readable by anyone who knows or guesses the topic name. Project directory names in this environment are client-identifying (the tree carries a client-named directory today). R-104 requires sanitizing artifacts before writing them and R-106 treats client-identifying content as the thing that must not leave; a third-party push endpoint is the same exposure class as a public git remote. Separately, line 9 sources the entire `.env` into the process that then makes the network call, which widens the blast radius of anything that file gains later.

Direction: send an opaque identifier instead of the directory basename (a short hash, or a fixed string), and read only `NTFY_TOPIC` from the env file instead of sourcing it wholesale. To confirm: whether the topic is already a high-entropy secret string (which mitigates but does not remove the exposure, since it also travels in the URL), and whether ntfy's auth-token mode is worth the setup.

### P2-11: R-903 routes audits to Opus; eight of nine audit agents are pinned to Sonnet

`rulebook/cost.md:15-22`:

```
15	R-903: Route work to the cheapest capable model.
16	  Spec:
17	  | Model | Use for |
19	  | Opus | Complex refactors, security-sensitive logic, ambiguous design, audits, multi-step planning |
```

Frontmatter across `agents/`: `audit-criticism`, `audit-design`, `audit-engineering`, `audit-financial`, `audit-legal`, `audit-marketing`, `audit-security`, `audit-ux` all declare `model: sonnet`; only `audit-customer` declares `model: opus`. Three of the nine (`audit-criticism`, `audit-engineering`, `audit-security`) carry an explicit "Model routing" section that documents the Sonnet default and the escalation criteria, which under the precedence rule is a documented override and not a violation. The other five Sonnet agents override R-903 silently, and `audit-customer` sits at Opus with no stated reason while `audit-security` (the security-sensitive one, by R-903's own wording) sits at Sonnet.

Direction: reconcile in one direction, either by amending R-903's table row to "audits: per the role file's Model routing section" or by adding the routing section to the five agents that lack it. To confirm: whether `audit-customer`'s Opus pin is deliberate; if it is, it needs the same documented rationale the other three have.

---

## P3

### P3-1: the judge's severity lookup ignores tier and breaks on multi-entry rules

`hooks/llm-rule-judge.sh:78`:

```
78	  severity=$(jq -r --arg id "$rule_id" '.rules[] | select(.id==$id) | .severity // "error"' "$MANIFEST" 2>/dev/null || echo "error")
```

Rules with more than one manifest entry return a multi-line string, so `[ "$severity" = "error" ]` on line 79 is false and the violation is downgraded to a stderr warning. Today this is harmless by luck: the judge-tier rules with two entries (R-320, R-322) are `warn` in both, so the outcome matches the intent. The moment a judge-tier rule gains an AST analog entry (exactly what happened to R-324, R-326, R-327, and R-329 in the last two weeks), an `error`-severity semantic rule silently stops blocking.

Direction: filter the lookup by `select(.id==$id and .tier=="llm-judge")`, or reduce with `any(.severity=="error")`. To confirm: whether any judge-tier rule is expected to carry a non-judge entry at a different severity, which decides between the two forms.

### P3-2: `audit-signal-check.sh` will not recognize this report as an audit

`hooks/audit-signal-check.sh:35`:

```
35	LAST_AUDIT=$(ls "$TOP/docs/audits" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-engineering\.md$' | sort | tail -1 || true)
```

The filename mandated by this audit's dispatch (`2026-07-31-engineering-harness.md`) does not match the anchored pattern, so the R-801 commit counter will keep measuring from `2026-07-31-engineering.md` and will re-fire the "5+ commits on a surface" advisory for work this audit already covered.

Direction: loosen the pattern to `^[0-9]{4}-[0-9]{2}-[0-9]{2}-engineering.*\.md$`, or standardize audit filenames so scoped variants still end in `-engineering.md`. To confirm: whether the other role reports (`-criticism.md`, `-security.md`) should also reset their own signals, which would make the pattern role-parameterized rather than engineering-only.

### P3-3: stale comments in the manifest test

`enforce/tests/manifest.test.sh:2-6` header:

```
 3	# and closure against the rule files: every hook:/eslint:/ruff: named in a CLAUDE.md
 4	# or rules/*.md Enforcement line has a manifest entry for that rule id, ...
```

The code below it covers five prefixes (`hook|eslint|ruff|rubocop|golangci`, line 22) and reads `rulebook/reference.md`, `agents.md`, `audits.md`, `cost.md`, not `CLAUDE.md` or `rules/*.md`. Cosmetic, but it is the comment a future maintainer trusts when adding the sixth prefix.

Direction: update both sentences with the prefix list and file set. To confirm: nothing; this is a comment edit.

### P3-4: credential-scan false-positive corpus, recorded so the next scan does not re-triage it

Of the 17 transcript files matching the broad pattern set, the following were verified benign and should not be re-escalated: nine files carry the all-`A` fixture key from this repo's own tests (distinct-character count 1); six `AIza` matches fall inside base64 blobs or inside the public Excalidraw OSS dev Firebase config (masked context: `VITE_APP_FIREBASE_CONFIG='{"apiKey":"[GOOGLE_MATCH]","authDomain":"excalidraw-oss-dev.firebaseapp.com"...`), where a Firebase web `apiKey` is a public client identifier by design and this one belongs to an open-source project, not to the operator; two `re_` matches are file paths, not Resend keys. See P2-2 for the pattern fix that removes this noise.

### P3-5: two secondary configuration surfaces are easy to forget

`~/.claude/.claude/settings.local.json` exists (a nested project-scoped settings file that applies whenever a session runs with cwd `~/.claude`, as this audit did), granting `WebSearch`, three `WebFetch` domains, and `Skill(update-config)`. It is gitignored by the bare `settings.local.json` pattern. Neither `README.md` nor `SETUP.md` mentions it. Separately, `SETUP.md:23` documents the top-level `settings.local.json` but not that a second one can shadow it per-directory.

Direction: document both, or fold the nested file's permissions into the top-level one and delete it. To confirm: whether the nested file was created intentionally or by a session running with cwd `~/.claude` and accepting a permission prompt.

### P3-6: the commit-message guard false-positives on command strings that merely quote a commit

Attempting to exercise the R-403 hook directly during this audit produced:

```
commit-message-guard BLOCKED this commit (R-505): subject '\"fix:' is not in conventional form
'type(scope): summary'. Types: feat|fix|chore|docs|refactor|test|perf|style|build|ci|revert.
```

The command was a `printf` of a JSON fixture piped into a hook; no commit was involved. The guard matches the substring anywhere in the command, including inside a quoted JSON literal. The fixture suites are unaffected (they run behind a single `bash run-tests.sh` string the guard never sees inside), so the cost is confined to ad-hoc hook verification, which is precisely the meta-work this repo does constantly. Worked around here by writing the fixture to a file and redirecting stdin.

Direction: require the `git commit` match to be at a command boundary rather than anywhere in the string, the way `global-repo-push-guard.sh:36` already anchors its `git push` detection with `(^|[;&|])[[:space:]]*`. To confirm: that anchoring does not lose the heredoc and `&&`-chained forms the guard must still catch.

---

## Workspace hygiene

No duplicate copy of the harness exists elsewhere on this machine: `find ~ -maxdepth 6 -name reference.md -path '*rulebook*'` returns only `~/.claude/rulebook/reference.md`, and no `CLAUDE-BACKEND.md` exists under `~/Desktop/code`, `~/code`, or `~/projects`. That is the good news. Three observations, none of which carry a deletion recommendation:

1. **A stale, client-named copy of the convention corpus lives inside the repo root.** `~/.claude/[client-project]/` holds seven files dated 2026-07-20: `CLAUDE.md` (73 lines, against the canonical 118), `CLAUDE-BACKEND.md` (701 lines, against the canonical 670), `CLAUDE-FRONTEND.md`, `CLAUDE-DATABASE.md`, `CLAUDE-STYLING.md`, `CLOUD-DEPLOYMENT.md`, plus two files with no counterpart in the current tree (`CLAUDE-MULTI-REPO.md`, `CLAUDE-SPEC-TO-BUILD.md`). It is kept out of git by `.git/info/exclude:7`, not by the tracked `.gitignore`. That distinction matters under R-106: `.git/info/exclude` is machine-local and unversioned, so a re-clone, a `.git` rebuild, or a `git add -f` re-exposes client-identifying content to a public remote. It is also a second answer to "what do the backend conventions say", one directory away from the canonical one.

2. **`~/.claude/.claude/`** holds the nested settings file described in P3-5.

3. **Stale project trees under `~/Desktop/pre-trash/`** (`freshbox`, `doppelscript-old`, `policy-pilot`) each carry their own `.claude/` directory, and `~/Desktop/code/personal/.claude/` sits at a code *root* rather than at a project, so it applies to every project beneath it. None affects the harness; noted because a root-level `.claude/` is the kind of thing that surprises you later.

Direction: produce a cleanup plan (not executed here) covering where `[client-project]/` should live, whether its exclusion belongs in the tracked `.gitignore` in the meantime, and whether the `~/Desktop/code/personal/.claude/` root-level settings directory is intentional.

## Verified clean (no finding)

- Rule-ID closure: every one of the 76 IDs in `CLAUDE.md` has a Spec block in `rulebook/reference.md` and vice versa; the R-7xx/R-8xx/R-9xx blocks live only in the tier-2 files by design, matching `CLAUDE.md`'s Blocks line. `enforce/tests/claude-md-lint.test.sh` already pins this invariant plus the 200-line budget (currently 118) and the "only `session-types.md` may sit un-frontmattered in `rules/`" rule.
- Manifest closure in both directions: no rule cites a mechanized enforcer without a manifest entry, and no manifest `hook:` enforcer names a missing script. All 30 hooks in `hooks/` are registered in `settings.json`; there is no dead hook and no phantom registration.
- All nine `rules/` symlinks resolve, and all nine convention files carry `paths:` frontmatter, so the auto-load mechanism the README describes actually works (with the coverage gap in P2-7).
- R-402's absence from the numbering is deliberate and recorded: `PROTOCOL.md:339` ("Retired current-scheme IDs: R-402 (2026-07-04) merged into R-403").
- The audit role pointer files under `audits/` and `audits/on-request/` all reference an existing `agents/audit-*.md` file, and the canonical-versus-pointer split described in `audits/engineering.md:5` holds.
- Both fixture suites pass in full (27/27 and 7/7), and the redaction hook demonstrably fired on this audit's own tool output during the credential sweep, replacing the fixture key with `[REDACTED]` in the model-visible context.
- `rules/session-types.md` is current with the Ruby and Go tracks and with the `rulebook/` tier-2 paths; the drift is in `SETUP.md`, not here.

## Prioritized recommendations

| # | Finding | Impact | Effort |
|---|---|---|---|
| 1 | Rotate the leaked Anthropic key, purge the transcript, and close the emission path (P0-1) | H | M |
| 2 | Fix the chained-staging bypass in `fix-commit-requires-test.sh` and `conflict-markers.sh`, with fixtures for the chained form (P1-2) | H | M |
| 3 | Point `session-start.sh` at `docs/session-handoff/session-handoff.md` and drop or relabel the audit fallback (P1-1) | H | S |
| 4 | Decide the judge tier's fate: supply the key, or demote the seven rules' tags to `manual` (P1-3) | H | S |
| 5 | Wire both test runners into the `~/.claude` push path (P1-4) | H | S |
| 6 | Regenerate `pre-compact.sh`'s injected rules from the corpus (P1-5) | H | M |
| 7 | Move or allowlist the inline cheat-sheet hook in `settings.json` (P1-7) | M | S |
| 8 | Add a `Read` guard for the R-102 path list (P2-1) | M | S |
| 9 | Anchor the secret patterns and consider extracting the three copies (P2-2) | M | S |
| 10 | Reconcile `README.md`, `SETUP.md`, and the four enforcer tags with the shipped tree (P2-3, P2-4, P2-5, P2-6) | M | M |

P2/P3 items for `ISSUES.md`: P2-1 through P2-11 and P3-1 through P3-6 as listed above.
