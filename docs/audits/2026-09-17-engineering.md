# Engineering Audit: 2026-09-17

Role: CTO / Engineering (`claude/agents/audit-engineering.md`).
Trigger: R-801 signal at push time, 5+ commits on `claude/enforce` since the baseline commit `be7b5f0` of `docs/audits/2026-09-16-engineering.md`.
Scope: `claude/enforce/` (manifest, lexicon, ESLint rule bundle, ratchet, `tdd.sh`, role policy, `hook-hashes.txt`, and the fixture suite under `claude/enforce/tests/`), plus `translate/*.mjs` as the code `claude/enforce/tests/translate-codex.test.sh` is the fixture for, plus the `claude/hooks/` scripts that read or write `enforce/` data where the fixture suite is the only thing proving them.
Out of scope: `codex/`, `cursor/`, `sync-tests/`, `claude/skills/`, `claude/global-memory/`, the rest of `claude/hooks/`.
Discipline: R-802, R-804. Every finding pastes real content with `file:line`, names the governing rule, and carries a severity. Fixes are directions plus `to confirm`, never patches. Nothing in this report was applied, and no git write command was run.
Prior report read first: `docs/audits/2026-09-16-engineering.md`. Its P0-1, P1-1, P1-2, P1-3, P1-4, P2-2, P2-7, P2-8, P2-11, P2-12, P3-3, P3-4 remediations were verified closed during this audit and are not re-reported.

---

## Finding counts

| Severity | Count |
|---|---|
| P0 | 0 |
| P1 | 4 |
| P2 | 8 |
| P3 | 7 |

Findings are ordered by severity. Every P1 and P2 below was reproduced empirically during this audit except P2-4 and P2-8, which are read from code and marked as such.

---

## Executive Summary

The surface is in materially better shape than the 2026-09-16 audit found it. Twelve of that report's findings are genuinely closed, the closures were done with fixtures rather than with prose, and several were closed the durable way: `repo-identity.sh` now centralizes repo identity, `verification-gate.sh` has a monorepo discovery branch, the `set -e` fail-open convention is written into `enforce/README.md` and backed by a mechanical fixture, and the P3-3 fixture tokens are now built at runtime, which this audit confirmed by finding zero credential-pattern matches anywhere in the working tree. Both suites are green: 54 enforcement fixtures and the hook suite, run locally during this audit.

The problem this audit found is that the enforcement surface protects the things it enumerates and is silent about the things it does not, and nothing checks the enumeration. Three separate mechanisms share that shape. `hook-hashes.txt` is closed in neither direction: it can name a file that does not exist (which is what commit `7eb41b5` just deleted four instances of) and it does not name the fixture suite, `judge-prompt.md`, or any of `translate/`, so an edit to the tests that prove the gates is invisible to the guard that exists to catch exactly that. `deny-tier-set-convention.test.sh` keys on the literal string `permissionDecision`, so the two guards that emit `decision: "block"` and an `additionalContext` leak warning sit outside the convention they were written to be covered by, and both still run `set -euo pipefail`. And `secret-scan.sh`'s R-103 redirect pattern matches a `.env` at a token boundary only, so `> server/.env` writes to a credential file unblocked, while the fixture that should catch it tests only the bare `.env` spelling.

The deeper pattern: every one of these is a case where the artifact that would have detected the gap is itself the artifact with the gap. That is the failure mode this repo exists to eliminate, and it is the one category where the repo has no meta-check.

**Top 3 priorities**

1. **P1-1**: deleting `claude/enforce/hook-hashes.txt` silently disables the R-203 integrity guard with zero output, and `--update` writing an empty file has the same permanent effect. Reproduced.
2. **P1-3**: `secret-scan.sh`'s R-103 mutation guard does not block a redirect to a `.env` in a subdirectory (`> server/.env`), which is the normal shape in every monorepo. Reproduced. The Write/Edit branch of the same hook handles it correctly, which shows the intent.
3. **P1-2 / P1-4**: the hash manifest does not cover the fixture tree or `translate/`, and `deny-tier-set-convention.test.sh` reports PASS having inspected zero hooks. Both reproduced. These are the two "green dashboard over a weakened gate" instances the dispatch asked about, and both are present.

---

## Operational Basics

| Check | Status | Evidence |
|---|---|---|
| Enforcement fixtures run and pass | **YES** | `bash claude/enforce/tests/run-tests.sh` during this audit: 54 fixtures, `ALL ENFORCEMENT TESTS PASS`. |
| Hook fixtures run and pass | **YES** | `bash claude/hooks/tests/run-tests.sh` during this audit: `ALL HOOK TESTS PASS`. |
| Runners reject a partial pass | **YES** | Both runners now carry `&& ! printf '%s' "$out" \| grep -q "FAIL"`. Verified against every exit path; see "Testing" for the residual holes, which are P3. |
| Hash-manifest integrity (repo tree) | **YES** | `CLAUDE_INTEGRITY_ROOT=<repo>/claude claude/hooks/hook-integrity-check.sh` emits nothing. The four phantom entries from `7eb41b5` are gone and the 73 remaining entries match the tree. |
| Hash manifest closed over the surface | **NO (blocker)** | P1-2. Fixture tree, `judge-prompt.md`, `gate-trusted-repos.txt`, `enforce/package*.json`, and all of `translate/` are uncovered. |
| Integrity guard fails closed | **NO (blocker)** | P1-1. Reproduced: manifest absent, hook tampered, guard silent, exit 0. |
| Manifest <-> rule-file closure | **YES** | `manifest.test.sh` green. Independently recomputed: 96 manifest rules, zero rulebook `Enforcement:` lines citing an enforcer with no manifest entry, zero `hook:` enforcers naming a missing script. |
| Manifest <-> fixture closure (R-516 second clause) | **NO** | P2-3. Five manifest enforcers have no fixture case exercising them. Neither `manifest.test.sh` nor `enforcement-guard-check.sh` checks this. |
| CI workflow defined and gates the suites | **YES (definition)** | `.github/workflows/enforce.yml` runs both suites, `shellcheck --severity=error`, `node translate/codex.mjs --check`, and the ratchet. |
| CI actually green | **UNVERIFIABLE HERE** | `gh` is not installed in this environment. Not recorded as a finding; the workflow definition was reviewed instead. The user should confirm with `gh run list`. |
| Local pre-push gate correct | **YES (content)** | `claude/hooks/pre-push.sample:28-51` now resolves suites from the pushed repo and also runs the translator check. Whether it is *installed* cannot be determined from this checkout: `.git/hooks` is untracked local state and this container's copy has only samples. Not a finding. |
| Turn-end R-509 gate covers the surface | **PARTIAL** | P2-5. `verification-gate.sh` discovers both suites via the monorepo branch (the 2026-09-16 P1-1 fix works) but omits the translator check that pre-push and CI both run. |
| Judge tier can run | **NO (documented)** | `enforcement-guard-check.sh` warns correctly: 3 llm-judge rules, no key, no `judge-accepted-honor-system` file. Reproduced. Documented in `claude/rulebook/cost.md`; a documented override, not a finding. See P2-4 for the separate tier-accounting defect. |
| Rollback plan | **PARTIAL** | Git history is the rollback for the repo. `sync.sh` still has no reverse path, and it never deletes, which is the documented and deliberate trade but is also the mechanism behind P1-2. |

---

# P1 findings

## P1-1: deleting or emptying `hook-hashes.txt` silently disables the R-203 integrity guard

**Severity: P1, blocker.** Governing rules: R-203 (`claude/CLAUDE.md:34`, `[hook:hook-integrity-check]`), R-405 (never weaken the protection that surfaced the failure). Manifest entry: `{"id": "R-203", "tier": "advisory", "enforcer": "hook:hook-integrity-check", "severity": "warn"}`.

`claude/hooks/hook-integrity-check.sh:35-37`:

```bash
cat >/dev/null 2>&1 || true   # drain stdin

[ -f "$HASH_FILE" ] || exit 0
```

The hook's own header states the threat model it exists to defeat, `claude/hooks/hook-integrity-check.sh:2-5`:

```bash
# hook-integrity-check.sh: SessionStart guard verifying that the enforcement
# surface on disk matches the committed hash manifest. One silent Write of
# `exit 0` into a guard hook would otherwise disable it forever (2026-07-31
# security audit P1: registration and existence were checked, content never).
```

One silent *delete* of `hook-hashes.txt` achieves the identical result, with no warning at all. Reproduced during this audit against a throwaway `CLAUDE_INTEGRITY_ROOT`:

```
--- baseline clean (expect empty):
[end]
--- now DELETE the hash file, then tamper the guard:
[end, exit=0]
--- now EMPTY hash file, tampered guard:
{ "hookSpecificOutput": { ... "enforcement files on disk do NOT match the committed hash manifest: enforce/manifest.json hooks/sample-guard.sh" ... } }
[end, exit=0]
```

The middle case is the finding: the sandbox's `hooks/sample-guard.sh` had been rewritten to `# TAMPERED, gate disabled` and the guard produced nothing. The third case shows the guard does work when the file is present but empty, which narrows the exposure but introduces the second half of the finding.

Second half, same root cause, opposite direction. `claude/hooks/hook-integrity-check.sh:28-32`:

```bash
if [ "${1:-}" = "--update" ]; then
  compute_hashes > "$HASH_FILE"
  echo "hook-integrity-check: wrote $(wc -l < "$HASH_FILE" | tr -d ' ') hashes to $HASH_FILE"
  exit 0
fi
```

and `claude/hooks/hook-integrity-check.sh:24-26`:

```bash
compute_hashes() {
  (cd "$CLAUDE_DIR" && { ls hooks/*.sh hooks/*.mjs hooks/*.py enforce/*.sh enforce/*.yml enforce/*.toml enforce/*.mjs enforce/rules/*.mjs enforce/manifest.json enforce/lexicon.json enforce/role-policy.json 2>/dev/null || true; } \
    | sort | { xargs shasum -a 256 2>/dev/null || true; })
}
```

Both the `ls` and the `xargs shasum` are wrapped in `2>/dev/null || true`. If `shasum` is not resolvable, or `CLAUDE_DIR` points somewhere with no `hooks/` or `enforce/`, `compute_hashes` returns the empty string and `--update` truncates the manifest to zero bytes, printing `wrote 0 hashes`. Every subsequent run then diffs empty against empty, finds no drift, and is permanently, silently satisfied. There is no floor assertion on the count, and the reassuring success message is printed either way.

`shasum` resolves on this machine and on both target hosts, so the trigger for the empty-write path is narrow. The delete path needs no unusual condition at all.

**Fix direction.** Make both an absent manifest and an implausibly small one loud rather than silent: replace the `[ -f "$HASH_FILE" ] || exit 0` early return with an `additionalContext` warning naming the missing manifest, and give `--update` a floor (refuse to write, and refuse to overwrite an existing non-empty manifest, when `compute_hashes` yields fewer entries than some minimum or fewer than the file it is replacing). `to confirm:` whether any legitimate first-run or bootstrap path depends on the silent exit when the manifest is genuinely absent (`install-git-hooks.sh` and `sync.sh` were both read and neither creates it, so the manifest should always exist post-clone, but a fresh `~/.claude` before the first `sync.sh` may not have it); and whether the floor should be a hardcoded number or a comparison against the outgoing file, since the latter needs no maintenance and also catches a partial regeneration.

## P1-2: the hash manifest is closed in neither direction, and nothing mechanical checks either

**Severity: P1, blocker.** Governing rules: R-203, R-516 (register every mechanizable rule, ship a fixture test), R-403 (fix bugs test-first).

This is the structural answer to the dispatch's question about the four phantom entries. Both holes are open.

### Forward hole: the manifest can name a file that does not exist

Commit `7eb41b5` deleted four such entries. The diff, `git show 7eb41b5`:

```diff
-a4f8fb101646284abf1506805e4a000f3782e146d5908484b031504fc707f5f6  enforce/eslintOptions.mjs
-91baea1e573eea4add8b25e656ece34a098d3e7794bedf7c6d821be6dddf7fcc  enforce/renderLexiconSpec.mjs
-2e834059ea61c8b5f64208101e97c8550ea53f59fc2c52c0441834e0e9d26638  enforce/resolveOutgoingBase.sh
-e3f9d8d09cf460f760b837dbdf1af1c461835881cc57395c19658120fe817cf1  hooks/single-file-folder-gate.sh
```

Those four names were retired by commit `0dda163`, which renamed them:

```
R100	claude/enforce/eslintOptions.mjs	claude/enforce/eslint-options.mjs
R088	claude/enforce/renderLexiconSpec.mjs	claude/enforce/render-lexicon-spec.mjs
R093	claude/enforce/resolveOutgoingBase.sh	claude/enforce/resolve-outgoing-base.sh
R089	claude/hooks/single-file-folder-gate.sh	claude/hooks/single-file-folder-reminder.sh
```

and the same commit's `hook-hashes.txt` diff shows the new names being *added* beside the old ones rather than replacing them:

```diff
+a4f8fb101646284abf1506805e4a000f3782e146d5908484b031504fc707f5f6  enforce/eslint-options.mjs
 a4f8fb101646284abf1506805e4a000f3782e146d5908484b031504fc707f5f6  enforce/eslintOptions.mjs
```

Two identical hashes under two names is the signature of a regeneration run against a tree that held both files. That tree is the live copy, because that is what the hook's own instructions tell the operator to regenerate, `claude/hooks/hook-integrity-check.sh:7-8`:

```bash
# Warns via additionalContext, never blocks. After INTENTIONAL hook changes,
# regenerate and commit the manifest:
#   ~/.claude/hooks/hook-integrity-check.sh --update
```

That command writes `$HOME/.claude/enforce/hook-hashes.txt`. And `sync.sh` deliberately never prunes, `sync.sh:19-25`:

```bash
# Never deletes anything from a live directory (no rsync --delete). An
# earlier version did, gated by a hand-maintained per-tool exclude list
# ... Sync now only ever adds or updates tracked files; nothing
# already sitting in a live directory is ever removed by it, even a
# tracked file removed from the source stays behind until cleaned up by
# hand.
```

The non-deleting sync is a documented, reasoned decision and is not the defect (R-804(b)). The defect is the composition: an `--update` documented against a tree that accumulates deleted files, writing a manifest that is committed from a different tree, with no closure check anywhere. Commit `7eb41b5` fixed the four instances and changed only `claude/enforce/hook-hashes.txt` (`git show --stat 7eb41b5`: `1 file changed, 4 deletions(-)`), leaving the mechanism that produced them intact.

Nothing detects a recurrence. Grepping every fixture, workflow, and hook for consumers of the manifest returns `claude/settings.json:350` (the registration), `claude/hooks/tests/hook-integrity-check.test.sh` (which builds its own sandbox manifest and never reads the committed one), and the hook itself. `.github/workflows/enforce.yml` never invokes `hook-integrity-check.sh`. The only detector is a SessionStart advisory on the live copy, which is exactly the surface that produced the phantom entries.

### Reverse hole: files on the enforcement surface the manifest does not cover

The globs at `hook-integrity-check.sh:25` cover `hooks/*.{sh,mjs,py}`, `enforce/*.{sh,yml,toml,mjs}`, `enforce/rules/*.mjs`, and three named JSON files. Not covered, verified by listing the tree against the 73 manifest entries:

- `claude/enforce/tests/*.test.sh` (54 files) and `claude/enforce/tests/run-tests.sh`
- `claude/hooks/tests/*` including its `run-tests.sh`
- `claude/enforce/judge-prompt.md`, which decides what the llm-judge tier enforces
- `claude/enforce/gate-trusted-repos.txt`, which decides where `build-cheatsheets.sh` auto-executes
- `claude/enforce/package.json` and `package-lock.json`, which pin the ESLint that is the entire `ast` tier
- all of `translate/*.mjs`, nine files, which CI runs as a gate (`enforce.yml`, `Translator port check`)

The header claims completeness for what it lists and offers no rationale for the omissions:

```bash
# Covered: hooks/*.sh, hooks/*.mjs, hooks/*.py, enforce/*.yml, enforce/*.toml,
# enforce/*.mjs (lint, ratchet, eslint config, shared options), enforce/rules/*.mjs
# (custom ESLint rules), enforce/*.sh (tdd.sh, resolve-outgoing-base.sh),
# enforce/manifest.json, enforce/lexicon.json, enforce/role-policy.json.
```

The header's own threat model is "one silent Write of `exit 0` into a guard hook". One silent Write of `echo "x.test.sh PASS"; exit 0` into a fixture is equally effective and equally invisible, and it is strictly easier because a gutted fixture leaves the dashboard green whereas a gutted hook at least stops firing. P1-4 below shows that a fixture reporting PASS while asserting nothing is not hypothetical on this surface.

**Fix direction.** Close the forward hole with a fixture that recomputes the hash set against the repo checkout and fails on any difference from the committed `hook-hashes.txt`, so a rename or a stale regeneration turns the suite red in the same commit instead of producing a session advisory on a different tree; and repoint the header's documented `--update` invocation at the checkout (`CLAUDE_INTEGRITY_ROOT=<repo>/claude`) rather than `~/.claude`. Close the reverse hole by extending the globs to the two fixture trees and the remaining decision-carrying data files, and decide explicitly whether `translate/` belongs on the integrity surface now that CI gates on it. `to confirm:` whether such a fixture would be self-referential in a way that breaks (the fixture would hash `enforce/tests/*.test.sh` including itself, which is fine for a content comparison but means every fixture edit requires a manifest regeneration in the same commit, a real ergonomic cost the user should weigh); whether `CLAUDE_INTEGRITY_ROOT` is already threaded correctly for `--update` and not just for the check path (reading the script, `HASH_FILE` derives from `CLAUDE_DIR` so it is, but this should be confirmed by running it); and whether `judge-prompt.md` and `gate-trusted-repos.txt` are intentionally excluded because they are prose and an untracked list respectively.

## P1-3: the R-103 mutation guard does not block a redirect to a `.env` in a subdirectory

**Severity: P1.** Governing rules: R-103 (`claude/CLAUDE.md:31`, `[hook:secret-scan]`), R-401 (tests that fail when the implementation is wrong). Manifest entry: `{"id": "R-103", "tier": "regex", "enforcer": "hook:secret-scan", "severity": "error"}`.

`claude/hooks/secret-scan.sh:93-100`:

```bash
HOMEDIRS='(~|\$HOME|/Users/[A-Za-z0-9._-]+)'
PROT="$HOMEDIRS/\.(aws|ssh|gnupg)(/[^[:space:]\"';|&]*)?"
PROT+="|$HOMEDIRS/\.config/gh/hosts\.yml"
PROT+="|(^|[[:space:]\"'=/])\.env(\.[A-Za-z0-9_-]+)?([[:space:]\"';|&]|$)"

MUTATE_VERBS='(rm|mv|cp|tee|shred|truncate|unlink|sed[[:space:]]+-[a-zA-Z]*i[a-zA-Z]*)'
MUTATION="(^|[;&|][[:space:]]*|[[:space:]])(sudo[[:space:]]+)?$MUTATE_VERBS([[:space:]]+-[^[:space:]]+)*([[:space:]][^;|&]*)?($PROT)"
REDIRECT=">>?[[:space:]]*($PROT)"
```

`REDIRECT` requires `$PROT` to begin immediately after the `>` and any run of spaces. `PROT`'s `.env` alternative opens with `(^|[[:space:]\"'=/])`, a single character class, so it can consume the `/` of `server/.env` only if the regex is allowed to start matching there. In `REDIRECT` it is not: `[[:space:]]*` cannot skip the literal `server`. The `MUTATION` alternative does not apply because no mutate verb is present.

Reproduced during this audit by feeding the hook real payloads:

```
sed -i '' 's/a/b/' server/.env                          -> deny
sed -i 's/a/b/' server/.env                             -> deny
printf x > server/.env                                  -> ALLOW
```

A redirect to a `.env` one directory down is unblocked. In a monorepo, which is the layout R-301 prescribes and which this very repo is, `apps/server/.env` and `packages/worker/.env` are the normal spelling, and the bare top-level `.env` is the exception.

The hook's own Write/Edit branch gets this right, which is what makes the Bash branch a defect rather than a scope decision. `claude/hooks/secret-scan.sh:121`:

```bash
      PROT_BASENAME='(^|/)\.env(\.[A-Za-z0-9_-]+)?$'
```

That pattern anchors on `/` or start and matches `/repo/apps/api/.env` correctly. Two patterns for the same protected-path concept, one of which handles nesting and one of which does not.

The fixture cannot catch it, and the way it cannot is instructive. `claude/enforce/tests/credential-mutation-guard.test.sh:17-27`:

```bash
ENVFILE=.env
# R-103 mutations: deny
deny "echo 'API_KEY=x' >> $ENVFILE"
deny "echo foo > $ENVFILE.production"
deny "rm ./$ENVFILE"
deny "rm -f ~/.ssh/id_rsa"
deny "mv $ENVFILE /backups/env-backup"
deny "cp $ENVFILE.example $ENVFILE"
deny "echo x > ~/.aws/credentials"
deny "tee ~/.config/gh/hosts.yml < payload.yml"
deny "sed -i '' 's/a/b/' server/$ENVFILE"
```

Every redirect case (lines 19, 20, 25) uses a path whose `.env` sits at a token boundary. The one case that does test a subdirectory, line 27, is the `sed` case, which routes through `MUTATION` rather than `REDIRECT`. So the fixture demonstrates awareness that nesting matters, applies it to one branch, and leaves the other branch asserted only in its easy spelling. This is the class the 2026-08-21 audit named and `claude/ISSUES.md` generalized, recurring on the R-103 guard.

**Fix direction.** Unify the two protected-path notions so the Bash branch and the Write/Edit branch cannot disagree: give `PROT`'s `.env` alternative a form that tolerates an arbitrary path prefix in the redirect position, or have `REDIRECT` capture the whole redirect operand and then test that operand with the same `PROT_BASENAME` logic the Write/Edit branch already uses. Add the nested spelling to the fixture for the redirect case, not only the `sed` case. `to confirm:` the real behavior of the widened pattern against the existing allow cases at `credential-mutation-guard.test.sh:30-37`, in particular `allow "echo 'X=1' >> /tmp/fixture-8213/$ENVFILE"`, which survives today only because `SAFE_CMD` at line 91 strips `/tmp` paths before the scan, so a prefix-tolerant pattern must keep that strip ordering intact; and whether a shared helper already exists for path classification (grep found none, the two patterns are independent string literals in the same file).

## P1-4: a fixture reports PASS having inspected nothing, and the convention it enforces misses two guards

**Severity: P1.** Governing rules: R-401 (`[hook:content-gate, eslint:no-self-mock, eslint:behavior-assertion-required]`), R-405, and the `Hook set convention` section of `claude/enforce/README.md`.

### Part A: the fixture cannot fail when its target tree is absent

`claude/enforce/tests/deny-tier-set-convention.test.sh:9-27`:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../../hooks"

fail=0
for hook in "$HOOKS_DIR"/*.sh; do
  name=$(basename "$hook")
  case "$name" in install-git-hooks.sh|pre-push.sample) continue ;; esac
  if grep -lq 'permissionDecision' "$hook" && grep -q '^set -euo pipefail' "$hook"; then
    echo "FAIL: $name emits decisions but runs set -e (fails open on internal error, P2-8)"
    fail=1
  fi
  if grep -qE '^\s*source [^;]*\|\| true' "$hook"; then
    echo "FAIL: $name sources a helper behind || true; a missing file still aborts the shell. Use an [ -f ] guard."
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "deny-tier-set-convention.test.sh PASS"
exit "$fail"
```

With `nullglob` unset (the default), a non-matching glob expands to the literal pattern, `grep` fails on the nonexistent path, the `if` is false, `fail` stays `0`, and the fixture prints PASS. There is no floor assertion on the number of hooks scanned. Reproduced by copying the fixture into a tree with no sibling `hooks/`:

```
=== run the fixture where ../../hooks does NOT exist ===
grep: /tmp/tmp.j3RfHogjgA/a/b/tests/../../hooks/*.sh: No such file or directory
grep: /tmp/tmp.j3RfHogjgA/a/b/tests/../../hooks/*.sh: No such file or directory
deny-tier-set-convention.test.sh PASS
exit=0
```

The runner does not save it. `claude/enforce/tests/run-tests.sh:23` accepts any output containing `PASS` and no `FAIL`, and `No such file or directory` contains neither, so this output is reported `ok`. A directory rename or a future layout change to `enforce/tests/` therefore converts this fixture from a gate into a rubber stamp with no signal.

The same shape exists at `claude/enforce/tests/claude-md-lint.test.sh:50-51`, where invariant 3 is skipped silently:

```bash
for rule_file in "$RULES_DIR"/*.md; do
  [ -e "$rule_file" ] || continue
```

That one is explicit about it, so it is a smaller instance, filed at P3-4 below rather than here.

### Part B: the convention keys on the wrong predicate, so two guards escape it

The convention the fixture mechanizes, `claude/enforce/README.md`, `Hook set convention (2026-09-16 audit P2-8)`:

```
Any hook that can emit a `permissionDecision` runs `set -uo pipefail`, never `-e`: under
`-e` an unexpected internal error (an unguarded grep, a missing file in a command
substitution) kills the hook before it emits, and a PreToolUse hook that emits nothing
is an allow, so the guard fails open silently.
```

The predicate is the literal token `permissionDecision`, and the fixture greps for exactly that string. Two guards decide things without ever using it.

`claude/hooks/settings-change-guard.sh:11-12` and `:22`:

```bash
# Blocks with decision:"block", which keeps the running session on the
# configuration it already has.
...
set -euo pipefail
```

Its manifest entry is not advisory: `{"id": "R-516", "tier": "regex", "enforcer": "hook:settings-change-guard", "severity": "error", "note": "ConfigChange: refuses a user settings.json that drops a manifest-required hook or does not parse"}`. So an error-severity blocking guard runs under the exact `set -e` the convention forbids, and the mechanical check reports clean because it emits `{decision: "block", reason: $r}` instead of a `permissionDecision`. It also carries the sibling of P1-1 at `claude/hooks/settings-change-guard.sh:32`: `[ -f "$MANIFEST" ] || exit 0`.

`claude/hooks/redact-output.sh:15` is the second, and it is the more consequential one because its subject is credentials:

```bash
set -euo pipefail
```

Its whole value is the `additionalContext` leak warning at lines 91-97, produced by a `perl` invocation at line 63. Reproduced with `perl` removed from `PATH`:

```
=== with perl REMOVED from PATH ===
claude/hooks/redact-output.sh: line 89: perl: command not found
[end] exit=127
```

The `grep` at line 60 had already proven a credential was present in the tool output. The hook then died and told the model nothing. `perl` resolves on macOS and on ubuntu-latest, so the specific trigger is unlikely; the shape is the point, and it applies to any internal error in that hook, including a `jq` failure on unusual output or a perl regex error. A credential-detection hook whose only failure mode is total silence is the fail-open the P2-8 remediation was written to eliminate, and the convention's wording excludes it.

Two lesser instances of the same wording gap, both `set -euo pipefail` and both emitting guard signal rather than a `permissionDecision`: `claude/hooks/hook-integrity-check.sh:19` (R-203, and see P1-1) and `claude/hooks/enforcement-guard-check.sh:10` (R-516). I checked the one `set -e` landmine I suspected in the latter, the `{ [ -n "${ANTHROPIC_API_KEY:-}" ] || security find-generic-password ... ; } && JUDGE_KEY_AVAILABLE=1` at line 55 on a host with no `security` binary, and it does **not** abort: the hook ran to completion and emitted its warning. That hypothesis is dropped.

**Fix direction.** For Part A, give the fixture a floor: count the hooks it inspected and fail when the count is zero or implausibly low, which makes every glob-driven fixture on this surface self-checking against a layout change. For Part B, restate the convention's predicate in terms of what the hook *decides* rather than which JSON key it happens to use (any hook whose output can block, ask, or carry a security warning), and widen the fixture's detection to `permissionDecision`, `"decision"`, and `additionalContext` emission; then move `settings-change-guard.sh` and `redact-output.sh` off `-e`, and give `redact-output.sh` a degraded path that still emits the warning when the redaction itself fails. `to confirm:` whether Claude Code treats a `ConfigChange` hook that exits non-zero with empty stdout as "apply the change" (the assumption behind calling this a fail-open; the hook's own header at lines 13-15 says a ConfigChange block is shown to nobody, so this needs verifying on the installed build before the fix is sized); whether `redact-output.sh` should declare `perl` as a hard dependency in the CI workflow and in `SETUP.md` rather than relying on it being present; and whether the two `additionalContext`-only SessionStart guards belong in the widened convention at all, since a missed session warning is a materially smaller harm than a missed block.

---

# P2 findings

## P2-1: `translate/codex.mjs` silently ignores a positional root, and `--write` then prunes the real tree

**Severity: P2.** Governing rules: R-101 (never run destructive data-loss actions without confirmation) by analogy, R-401, R-406 (one negative-input test per user-input handler).

`translate/codex.mjs:23-39`:

```js
function parseCliMode(argv) {
  const flags = argv.filter((a) => a.startsWith("--"));
  const known = new Set(["--write", "--check", "--root"]);
  const modes = flags.filter((f) => f === "--write" || f === "--check");
  const unknown = flags.find((f) => !known.has(f));
  if (unknown || modes.length !== 1) return null;
  const rootIndex = argv.indexOf("--root");
  if (rootIndex === -1) {
    return { mode: modes[0].slice(2), rootDir: path.resolve(fileURLToPath(import.meta.url), "../..") };
  }
```

`flags` is only the `--`-prefixed tokens, so `unknown` can never see a bare positional argument or a single-dash flag. Both are discarded, and `rootDir` silently falls back to the repository containing the script. Reproduced:

```
=== positional root ignored? (--check with a positional dir) ===
exit=0
=== single-dash flag ===
exit=0
```

Both invocations named an empty throwaway directory. Against an empty root, `loadSources` would have thrown `SourceError` and exited 2. Exit 0 proves both ran against the real repo instead.

In `--check` that is merely wrong. In `--write` it is destructive, because `writePlannedTree` prunes, `translate/codex.mjs:175-179`:

```js
  const orphans = findOrphanFiles(rootDir, planned, portMap);
  for (const orphan of orphans) fs.unlinkSync(path.join(rootDir, "codex", orphan));
  for (const entry of fs.readdirSync(path.join(rootDir, "codex"), { withFileTypes: true })) {
    if (entry.isDirectory()) removeEmptyDirectories(path.join(rootDir, "codex", entry.name));
  }
```

So `node translate/codex.mjs --write /tmp/sandbox`, a natural mistyping of the documented `--root /tmp/sandbox`, regenerates and prunes the repository's own `codex/` tree while the operator believes nothing outside `/tmp` was touched. I did not execute that variant, because doing so would modify the repository (R-802); the `--check` reproduction plus the code path above is the evidence.

The fixture's corresponding section is titled for exactly this concern and covers only the double-dash spellings, `claude/enforce/tests/translate-codex.test.sh:179-195`:

```bash
# B-10: mode hygiene, no file touched.
...
OUT=$(node "$TRANSLATOR" --frobnicate --root "$SANDBOX" 2>&1); ST=$?
check "unknown flag exits 2" test "$ST" -eq 2
check "usage errors touch nothing" test -z "$(ls -A "$SANDBOX")"

# Final review finding 2: bare --root with no following value is a usage
# error (exit 2), not a crash. ...
OUT=$(node "$TRANSLATOR" --check --root 2>&1); ST=$?
check "bare --root exits 2" test "$ST" -eq 2
```

**Fix direction.** Reject any argument the parser does not consume, not just the `--`-prefixed ones: build the known-token set including the `--root` value position and return `null` for anything left over. Add both a positional-argument case and a single-dash-flag case to the B-10 section. `to confirm:` whether any caller passes a positional argument today and would break (`.github/workflows/enforce.yml` runs `node translate/codex.mjs --check` with no root, and `claude/hooks/pre-push.sample:48` runs `node "$TOP/translate/codex.mjs" --check`, so neither does, but `claude/docs/superpowers/specs/2026-09-17-codex-translator-design.md` should be read for a documented positional form before tightening); and whether the `ratchet.mjs` positional form, which CI does use (`node "$HOME/.claude/enforce/ratchet.mjs" "$GITHUB_WORKSPACE/claude"`), sets a convention the translator was meant to follow, which would make the fix "accept the positional deliberately" rather than "reject it".

## P2-2: the generated `codex/.gitignore` promises tolerance for incidental files that `--write` deletes

**Severity: P2.** Governing rule: R-332 (keep every comment true to the code beside it); runbook-vs-code drift.

`translate/render-codex-gitignore.mjs:19-23` writes this header into every generated `codex/.gitignore`:

```js
  "# An allowlist, not a denylist: everything under codex/ is ignored, then every",
  "# generated and hand-authored file is named back in. Anything a tool drops here",
  "# on its own (local state, scratch, caches) stays untracked without having to be",
  "# predicted, and a generated file can no longer go missing from git for want of",
  "# a hand edit.",
```

`translate/codex.mjs:70-75` disagrees:

```js
function findOrphanFiles(rootDir, planned, portMap) {
  const plannedPaths = new Set(planned.map((file) => file.path));
  const handAuthoredPaths = new Set(portMap.hand_authored);
  return listFilesRecursive(path.join(rootDir, "codex"))
    .filter((relPath) => !plannedPaths.has(relPath) && !handAuthoredPaths.has(relPath));
}
```

Anything a tool drops there is an orphan: a `--check` failure and then a `--write` deletion. Reproduced in a sandbox built from the fixture's own `make_source_tree`:

```
--- plant a macOS Finder artifact under codex/ ---
orphaned: .DS_Store
check exit=1
wrote 9 files, removed 1 orphans
still there? NO - DELETED
```

So on the maintainer's macOS, opening `codex/` in Finder turns CI red, and the next `--write` silently deletes the artifact. The single-owner invariant at `translate/codex.mjs:64-69` is a deliberate and defensible design ("an orphan is always a defect, never intentional"), so the code is not the thing to change. The generated header is, because it tells a human the opposite of what the tool does, and it is the text a human reads when they wonder whether `codex/` is safe to put anything in.

**Fix direction.** Rewrite the generated header so it states the actual invariant: `codex/` holds only generated and hand-authored files, anything else is deleted on the next `--write`, and scratch belongs outside it. `to confirm:` whether an `.DS_Store`-class exclusion belongs in `findOrphanFiles` instead (the user may prefer tolerating a small denylist of known-incidental names over the stricter invariant, which is a design call, not an audit call); and whether the repo-root `.gitignore` already covers `.DS_Store` such that only `--check`/`--write` see it, since that determines whether this ever bites in CI or only locally.

## P2-3: R-516's "ship a fixture test" clause is unenforced by its own named enforcer

**Severity: P2.** Governing rules: R-516 (`claude/CLAUDE.md:147`), R-332.

R-516's norm line:

```
R-516: Register every mechanizable rule in `~/.claude/enforce/manifest.json` with tier and enforcer, and ship a fixture test; a rule with no manifest entry depends on recall. [hook:enforcement-guard-check]
```

`claude/enforce/README.md`, `Adding a rule`, step 3, repeats the requirement:

```
3. Ship the enforcer (extend an existing hook, add an ESLint rule, or add the rule id to the judge tier) AND a fixture test under `tests/`. A rule with no manifest entry is unenforced and depends on recall.
```

The named enforcer checks three things and not that one. `claude/hooks/enforcement-guard-check.sh:2-9`:

```bash
# enforcement-guard-check.sh: at session start, verify both directions of the
# enforcement mapping. Forward: every hook the manifest requires is registered
# in settings.json. Reverse (P2-1): every hook:/eslint: enforcer cited in a
# rule-file Enforcement line has a manifest entry, so coverage drift is
# self-detecting rather than audit-detected.
```

`manifest.test.sh` does not cover it either; its own header enumerates what it does check (`manifest.test.sh:2-9`) and fixture existence is absent from that list.

The gap is not hypothetical. Cross-checking all 96 manifest enforcers against the text of every fixture in both suites, five enforcers have no fixture that exercises them:

| Manifest entry | Status |
|---|---|
| `R-329: ruff:ANN401` | `ruff-enforce.toml:21` selects it; no fixture case has an `Any`-annotated signature |
| `R-329: ruff:PGH003` | selected; no fixture case has a blanket `# type: ignore` |
| `R-344: ruff:S110` | selected; no fixture case has `try/except/pass` (the fixture tests `E722` and `BLE001` only) |
| `R-344: rubocop:Lint/SuppressedException` | `rubocop-enforce.yml` enables it; the fixture stubs RuboCop, so no cop selection is verified |
| `R-303: eslint:no-restricted-paths` | **covered** by `import-direction.test.sh` behaviourally; dropped from the list |
| `R-326: eslint:no-restricted-syntax` | **covered** by `eslint.test.sh:44-46`; dropped from the list |

The last two are listed to record that I checked and dropped them, per R-804(a).

Compounding, the CI workflow asserts coverage that does not exist. `.github/workflows/enforce.yml:56-60`:

```
      # push-ruff-gate.test.sh drives the REAL ruff binary. ... Stubbing ruff to
      # match the other two would make the suite hermetic at the cost of no
      # longer checking that enforce/ruff-enforce.toml actually selects
      # PLR2004/E731/ANN401, so CI provides the binary instead.
```

Grepping `claude/enforce/tests/push-ruff-gate.test.sh` for `ANN401`, `PGH003`, or any `Any` annotation returns nothing; the fixture's Python payloads exercise `E731` (line 14), `PLR2004` (line 44), `E722` (line 53), `BLE001` (line 58), and `T201` (line 67). The named justification for installing real ruff in CI is two thirds true. That is R-332.

The stubbing of RuboCop and golangci is documented in the same workflow comment as a deliberate trade and is not a violation (R-804(b)); the unverified cop selection that follows from it is the residual risk worth recording.

**Fix direction.** Add the missing half of R-516 to the mechanical check: derive the enforcer set from the manifest and assert each one is named or exercised by at least one fixture, with an explicit, commented exemption list for the enforcers whose configs are deliberately stub-tested. Correct the CI comment to name only the codes the fixture actually drives. `to confirm:` how "exercised" should be decided, since a name grep is too naive (it produced 33 false positives before I cross-checked behaviourally) and a behavioural mapping needs a hand-kept table, which is itself a drift surface; and whether the four unexercised ruff and rubocop codes are better closed by adding fixture cases than by a closure check, since that is cheap and removes the question.

## P2-4: the README's tier table and one `CLAUDE.md` tag claim an `llm-judge` tier the manifest does not implement

**Severity: P2.** Read from code and data; not separately reproduced beyond the cross-check below. Governing rules: R-332, R-516.

`claude/enforce/README.md:25`:

```
| `llm-judge` | `llm-rule-judge.sh` (a fast model over the diff) | per push | R-315, R-316, R-317, R-322, R-318, R-325, R-320 |
```

The manifest has exactly three `llm-judge` entries, recomputed during this audit:

```
llm-judge 3
    ['R-315:hook:llm-rule-judge', 'R-316:hook:llm-rule-judge', 'R-317:hook:llm-rule-judge']
```

The other four named in the table are elsewhere: R-322 is `advisory:hook:clean-code-reminder`, R-325 is `ast:eslint:destructure-object-reads`, R-320 is `ast:eslint:file-header-comment` plus `advisory:hook:new-file-header-reminder`, and R-318 has no manifest entry at all. The judge derives its rule set from the manifest and nowhere else, `claude/hooks/llm-rule-judge.sh:70`:

```bash
  RULE_IDS=$(jq -r '.rules[] | select(.tier=="llm-judge") | .id' "$MANIFEST")
```

so the judge never evaluates R-318, R-320, R-322, or R-325 regardless of what the table says.

The table's column header is `Examples`, which excuses an incomplete list but not a wrong one. One `CLAUDE.md` tag makes the same claim without that excuse, `claude/CLAUDE.md:50`:

```
R-325: Destructure when reading 2+ properties of an object; never destructure a method off its object. [eslint:destructure-object-reads, judge]
```

`judge` names an enforcer that does not carry R-325. R-315, R-316, R-317 tag `judge` correctly; R-318 honestly tags `[manual]`; R-320 and R-322 do not claim `judge` at all. So R-325 is the single tag defect and the table is the doc defect.

Practical exposure is modest, because R-325 does have a working ESLint rule and R-322 has a working reminder. The finding is that neither `manifest.test.sh` nor `enforcement-guard-check.sh` compares a *tier* claim against the manifest, only an enforcer claim against a rule id, so a tier assertion anywhere in the corpus is unverified in both directions. The 2026-09-16 P3-5 finding documented the analogous gap for `CLAUDE.md` bracket tags and both checks still read `rulebook/*.md` only.

**Fix direction.** Correct the README row to the three rules actually in the tier, and decide whether R-325's `judge` tag is aspirational (remove it) or intended (add the manifest entry, which would also change what the judge prompt must cover). If tier claims are to be trusted anywhere, the closure check needs to compare them, which argues for generating the README tier table from `manifest.json` the way `render-lexicon-spec.mjs` generates the verb lists into `reference.md` between markers. `to confirm:` whether the bracket tags are meant to be exhaustive per rule or to name only the primary enforcer, which the 2026-09-16 P3-5 finding left open and which decides whether R-325's extra tag is a defect or shorthand; and whether adding R-325 and R-322 to the judge tier is wanted at all, given the judge tier currently cannot run for want of a key.

## P2-5: the turn-end R-509 gate and the pre-push gate disagree on what verifies this repo

**Severity: P2.** Governing rule: R-509 (`claude/CLAUDE.md:142`, `[hook:verification-gate]`).

`claude/hooks/verification-gate.sh:132-137` (the monorepo branch added by the 2026-09-16 P1-1 fix, which works):

```bash
elif [ -f claude/enforce/tests/run-tests.sh ] && [ -f claude/hooks/tests/run-tests.sh ] && [ -f claude/CLAUDE.md ]; then
  # The agent-governance monorepo: the same governance tree one level down
  # under claude/ (2026-09-16 audit P1-1).
  add_check "bash claude/enforce/tests/run-tests.sh"
  add_check "bash claude/hooks/tests/run-tests.sh"
```

Two checks. The pre-push hook for the same repo runs three, `claude/hooks/pre-push.sample:44-51`:

```bash
# translate/ lives beside claude/ in the monorepo layout only; a legacy or
# live-copy checkout carries no translator, so this step is silently skipped
# there rather than failing on a missing script.
if [ -f "$TOP/translate/codex.mjs" ]; then
  if ! node "$TOP/translate/codex.mjs" --check; then
    fail=1
  fi
fi
```

and so does CI (`.github/workflows/enforce.yml`, step `Translator port check`). R-509's norm line covers both boundaries in one sentence ("Target changed files in per-commit test runs; run the full suite at pre-push; neither a turn nor a writing subagent ends on a red suite"), and the translator is the most-churned code on this surface: four of the five in-scope commits touch `translate/`. A turn can therefore end with `codex/` drifted from `claude/`, or with a stale `codex/.gitignore` losing a file from git (the exact regression `c8b0555` was written to prevent), and the turn-end gate says nothing.

**Fix direction.** Add the translator check to the monorepo discovery branch, guarded on the script existing, mirroring the pre-push shape. `to confirm:` the cost, since `verification-gate.sh` runs at every `Stop` and `SubagentStop` and its memo at lines 90-105 keys on the tree rather than on the check set, so adding a Node startup to the turn-end path needs measuring against the same budget `hook-latency.test.sh` applies to the per-edit chains; and whether `sync-tests/` should join at the same time, since it has no turn-end check either and is equally out of both gates.

## P2-6: `secret-scan.sh` misses three real in-place-edit spellings, including the portable one this repo itself uses

**Severity: P2.** Governing rules: R-103, R-401.

`claude/hooks/secret-scan.sh:98`:

```bash
MUTATE_VERBS='(rm|mv|cp|tee|shred|truncate|unlink|sed[[:space:]]+-[a-zA-Z]*i[a-zA-Z]*)'
```

`[a-zA-Z]*i[a-zA-Z]*` matches only letters after the dash, so `sed -i.bak` matches as far as `-i` and then the regex needs `$PROT` to begin at `.bak`, which it cannot. Reproduced:

```
sed -i.bak 's/a/b/' server/.env                         -> ALLOW
sed --in-place 's/a/b/' server/.env                     -> ALLOW
perl -pi -e 's/a/b/' server/.env                        -> ALLOW
```

`sed -i.bak` is the spelling that works on both GNU and BSD sed, which is why this repo's own fixture uses it, `claude/enforce/tests/tdd-red-green.test.sh:108`:

```bash
sed -i.bak 's/^it(/it.skip(/' src/__tests__/score.test.ts && rm -f src/__tests__/score.test.ts.bak
```

So the portable in-place edit that the repo's own conventions produce is the one the guard does not recognize. `perl -pi -e` is the other common substitute and `perl` is not in the verb list at all. This is less severe than P1-3 only because the escaping spellings are less likely than a redirect.

**Fix direction.** Broaden the in-place detection to any `sed` invocation carrying an `-i`-family option in any spelling (including a suffix and the long form) and add `perl` with `-i`/`-p` to the verb set, then add each spelling to `credential-mutation-guard.test.sh`. `to confirm:` whether broadening `sed` risks a false positive on `sed -n` or `sed -E` combined forms such as `sed -ni` versus `sed -in` (the current pattern already accepts letters on either side of the `i`, so the direction is already permissive and the fix is mostly about non-letter suffixes); and whether `awk -i inplace`, `python -c` writes, and `dd of=` belong in the same sweep or are out of the guard's declared scope, which the hook header at lines 86-90 does not say.

## P2-7: one unpaired `fix:` commit in the window

**Severity: P2, pattern note.** Governing rule: R-403 (`[hook:fix-commit-requires-test]`).

Reviewed every commit on this surface since `be7b5f0`, plus the two later commits on `main`. Three carry a `fix` type.

| Commit | Subject | Test change? |
|---|---|---|
| `a5b4ff1` | `fix(translate): --write removes the directories its orphan deletions empty` | **YES**: `claude/enforce/tests/translate-codex.test.sh \| 16 +++++` alongside `translate/codex.mjs` |
| `90b6996` | `fix(enforce): unescape the backtick patterns so the port-status assertions match on GNU grep` | Test-only (`translate-codex.test.sh` + `claude/ISSUES.md`). A test improvement, not an unpaired fix, per the role definition. Not counted. |
| `7eb41b5` | `fix(enforce): drop the four phantom hash entries the kebab-casing rename left behind` | **NO**. `git show --stat 7eb41b5`: `claude/enforce/hook-hashes.txt \| 4 ----`, `1 file changed, 4 deletions(-)` |

`7eb41b5` is the unpaired one. The data-only nature of the change is a fair partial defence: there is no product code to write a test against. But the class *was* testable, and P1-2 above is the test that was not written, which is precisely why the mechanism that produced the four entries is still live. One unpaired fix in the window is a P2 pattern note under the role definition, not a P1 behavioural finding.

Separately, `fix-commit-requires-test.sh` did not fire on `7eb41b5`, which needs explaining rather than assuming: either the hook does not classify `hook-hashes.txt` as product code, or it was not invoked for that commit. Worth checking, because a `fix:` commit touching only a gate input is exactly the shape the hook should have an opinion about.

**Fix direction.** No code change for the commit itself. Land the P1-2 closure check as the test that should have accompanied it, and read `claude/hooks/fix-commit-requires-test.sh` to determine whether a data-only `fix:` is deliberately exempt. `to confirm:` the hook's actual predicate for "product code changed" and whether `enforce/*.txt` gate inputs are inside or outside it; and whether the hook fired and was overridden, which the rule-fire log would show.

## P2-8: `claude-md-lint.test.sh` and `hook-latency.test.sh` measure the live copy while their siblings are overridable

**Severity: P2.** Read from code; the CI symlink means this does not bite in CI. Governing rule: R-401; the 2026-09-16 P2-11 live-versus-repo class.

`claude/enforce/tests/claude-md-lint.test.sh:17-19`:

```bash
CLAUDE_MD="${CLAUDE_MD_FILE:-$HOME/.claude/CLAUDE.md}"
REFERENCE_MD="${CLAUDE_REFERENCE_FILE:-$HOME/.claude/rulebook/reference.md}"
RULES_DIR="$HOME/.claude/rules"
```

Two of the three inputs are env-overridable and the third is not. `claude/enforce/tests/hook-latency.test.sh:12` and `:22` split the same way:

```bash
HOOKS_DIR="$HOME/.claude/hooks"
...
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
```

The chains are read from a settings file the caller can point at the checkout, and then the hooks those chains name are executed from the live copy. In CI this is harmless because `.github/workflows/enforce.yml` symlinks `$HOME/.claude` to the checkout's `claude/`. Locally it means an expensive new hook in the repo is not measured until it is synced, and a rules-directory defect in the repo is not linted at all, which is the same live-versus-repo asymmetry the 2026-09-16 P2-11 finding was about, surviving inside the fixtures rather than in the hooks.

**Fix direction.** Make every path in a fixture resolve through one convention: either all env-overridable with a `$HOME/.claude` default, or all derived from the fixture's own `SCRIPT_DIR` the way `deny-tier-set-convention.test.sh:9-10` and `index-settings-sync.test.sh:11-12` already do. The `SCRIPT_DIR` form is the stronger one because it cannot be pointed at the wrong tree by a stale environment. `to confirm:` whether any fixture deliberately targets the live copy as its subject rather than as a convenience (`hook-latency.test.sh` arguably should measure what actually runs in a session, which would make its live-copy read intentional and worth a comment rather than a change); and whether the R-313 co-location allowlist work in `0f06e3c` already established a preferred pattern for this, since that commit solved the same problem for `structure-gate.test.sh`.

---

# P3 findings

## P3-1: `in` on a plain object treats prototype keys as classified hooks

**Severity: P3, improbable.** `translate/codex.mjs:196-203`:

```js
  for (const [event, groups] of Object.entries(settingsHooks)) {
    if (Object.prototype.hasOwnProperty.call(portMap.events, event)) continue;
    for (const group of groups) {
      for (const hook of group.hooks ?? []) {
        const name = hookNameFromCommand(hook.command);
        if (name in overrides || name in portMap.unported_reasons) continue;
```

Line 197 correctly uses `hasOwnProperty.call`; line 201 uses bare `in` twice, on the same kind of plain JSON object, three lines later. A hook named `constructor`, `toString`, or `valueOf` would be silently treated as classified and never reported as an unclassified hook. `parse-sources.mjs:73` has the same shape. Hook names derive from script basenames, so this needs a file literally named `constructor.sh`; the reason to fix it is consistency within one function, not likelihood.

**Fix direction.** Use `Object.prototype.hasOwnProperty.call` in all three places, or normalize the port map's maps into `Map` instances at load time in `loadPortMap`. `to confirm:` whether `loadPortMap` at `parse-sources.mjs:40-46` is the only construction site for these objects, which would make a single normalization there sufficient.

## P3-2: a negative assertion in `translate-codex.test.sh` passes vacuously on empty input

**Severity: P3.** `claude/enforce/tests/translate-codex.test.sh:229-230`:

```bash
BODY_REGION=$(awk '/^developer_instructions = """$/{flag=1; next} flag && /^"""$/{flag=0; next} flag' "$TOML")
check "toml body has no unescaped double quote" not grep -qE '[^\\]"' <<<"$BODY_REGION"
```

If the renderer stopped emitting the `developer_instructions = """` delimiter, `BODY_REGION` would be empty and this check would pass. Its three siblings at lines 231-233 use `grep -qF` on the same variable and would fail, so the vacuity is currently covered by neighbours rather than by the assertion itself. Filed because the pattern (a negative assertion over a variable produced by a fragile extraction, with no non-emptiness precondition) recurs at lines 442, 501, 522, and 551, each time saved by a sibling.

**Fix direction.** Assert `BODY_REGION` is non-empty once before the four checks that read it, which makes all of them honest and costs one line. `to confirm:` whether the same guard is wanted for the `<<<"$OUT"` negative checks, where `$OUT` is already pinned non-empty by the preceding positive assertion in every instance I traced.

## P3-3: `index-settings-sync.test.sh` turns a legitimate config into a red suite

**Severity: P3.** `claude/enforce/tests/index-settings-sync.test.sh:14-15`:

```bash
SETTINGS_MODEL=$(jq -r '.model // ""' "$CLAUDE_ROOT/settings.json")
[ -n "$SETTINGS_MODEL" ] || { echo "index-settings-sync.test.sh SKIP: settings.json sets no model"; exit 0; }
```

The string `SKIP: settings.json sets no model` contains no `PASS`, and `run-tests.sh:23` requires `PASS`, so removing the `model` key (a valid configuration meaning "use the default") reports `FAIL index-settings-sync.test.sh`. This fails in the safe direction and is a usability defect rather than a hole.

**Fix direction.** Emit a sentinel the runner accepts, or drop the skip branch and assert the key exists. `to confirm:` whether any fixture already has a runner-accepted skip convention (I found none; this is the only `SKIP` in either suite), which makes this a chance to establish one rather than a one-off patch.

## P3-4: `claude-md-lint.test.sh` invariant 3 skips itself silently

**Severity: P3.** `claude/enforce/tests/claude-md-lint.test.sh:50-51`:

```bash
for rule_file in "$RULES_DIR"/*.md; do
  [ -e "$rule_file" ] || continue
```

The same shape as P1-4 Part A but explicit about it and lower stakes: the invariant guards auto-loading prose in `rules/`, not a gate. Bundled here because the floor-count fix proposed for P1-4 should cover both call sites.

**Fix direction.** Same floor assertion as P1-4 Part A. `to confirm:` whether `$RULES_DIR` can legitimately be empty in any supported layout, since `claude/rules/` currently holds `session-types.md` plus path-scoped symlinks.

## P3-5: a dead branch in the enforcement runner

**Severity: P3.** `claude/enforce/tests/run-tests.sh:17-20`:

```bash
for t in "$DIR"/*.test.sh; do
  name=$(basename "$t")
  [ "$name" = "run-tests.sh" ] && continue
```

The glob is `*.test.sh`, so `run-tests.sh` can never be the value of `$name`. `claude/hooks/tests/run-tests.sh` is the same loop without the line, which is the correct version. Harmless; it costs a reader a moment wondering what it guards against.

**Fix direction.** Delete the line, or add the comment that explains the historical glob it was written for. `to confirm:` nothing.

## P3-6: an unanchored regex in a staleness assertion

**Severity: P3.** `claude/enforce/tests/translate-codex.test.sh:500`:

```bash
check "stale gitignore named" grep -q "^stale: .gitignore$" <<<"$OUT"
```

The `.` before `gitignore` is a regex any-character, so this also matches `stale: Xgitignore`. Repeated at lines 540 and 550. No realistic output satisfies the loose form that does not also satisfy the strict one, so this is cosmetic precision, not a hole.

**Fix direction.** `grep -qx -- '^stale: \.gitignore$'` or `grep -qFx 'stale: .gitignore'`, matching the `grep -qx --` form the same fixture already uses at lines 506-517. `to confirm:` nothing.

## P3-7: the judge-liveness warning cannot be satisfied on Linux

**Severity: P3, uncertain whether this is a defect.** `claude/hooks/enforcement-guard-check.sh:53-55`:

```bash
JUDGE_KEYCHAIN_SERVICE="${CLAUDE_JUDGE_KEYCHAIN_SERVICE:-claude-judge-api-key}"
JUDGE_KEY_AVAILABLE=0
{ [ -n "${ANTHROPIC_API_KEY:-}" ] || security find-generic-password -s "$JUDGE_KEYCHAIN_SERVICE" >/dev/null 2>&1; } && JUDGE_KEY_AVAILABLE=1
```

`security` is the macOS keychain binary and is absent on Linux (`command -v security` returns nothing here), so on any Linux host the only satisfying path is an `ANTHROPIC_API_KEY` in the hook environment. I verified the hook does not abort under `set -e` when both probes fail, and that it emits its warning correctly, so this is honest in the warn direction. Whether it is a defect depends on whether Linux is a supported host for this configuration at all, which I could not determine: the repo targets macOS by every other signal (`credential-mutation-guard.test.sh:37` references `/private/tmp/claude-501/`, `redact-output.sh:32` mentions "macOS sed limitations"), but CI runs `ubuntu-latest` and this audit is running on Linux.

**Fix direction.** If Linux is supported, add a `secret-tool`/`pass` probe or document that the file-based `judge-accepted-honor-system` acknowledgement is the Linux answer. `to confirm:` whether any host other than the maintainer's macOS is expected to run a real session as opposed to running CI, which settles whether this is a defect or correct behaviour on an unsupported host.

---

## Architecture & Design

The layering on this surface is sound and I found nothing to change in it. Rules are data (`manifest.json`, `lexicon.json`, `role-policy.json`, `codex-port-map.json`), enforcement is code (`hooks/`, `enforce/rules/`, `translate/`), prose is a third tier (`rulebook/`, `enforce/README.md`), and the dependency direction is one-way: hooks and the translator read `enforce/` data, never the reverse. The new `translate/` package is the best-structured code in the repo: one renderer module per output artifact, a single `parse-sources.mjs` owning validation and the `SourceError` type, a pure `renderPlannedTree` that builds the whole tree before any write, and `--check` sharing the identical render path with `--write` so the two cannot diverge. That last property is the one most such tools get wrong, and getting it right is why the `.gitignore` regression at `c8b0555` was closable by moving one file into the planned set rather than by adding a second comparison path.

The structural weakness is a single repeated pattern, and it is the through-line of every P1 above: **a mechanism that enumerates what it protects, with nothing checking the enumeration.** Four instances, all on this surface:

- `hook-integrity-check.sh:25` enumerates globs; the fixture trees and `translate/` are outside them (P1-2).
- `deny-tier-set-convention.test.sh:16` enumerates a predicate (`permissionDecision`); two guards fall outside it (P1-4).
- `secret-scan.sh:94-96` enumerates protected-path shapes twice, in two patterns, which disagree (P1-3).
- `manifest.json` enumerates enforcers; nothing checks each has a fixture (P2-3).

The existing template for the fix is already in the tree and is the right one: `render-lexicon-spec.mjs` generates the R-316 verb lists into `reference.md` between markers, and `lexicon-spec-sync.test.sh` fails the suite on divergence. That pattern turns an enumeration into derived data. It has now been applied twice successfully (the verb lists, and `codex/.gitignore` at `c8b0555`) and each time it retired a whole class of drift. The four cases above are the remaining candidates, and P1-2 is the highest-value one because the thing it would protect is the fixture suite that every other gate's credibility rests on.

## Code Quality

Consistent and above average. Hook scripts carry a header stating purpose, rule ID, and known limitations; the `set` line is deliberate and now documented; helpers are sourced behind `[ -f ]` guards after the 2026-09-16 P2-8 class fix, which `deny-tier-set-convention.test.sh:20-23` now enforces mechanically. The habit of writing what a component *cannot* see into its own header is rare and worth keeping: `translate/codex.mjs:184-192`, `render-codex-gitignore.mjs:1-11`, and the ratchet's "Known limit, stated rather than hidden" are all load-bearing documentation rather than decoration.

Comment truth (R-332) is the recurring quality defect and every instance this audit found is filed above: the CI ruff comment (P2-3), the README tier table (P2-4), the generated `.gitignore` header (P2-2), and the `hook-integrity-check.sh` `--update` instruction (P1-2). Four instances in one surface, all in the same direction: the comment claims more coverage than the code delivers. That directionality is worth naming, because it means comments on this surface are written at the moment of intent rather than at the moment of completion.

No dead code beyond the single dead branch at P3-5. `shellcheck --severity=error` is now in CI over `claude/hooks/*.sh` and `claude/enforce/*.sh`, which closes the 2026-09-16 recommendation 18; note it does not cover `claude/enforce/tests/*.sh` or `claude/hooks/tests/*.sh`, which is where P1-4's nullglob defect lives and where shellcheck would have had something to say.

## Security

No P0. Covered above: P1-3 and P2-6 (R-103 mutation-guard gaps), P1-1 (integrity guard fails open on a missing manifest), P1-4 Part B (`redact-output.sh` silent on internal error).

Working as designed and verified during this audit: `secret-scan.sh` blocked one of my own probe commands mid-audit because the command string itself contained a protected-path redirect pattern, which is the guard working correctly on the auditor; `redact-output.sh` produced a correct redacted copy plus the exposure warning when driven with a synthetic full-length token; the `set -uo pipefail` convention holds for all 26 `permissionDecision`-emitting hooks with zero exceptions (recomputed across all 50 scripts in `claude/hooks/`).

Prompt injection: the only LLM call on this surface is `llm-rule-judge.sh`, which is gated on a key that is documented as not provisioned and which `enforcement-guard-check.sh:56-58` warns about at every session start. `judge-prompt.md` is the injection surface if the tier is ever activated, and it is one of the files P1-2 found outside the integrity manifest, which is worth weighting when that tier goes live.

## Credential Exposure Scan

Every target the role definition requires, scanned with counts and paths only. No matched value appears anywhere in this report.

| Target | Result |
|---|---|
| Git history, all refs | **Clean.** 28 blob-refs match `sk-ant-api03-[A-Za-z0-9_-]{50,}`, in exactly two files: `claude/enforce/tests/credential-mutation-guard.test.sh` and `claude/hooks/secret-scan.sh`. Reducing every matched body through `sed 's/A\{10,\}/<A-RUN>/'` yields exactly one distinct form, `<A-RUN>`: all synthetic all-`A` padding. Zero matches for the other 11 patterns tested (Stripe webhook, Stripe live, GitHub PAT, AWS AKIA and ASIA, Google, Slack, Render, Vercel, SendGrid, private-key header). |
| Working tree, including untracked | **Clean, and improved.** Zero matches for any pattern, including in the two files above. The 2026-09-16 P3-3 remediation (`415bd29`, "build full-length fixture tokens at runtime") is verified working: `credential-mutation-guard.test.sh:40` now constructs the padding with `FAKE_PAD=$(printf 'A%.0s' $(seq 1 54))` and `secret-scan.sh:30` no longer carries a literal. The repo now contains no full-length token in any form. |
| Claude Code session transcripts | **Clean.** One project directory exists (`~/.claude/projects/-home-user-agent-governance/`). Zero files match any of the seven high-signal patterns swept. |
| Shell history | **Not present.** `~/.zsh_history` and `~/.bash_history` do not exist in this environment. |
| Vendor CLI configs | **Not present.** `~/.railway/config.json`, `~/.vercel/auth.json`, `~/.config/gh/hosts.yml`, `~/.stripe/config.toml`, `~/.aws/credentials`, `~/.netrc`: all absent. |
| `.env` files anywhere in the repo | **None.** `find . -name '.env*'` excluding `.git` and `node_modules` returns nothing. |

Rotations completed: none required, and auditors do not rotate (R-802). Rotations pending: none. The `PreToolUse` secret-scan hook is installed and fired correctly on the auditor during this session, so remediation step (c) from the role definition is satisfied.

One caveat on scope, stated rather than omitted: this environment is a container with no shell history and no vendor CLI state, so those two surfaces are *absent* rather than *verified clean* on the maintainer's own machine. The two credential-shaped transcript matches the 2026-09-16 audit flagged for triage (one `ghp_` shape, one `ASIA` shape, both outside this repo) are not visible from here and their triage status is unknown. The user should confirm those two are resolved; nothing in this audit supersedes that item.

## Database / API Design / Performance

Not applicable in the usual sense: this surface has no database, no HTTP routes, and no client, so there is no N+1, no bundle, no caching strategy, and no client-side polling to grep for. The performance dimension that does apply is hook latency, and it is governed correctly.

`claude/enforce/tests/hook-latency.test.sh` reads the registered chains from `settings.json` rather than a hand-kept list (lines 17-27), normalizes against a same-environment bare-spawn control with an absolute floor (lines 35-51), and passes. Its design is right and I am not re-filing the 2026-09-16 praise. Two observations, both already filed: it executes the live copy's hooks against a possibly-overridden settings file (P2-8), and `|| true` at line 55 means a hook that crashes instantly measures as fast, which is correct for a latency test and is worth knowing when reading a green result.

One new cost to watch, not a finding: `translate/codex.mjs --check` renders the entire planned tree (agents, skills, rules doc, hooks config, port status, gitignore, manifest) before comparing, so it is a full Node startup plus a full render. It runs at pre-push and in CI, where that is fine. P2-5 proposes adding it to the turn-end gate, and that is where the cost needs measuring rather than assuming.

## Testing

54 enforcement fixtures, both suites green, run during this audit. Quality is genuinely good: fixtures build throwaway trees and drive the real scripts, assert observable decisions rather than mock-call counts, and several deliberately drive real binaries (`push-ruff-gate.test.sh` runs actual ruff, `tdd-red-green.test.sh` drives the pinned Vitest, `eslint.test.sh` runs the real config). Three fixtures added in the last two days (`git-env-isolation.test.sh`, `codex-test-author-guard.test.sh`, `translate-codex.test.sh`) are all constructed to fail when the thing they guard breaks, which I verified by reading each against its subject.

Two of the dispatch's four testing questions come back positive and are filed as P1-4 and P1-2. The other two come back clean, and I am stating them as one line each rather than padding them, per the dispatch instruction.

**Fixtures that cannot fail, assert on their own setup, or would pass against a gutted hook.** One instance, proven: `deny-tier-set-convention.test.sh` (P1-4 Part A), plus a smaller explicit instance at `claude-md-lint.test.sh:51` (P3-4) and a vacuous negative assertion at `translate-codex.test.sh:230` (P3-2). I checked for the "asserts on its own setup" shape specifically and did not find it: where a fixture asserts on content `make_source_tree` wrote (for example `translate-codex.test.sh:231-233`, `240-241`), the assertion is on the *translator's copy* of that content, which is the artifact under test, not the setup. The three fixtures the 2026-08-21 audit found sidestepping their failure mode were not re-examined here (they are in `claude/hooks/tests/`, outside this scope); `claude/ISSUES.md` still carries the generalization.

**Host-dependent constructs.** Substantially clean, one residual. I swept both fixture trees for every class the dispatch named and found: zero uses of `stat`, `readlink`, `date -d`/`date -r`, `grep -P`, `grep -o` in a parsing position, or a non-portable `mktemp` flag; zero escaped-backtick patterns remaining after `90b6996`; `sed -i` appearing only inside hook *payload strings* that are never executed (`credential-mutation-guard.test.sh:27`, `protected-path-guard.test.sh:71`) plus one genuinely portable `sed -i.bak` at `tdd-red-green.test.sh:108`; `shasum` used uniformly across all five fixtures that hash, never mixed with `sha256sum` except as two independent payload strings in `destructive-command-guard.test.sh:36-37`; and collation already pinned where it matters, `translate-codex.test.sh:518-520`:

```bash
# Entry order is the deterministic-output invariant, checked in C locale
# because the renderer sorts byte-wise, not by the caller's collation.
gitignoreEntriesSorted() { local e; e=$(grep '^!/' "$GI"); [ "$e" = "$(LC_ALL=C sort <<<"$e")" ]; }
```

That comment shows the class is understood. The residual is P3-7 (`security` is macOS-only), plus two undeclared hard dependencies that happen to exist on both hosts and so are latent rather than active: `perl` (`redact-output.sh:63`, and see P1-4 Part B for what its absence does) and `python3` (`hook-latency.test.sh:33`). Neither is declared in the CI workflow or in `SETUP.md`. No bash-version dependence: `<<<`, `${var-default}`, and `local` are all bash 3.2 compatible, and I found no `mapfile`, associative array, or `${x^^}` anywhere in either tree.

**Runner robustness against a partial pass.** Holds on every exit path I could construct. Both runners now carry the 2026-09-16 fix at `run-tests.sh:23`:

```bash
  if out=$(bash "$t" 2>&1) && printf '%s' "$out" | grep -q "PASS" && ! printf '%s' "$out" | grep -q "FAIL"; then
```

A fixture that dies before printing anything exits non-zero, the `&&` chain short-circuits, and it is reported `FAIL` (verified by construction: `out=$(...)` propagates the fixture's status). A fixture that exits 0 printing nothing lacks `PASS` and is reported `FAIL`. A fixture printing both `PASS:` and `FAIL:` lines while exiting 0 is caught by the new negation, which is the hole the last audit named. The residual holes are both narrow and both P3-adjacent: a fixture whose *successful* output happened to contain the substring `FAIL` would be rejected as a false positive (no fixture does today, checked), and P1-4 Part A's vacuous PASS is invisible to the runner because its stderr noise contains neither token. The runner is not the weak link; the fixture floor is.

**Remaining gap, not otherwise filed.** No fixture asserts what a guard does when its own internals error. The 2026-09-16 P2-8 remediation established the convention and mechanized the `set` line, which is the static half. The dynamic half (inject a forced internal failure and assert the hook still decides or is loudly detectable) is still absent, and P1-4 Part B is what the absence costs: two guards escaped the static check entirely, and no dynamic check existed to catch them.

## Dependencies & Supply Chain

`claude/enforce/package.json` is unchanged since the 2026-09-16 review and remains small and current: `eslint ^10.10.0`, `eslint-plugin-import-x ^4.17.1`, `typescript-eslint ^8.69.0`, `vitest 5.0.0` pinned exact for the `tdd.sh` fixture. `package-lock.json` is committed and CI uses `npm ci` with lockfile-keyed caching. `node_modules/` is present locally and correctly ignored.

Two supply-chain observations specific to this surface:

`.github/workflows/enforce.yml` still names a dependabot config that does not exist, which was 2026-09-16 P2-9 and is unchanged (`ls .github/` returns only `workflows`). Not re-filed as a new finding; it remains open on the register. The node20-runtime deprecation that comment references lands on 2026-09-23, six days out, and the pins (`actions/checkout@v7`, `actions/setup-node@v7`) are already ahead of it, so nothing breaks next week. The exposure is that the next such deadline still has no owner.

New to this audit: `claude/enforce/package.json` and `package-lock.json` are outside the integrity manifest (P1-2). They pin the ESLint that *is* the entire `ast` tier, 35 of the 96 manifest rules. An edit to either changes what the `ast` tier enforces, and `hook-integrity-check.sh` would not notice. That is the same argument the header already accepts for `enforce/rules/*.mjs` and `lexicon.json`, applied to the dependency pins.

## Deployment & Infrastructure

No deployable artifact on this surface, so R-351 does not apply. The infrastructure that exists is `.github/workflows/enforce.yml`, and it is carefully built: `permissions: contents: read`, a concurrency group with `cancel-in-progress` scoped to pull requests only, pinned `ruff==0.16.6` with an inline rationale, `shellcheck --severity=error` with an explicit reason for the severity floor, and a `Confirm ruff resolves` step so a broken install fails on its own line rather than inside a fixture. The `Install the checkout at ~/.claude` step symlinks rather than copies, which is what keeps the fixtures exercising the real tree and what makes P2-8's live-versus-repo asymmetry harmless in CI.

Two gaps, both filed: the workflow never runs `hook-integrity-check.sh`, so the committed hash manifest is never validated where it cannot be skipped (P1-2), and its ruff comment overstates what the ruff fixture checks (P2-3).

## Bug Fix Discipline

Filed as P2-7. One unpaired `fix:` commit (`7eb41b5`, data-only), one paired (`a5b4ff1`), one test-only improvement that does not count (`90b6996`). Below the three-in-thirty-days threshold that would make it a P1 behavioural finding. `fix-commit-requires-test.sh` appears not to have fired on the unpaired one, which P2-7 flags for checking.

## Runbook-vs-Code Drift Scan

No `docs/runbooks/` tree. The functional equivalents on this surface are `claude/enforce/README.md`, the hook and module headers, `.github/workflows/enforce.yml`'s comments, and `claude/CLAUDE.md`'s bracket tags. Checked each against the code.

| Doc claim | Code reality | Direction | Severity |
|---|---|---|---|
| `hook-integrity-check.sh:7-8` "regenerate and commit the manifest: `~/.claude/hooks/hook-integrity-check.sh --update`" | writes the live copy, which `sync.sh` never prunes; the committed manifest is in the repo | Doc stale, and the cause of the phantom entries | **P1-2** |
| `hook-integrity-check.sh:10-13` "Covered: ..." | complete for what it lists; fixture trees, `judge-prompt.md`, `translate/` uncovered with no rationale | Doc understates by omission | **P1-2** |
| `enforce/README.md` "Any hook that can emit a `permissionDecision` runs `set -uo pipefail`" | `settings-change-guard.sh` emits `decision: "block"` under `set -euo pipefail`; `redact-output.sh` emits a leak warning under `set -euo pipefail` | Convention predicate too narrow | **P1-4** |
| `render-codex-gitignore.mjs:20-23` "Anything a tool drops here on its own ... stays untracked without having to be predicted" | `codex.mjs:176` unlinks it; `--check` fails on it | Comment contradicts code | **P2-2** |
| `enforce.yml:56-60` "checking that `enforce/ruff-enforce.toml` actually selects PLR2004/E731/ANN401" | the fixture drives E731, PLR2004, E722, BLE001, T201; never ANN401 | Comment stale | **P2-3** |
| `enforce/README.md:25` llm-judge tier lists R-315, R-316, R-317, R-322, R-318, R-325, R-320 | manifest has three; the judge reads the manifest only | Doc stale | **P2-4** |
| `CLAUDE.md:50` R-325 tagged `judge` | no llm-judge manifest entry for R-325 | Tag stale | **P2-4** |
| `enforce.yml:37-40` "Dependabot (`.github/dependabot.yml`) carries the next bump" | file absent | Comment stale | 2026-09-16 P2-9, still open. VERIFIER'S NOTE (R-804d, 2026-09-17): dropped, the evidence shows compliance. `.github/dependabot.yml` exists at the repo root, restored in `612551d`; the comment is true and this row is not a finding. |
| `enforce/README.md` "Hook `set` convention" cites `deny-tier-set-convention.test.sh` as enforcing it mechanically | it does, for the hooks it inspects, and reports PASS when it inspects none | Doc true, mechanism incomplete | **P1-4** |

Nine drift instances, seven new. Five of the nine share one cause: a doc written at the moment of intent and never revisited when the code's scope turned out narrower. That is the same directionality noted under Code Quality, and it argues for generating the enumerations (the tier table, the coverage list) rather than maintaining them, which is what `render-lexicon-spec.mjs` already does for the one enumeration nobody has to maintain.

## Workspace Hygiene

Clean. Searched for every `hook-hashes.txt` and every `agent-governance*` directory across the accessible roots:

```
<checkout>/claude/enforce/hook-hashes.txt
<live install>/enforce/hook-hashes.txt
<checkout>
```

One checkout and one live install copy (absolute paths elided per R-106; this audit ran in an ephemeral container, so the roots here are not the maintainer's own). No duplicate ancestor directories, no stale clone. `git config --get core.hooksPath` is unset, so R-107's drift signal is quiet and there is no supply-chain concern from that direction. `.git/hooks` in this container holds only git's stock samples, which is expected for a fresh clone and is not evidence about the maintainer's machine (see Operational Basics). No deletions recommended.

The 2026-09-16 P2-11 item (the untracked `~/.claude` copy with nothing verifying it matches the repo) is now addressed: `sync.sh` stamps `.sync-source` and `hook-integrity-check.sh:41-53` grows a live-versus-repo comparison mode, with a fixture at `hook-integrity-check.test.sh:27-41`. Verified working. Note that this second mode inherits P1-1's fail-open: it too sits after the `[ -f "$HASH_FILE" ] || exit 0` early return, so deleting the manifest disables the live-versus-repo check along with the primary one.

## Tech Debt Register

`claude/ISSUES.md` remains well maintained and I am not duplicating its contents. New debt this audit identified, for the register:

| Item | Risk |
|---|---|
| Enumeration-without-closure: four mechanisms enumerate their own coverage and nothing checks the enumeration | **High.** Root cause of P1-2, P1-3, P1-4, P2-3. The pattern has now produced four independent defects on one surface. |
| The fixture suite is outside the integrity manifest | **High.** A gutted fixture is strictly easier to hide than a gutted hook, because the dashboard stays green. |
| Missing gate input means silence in four hooks (`hook-integrity-check`, `enforcement-guard-check`, `settings-change-guard`, `redaction-guard-check`) | **Medium.** Proven for the first. Same `[ -f ... ] || exit 0` shape in all four. |
| `perl` and `python3` are undeclared hard dependencies of the hook tree | **Medium.** Present on both target hosts today; `redact-output.sh` fails silently without perl. |
| Two protected-path patterns for one concept in `secret-scan.sh` | **Medium.** They already disagree (P1-3). |
| `translate/` has no integrity coverage and CI gates on it | **Medium.** |
| Comment-versus-code drift, seven new instances, all overstating coverage | **Low individually, corrosive collectively** in a repo whose thesis is that documentation drifts unless mechanically checked. |
| Turn-end and pre-push gates enforce different check sets for the same repo | **Low.** |
| No fixture asserts fail-closed behaviour under an injected internal error | **Low, rising.** The static half is done; the dynamic half is what P1-4 Part B slipped through. |

---

## Prioritized Recommendations

| # | Recommendation | Finding | Impact | Effort |
|---|---|---|---|---|
| 1 | Make a missing or implausibly small `hook-hashes.txt` loud; give `--update` a floor and a no-shrink rule | P1-1 | **H** | **L** |
| 2 | Add a fixture asserting the committed `hook-hashes.txt` is closed over the repo checkout, and repoint the documented `--update` at the checkout | P1-2 | **H** | **L** |
| 3 | Widen the R-103 redirect pattern to tolerate a path prefix; reuse the Write/Edit branch's path logic so the two cannot disagree | P1-3 | **H** | **L** |
| 4 | Give every glob-driven fixture a floor count so none can report PASS having inspected nothing | P1-4A, P3-4 | **H** | **L** |
| 5 | Restate the `set` convention in terms of what a hook decides rather than which JSON key it uses; widen the fixture; move `settings-change-guard.sh` and `redact-output.sh` off `-e` | P1-4B | **H** | **M** |
| 6 | Extend the integrity globs to both fixture trees, `judge-prompt.md`, and `enforce/package*.json`; decide explicitly on `translate/` | P1-2 | **H** | **M** |
| 7 | Reject any translator argument the parser does not consume; add a positional case and a single-dash case to B-10 | P2-1 | **M** | **L** |
| 8 | Add the fixture-existence half of R-516 to the mechanical check, with a commented exemption list | P2-3 | **M** | **M** |
| 9 | Rewrite the generated `codex/.gitignore` header to state the actual single-owner invariant | P2-2 | **M** | **L** |
| 10 | Correct the ruff CI comment and the README llm-judge row; settle R-325's `judge` tag | P2-3, P2-4 | **M** | **L** |
| 11 | Add the translator check to `verification-gate.sh`'s monorepo branch and measure the cost | P2-5 | **M** | **L** |
| 12 | Broaden `MUTATE_VERBS` to every `sed -i` spelling plus `perl -pi`, and fixture each | P2-6 | **M** | **L** |
| 13 | Make every fixture resolve its inputs through one convention, preferring `SCRIPT_DIR` over `$HOME/.claude` | P2-8 | **M** | **M** |
| 14 | Add a fail-closed fixture that injects a forced internal error into each deciding hook | Testing | **M** | **M** |
| 15 | Extend `shellcheck` in CI to both fixture trees | Code Quality | **M** | **L** |
| 16 | Read `fix-commit-requires-test.sh` to settle whether a data-only `fix:` is deliberately exempt | P2-7 | **L** | **L** |
| 17 | Declare `perl` and `python3` as hook-tree dependencies in CI and `SETUP.md` | Testing | **L** | **L** |
| 18 | Generate the README tier table from `manifest.json` between markers, `render-lexicon-spec.mjs` style | P2-4, Architecture | **L** | **M** |
| 19 | P3 cleanup: the `in` inconsistency, the vacuous negative assertion, the `SKIP` sentinel, the dead runner branch, the unanchored `.gitignore` regexes | P3-1, P3-2, P3-3, P3-5, P3-6 | **L** | **L** |
| 20 | Decide whether Linux is a supported session host, which settles the `security` probe | P3-7 | **L** | **L** |

Items 1 through 4 are each under an hour and each close a proven hole. Item 6 is the one that makes the fixture suite trustworthy, and therefore the one that makes every other gate's green result mean something. Items 2, 8, and 18 are the same move applied three times: turn an enumeration into derived data, which is the only fix on this list that prevents the next recurrence rather than closing the current one.

---

*Findings only. Nothing in this report was applied, no git write command was run, and this file is uncommitted per the audit dispatch. Per R-802 and R-804, the dispatcher verifies each finding against the code before acting, and P2/P3 items not taken up now belong in `claude/ISSUES.md`.*
