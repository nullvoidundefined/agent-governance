# Engineering Audit: 2026-09-16

Role: CTO / Engineering (`claude/audits/engineering.md`, `claude/agents/audit-engineering.md`).
Trigger: R-801 signal raised by `claude/hooks/audit-signal-check.sh` at push time (5+ commits on ten surfaces, no engineering audit on record).
Scope: `claude/enforce`, `claude/hooks`, `claude/docs`, `claude/settings.json`, `claude/rulebook`, `claude/ISSUES.md`, `claude/CLAUDE.md`, `claude/README.md`, `claude/global-memory`, `claude/skills`.
Out of scope: `codex/`, `cursor/`, `sync-tests/`, `sync.sh`.
Discipline: R-804. Every finding pastes real content with `file:line`, names the governing rule, and carries a severity. Fixes are directions plus `to confirm`, never patches. Nothing in this report was applied.

---

## Executive Summary

The enforcement harness itself is in good health: both fixture suites are green (48 enforcement + 12 hook fixtures, run locally during this audit), the hash manifest matches the repo tree byte for byte, the manifest/settings/rule-file closure checks pass in both directions, rule-ID closure across live docs is clean, and bug-fix discipline in the review window is compliant. The work of the last 30 days was mostly high quality.

The problem is not the harness. The problem is the **monorepo migration of 2026-09-15**. On that day `~/.claude` stopped being a git repository and became an untracked copy synced by `sync.sh` from a new repo root at `agent-governance/`. Roughly a dozen hooks, rules, and docs still resolve paths as though `~/.claude` were the repo. Commit `6c841dc` fixed exactly one of them (`git-workflow-guard.sh`, by matching the remote URL instead of the path). The same fix was never applied to its siblings. The result is that the three gates that matter most for this specific repo are all silently inert, and every one of them still has a green fixture test proving it works in a world that no longer exists.

This is the "tests that pass for the wrong reasons" failure mode, and it is currently load-bearing on a **public** remote.

**Top 3 priorities**

1. **P0-1**: `global-repo-push-guard.sh` (the R-106 publish guard for a public repo) never fires for `agent-governance`. Verified empirically: it emits nothing for a push from the repo root.
2. **P1-1 / P1-2**: R-509 is unenforced. `verification-gate.sh` discovers zero checks at this repo root, no `pre-push` hook is installed, and `main` has no branch protection. The GitHub Actions `fixtures` job is the only thing that runs the suites, and it runs *after* the push, on a branch nothing protects.
3. **P0-2**: Two credential-shaped strings outside this repo need user triage (one GitHub-PAT shape, one AWS STS key-ID shape) in Claude Code session transcripts. Cannot be confirmed live from here; rotation-then-purge is the default assumption.

---

## Operational Basics

| Check | Status | Evidence |
|---|---|---|
| Tests run and pass | **YES** | `bash claude/enforce/tests/run-tests.sh` -> `ALL ENFORCEMENT TESTS PASS` (48 fixtures). `bash claude/hooks/tests/run-tests.sh` -> `ALL HOOK TESTS PASS` (12 fixtures). Both run during this audit. |
| CI exists and is green | **YES** | `gh run list`: last 6 runs on `main` `completed success`. One `failure` at `chore: migrate CI, scope paths to claude/`, fixed in the next commit. |
| CI is a merge gate | **NO (blocker)** | `gh api repos/.../branches/main/protection` -> `404 Branch not protected`. See P1-2. |
| Local pre-push gate installed | **NO (blocker)** | `.git/hooks/` contains only `*.sample` files. `claude/hooks/pre-push.sample` is tracked but was never installed here. See P1-2. |
| Turn-end verification (R-509) wired | **NO (blocker)** | `verification-gate.sh` discovers no checks at this repo root. See P1-1. |
| Publish guard (R-106) active | **NO (blocker)** | See P0-1. |
| Hash-manifest integrity | **YES** | Recomputed `hook-integrity-check.sh` hash set against `claude/`: identical to committed `enforce/hook-hashes.txt`, 70 lines, zero drift. |
| Manifest <-> settings <-> rules closure | **YES** | Every `hook:` enforcer in `manifest.json` has a script on disk and a `settings.json` registration; every mechanized tag in `CLAUDE.md` maps to a manifest enforcer; zero dangling rule IDs in live docs. |
| Rollback plan | **PARTIAL** | Git history is the rollback for the repo; `sync.sh` has no documented reverse path for a bad sync into a live `~/.claude`. Noted in P2-11, not separately filed. |

---

# P0 findings

## P0-1: the R-106 publish guard is inert for the public repo it exists to protect

**Severity: P0.** Governing rule: R-106 (`claude/CLAUDE.md:19`), enforcer tagged `[hook:global-repo-push-guard]`.

`claude/hooks/global-repo-push-guard.sh:44-46`:

```bash
ROOT_REAL=$(cd "$ROOT" 2>/dev/null && pwd -P) || exit 0
EXPECTED=$(cd "$HOME/.claude" 2>/dev/null && pwd -P) || exit 0
[ "$ROOT_REAL" = "$EXPECTED" ] || exit 0
```

`claude/CLAUDE.md:19` still states the premise this code encodes:

```
R-106: Every push of `~/.claude` is publishing (public remote): `git diff origin/main` first; no secrets, no local filesystem paths, no client-identifying content. [hook:global-repo-push-guard]
```

Both are false since 2026-09-15. `~/.claude` is no longer a git work tree (`git -C ~/.claude rev-parse --show-toplevel` -> `fatal: not a git repository`), and the public repo now lives at the `agent-governance` checkout. `ROOT_REAL` for any push from the repo therefore never equals `EXPECTED`, and the guard returns at line 46 before it ever computes the outgoing diff.

Verified empirically. Feeding the guard a real payload for a push from the repo root produced no output at all:

```
OUTPUT=[]
len=0
EXPECTED=<home>/.claude
```

The remote is confirmed public: `gh repo view --json visibility,isPrivate` -> `{"isPrivate":false,"visibility":"PUBLIC"}`.

So the last mechanical check standing between a secret or a local home path and an irreversible publish to a public remote has been off for every push since the migration. Commit `6c841dc` fixed precisely this class of breakage in `git-workflow-guard.sh` by matching the `origin` remote URL instead of the path; the sibling hook with the higher blast radius was not updated in the same commit.

The fixture conceals it. `claude/hooks/tests/global-repo-push-guard.test.sh:24-26` builds the vanished world:

```bash
export HOME="$SANDBOX"
ORIGIN="$SANDBOX/origin.git"
REPO="$HOME/.claude"
```

The suite is green and the guard is dead. This is the generalization already written into `claude/ISSUES.md` ("a fixture that sidesteps the environment quirk tests the hook against a world that does not exist"), now instantiated on the highest-severity guard in the tree.

**Fix direction.** Replace the path-equality repo test with the same dual recognition `git-workflow-guard.sh:36-40` already uses (realpath match OR `origin` URL substring match), and drive the fixture from a repo whose *remote* identifies it rather than its location, so the test cannot pass again on a stale layout assumption. `to confirm:` whether `resolve_outgoing_base` behaves identically when `ROOT` is the monorepo root rather than a `claude/`-shaped tree; whether the guard should scan the whole monorepo diff or only `claude/` (`cursor/` and `codex/` publish to the same remote and are equally exposed); and whether `CLAUDE.md:19`'s rule text should be rewritten to name the repo rather than the install path, since the rule and the hook drifted together.

## P0-2: credential-shaped strings in session transcripts outside this repo (user triage required)

**Severity: P0 pending triage.** Governing rule: R-102, R-104; audit role "Credential Exposure Scan" section.

Scan performed with `output_mode: files_with_matches` / count only. No matched value is reproduced here.

**This repo is clean.** Working tree and full git history (176 commits, all refs) contain exactly **one distinct** matching token, an all-`A` synthetic fixture, in two files:

- `claude/hooks/secret-scan.sh:30` (a documented manual-test example)
- `claude/enforce/tests/credential-mutation-guard.test.sh:39,43` (`FAKE_KEY=`)

Both are deliberate fixtures, not credentials. Nothing else matched any of the 19 vendor patterns anywhere in history.

**Transcripts need triage.** Scanning `~/.claude/projects/*/**.jsonl`:

| Transcript | Matches | Shape | Assessment |
|---|---|---|---|
| this project's dir, `.../subagents/agent-a300de18766fe7380.jsonl` | 1 | Anthropic key prefix, all-`A` body | Benign. Written by **this audit** when the fixture line was read. |
| the legacy `~/.claude` project dir, one JSONL | 2 | Anthropic key prefix, all-`A` body | Benign. Same fixture, prior sessions. |
| the legacy `~/.claude` project dir, a second JSONL | 1 | `ghp_` + lowercase-alphanumeric body | **Triage.** Does not match any fixture in this repo (all fixtures use uppercase `A` padding). Shape is consistent with a real GitHub PAT. |
| a `doppelscript` project dir, one JSONL | 1 | `ASIA` + 16 uppercase alphanumerics | **Triage.** AWS STS temporary access key ID. The key ID alone is not a secret, but its presence means temporary credentials passed through a session. |

I cannot determine from here whether either is live, and per R-805 as narrowed by this audit's dispatch I did not open the files to inspect them.

**Scan surfaces not covered.** Shell history (`~/.zsh_history`, `~/.bash_history`, `~/.config/fish/fish_history`) and vendor CLI config caches (`~/.railway/config.json`, `~/.vercel/auth.json`, `~/.stripe/config.toml`, `~/.config/gh/hosts.yml`, `~/.netrc`) were **not scanned**: both attempts were refused by the Claude Code auto-mode permission classifier. This is the harness working correctly and is recorded here as a refusal, not a gap in the method. The user should run the equivalent scan in their own terminal. Git history, working tree, and transcripts were all covered.

**Fix direction.** (a) Triage the two flagged JSONLs by shape before assuming liveness; if either resolves to a live credential, rotate at the vendor dashboard (never with the secret on argv, which is the incident that created this scan) and then delete the JSONL. (b) Run the two blocked scans manually. (c) The `PreToolUse` secret-scan hook is already installed and already fired correctly twice during this audit, so no installation step is needed. `to confirm:` whether the legacy `~/.claude` transcript directory is still being written to after the migration, or whether it is frozen history that can simply be purged wholesale.

---

# P1 findings

## P1-1: R-509 runs no checks in this repo; the verification gate discovers nothing

**Severity: P1, blocker.** Governing rule: R-509 (`claude/CLAUDE.md`, `[hook:verification-gate]`), manifest tier `regex`, severity `error`.

`claude/hooks/verification-gate.sh:105-112`:

```bash
if [ -f .claude/verify.sh ]; then
  add_check "bash .claude/verify.sh"
elif [ -f enforce/tests/run-tests.sh ] && [ -f hooks/tests/run-tests.sh ] && [ -f CLAUDE.md ]; then
  # The ~/.claude repo itself. It has no typecheck: no TypeScript source, and
  # enforce/*.mjs is plain JS with no tsc. Both fixture suites are the checks.
  add_check "bash enforce/tests/run-tests.sh"
  add_check "bash hooks/tests/run-tests.sh"
elif [ -f package.json ]; then
```

The hook `cd`s to the git toplevel (line 78) before discovery. At this repo's toplevel:

```
$ ls
.git  .github  .gitignore  claude  codex  cursor  LICENSE  README.md  sync-tests  sync.sh
$ ls .claude    -> No such file or directory
$ ls enforce    -> No such file or directory
```

No `.claude/verify.sh`, no `enforce/`, no root `package.json`, `pyproject.toml`, `go.mod`, or `Gemfile`. Every branch falls through, `CHECKS` is empty, and line 137 (`[ -n "$CHECKS" ] || exit 0`) ends the hook. The comment at line 108 still says "The `~/.claude` repo itself," naming a repo that no longer exists at that path (also R-332).

Consequence: the governance repo, which is the one repo in the user's world whose *entire purpose* is enforcing that turns do not end on a red suite, is the one repo where R-509 does nothing. A turn can end with both fixture suites red and nothing says so until CI reports after the push.

**Fix direction.** Either add a root `.claude/verify.sh` that runs both suites from `claude/` (the documented per-project override, and the smallest change), or teach the self-detection branch to look one level down for a `<dir>/enforce/tests/run-tests.sh` + `<dir>/hooks/tests/run-tests.sh` pair. `to confirm:` that `.claude/verify.sh` at the monorepo root is not itself blocked by `protected-path-guard.sh` (R-410 lists `.claude/verify.sh` as a protected gate input, so creating it may require a deliberate out-of-band write); and whether the gate should also cover `sync-tests/` and the `cursor/`/`codex/` surfaces, which today have no turn-end check either.

## P1-2: no merge gate anywhere: no branch protection, no installed pre-push hook

**Severity: P1, blocker.** Governing rule: R-509 (full suite at pre-push), plus the workflow's own stated design.

`.github/workflows/enforce.yml:3-9`:

```
# A local git hook is --no-verify-able, which makes it advisory however it is
# written. Determinism needs the check to run somewhere the author does not
# control, so this exists to be named as a required status check under branch
# protection (Settings > Branches > require status checks > "fixtures").
```

The required status check does not exist:

```
$ gh api repos/nullvoidundefined/agent-governance/branches/main/protection
{"message":"Branch not protected", "status":"404"}
```

And the local half is not installed either:

```
$ ls .git/hooks/
applypatch-msg.sample  commit-msg.sample  fsmonitor-watchman.sample  post-update.sample
pre-applypatch.sample  pre-commit.sample  pre-merge-commit.sample  pre-push.sample
pre-rebase.sample  pre-receive.sample  prepare-commit-msg.sample  push-to-checkout.sample
sendemail-validate.sample  update.sample
```

Only git's own stock samples. `bash claude/hooks/install-git-hooks.sh <repo>` was never run against this checkout.

Compounding: R-514 (ask before pushing to `main`) is *deliberately* exempted for this repo (`git-workflow-guard.sh:88`, `[ "$is_global_repo" -eq 0 ] && ...`), which is a documented override and not a violation on its own. But the exemption was written assuming the pre-push suite gate was the backstop. With neither branch protection nor a pre-push hook, the chain is: direct push to `main`, no local test run, no required check, CI reports the failure minutes later on a commit already published to a public remote.

Second defect in the same area. Even if `install-git-hooks.sh` were run here, `claude/hooks/pre-push.sample:15-22` tests the wrong tree:

```bash
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
for suite in enforce/tests/run-tests.sh hooks/tests/run-tests.sh; do
  [ -f "$CLAUDE_DIR/$suite" ] || continue
  if ! bash "$CLAUDE_DIR/$suite"; then
```

It runs the suites from the **synced live copy**, not from the checkout being pushed. A repo change not yet synced would be validated against stale code, and vice versa. Pre-migration this was the same directory; it is not any more.

**Fix direction.** Three independent changes, in increasing order of value: enable branch protection on `main` with `fixtures` required (user action, GitHub UI or `gh api`); install the pre-push hook in this checkout; and repoint `pre-push.sample` at the repo being pushed rather than `$HOME/.claude`. `to confirm:` whether branch protection with a required check is compatible with the deliberate R-514 direct-push exemption (a required status check on `main` forces a PR unless the user keeps admin bypass, which is a real tradeoff the user should decide, not the auditor); and whether `pre-push.sample` should resolve suites relative to the pushed repo's toplevel with the `$HOME/.claude` value kept only as a fallback.

## P1-3: the audit signal can never be satisfied, and counts a docs surface it claims to exclude

**Severity: P1.** Governing rule: R-801 (`claude/rulebook/audits.md:6-12`), enforcer `hook:audit-signal-check`.

`claude/hooks/audit-signal-check.sh:35-36`:

```bash
# Suffixed reports count too (e.g. -engineering-harness.md, 2026-07-31).
LAST_AUDIT=$(ls "$TOP/docs/audits" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-engineering(-[a-z-]+)?\.md$' | sort | tail -1 || true)
```

`$TOP` is the git toplevel. The nine existing engineering and harness audits live at `claude/docs/audits/`, not `$TOP/docs/audits`. `LAST_AUDIT` is therefore permanently empty and the hook permanently falls back to `BASELINE="the last 30 days (no engineering audit on record)"`.

This is not theoretical. The advisory that triggered this very audit said so verbatim:

```
audit-signal-check (R-801/R-904): the engineering-audit signal (5+ commits on a surface)
is met since the last 30 days (no engineering audit on record): claude/ISSUES.md (12 commits),
claude/enforce (19 commits), ... claude/docs (16 commits), ...
```

Two failures in one line.

First, the baseline never advances. Completing this audit will not suppress the signal on the next push, because the report has to land at `$TOP/docs/audits/` for the hook to see it, while R-802 (`claude/rulebook/audits.md:15`) says "Reports to `docs/audits/YYYY-MM-DD-<role>.md`" and every prior report is under `claude/`. An advisory that fires forever is an advisory the operator learns to scroll past, which costs the hook its entire value.

Second, `claude/docs` is reported as a hot surface despite the hook's own header (line 6-8) promising "docs/ and root-level files are excluded." Line 46:

```bash
HOT_SURFACES=$(git -C "$TOP" log --no-merges --since="$SINCE" --name-only --pretty=format:'@%H' -- . ':(exclude)docs' 2>/dev/null | awk ...
```

The pathspec `':(exclude)docs'` excludes a **top-level** `docs/` only. Post-migration the docs tree is `claude/docs`, which the exclusion misses, so 16 commits of audit reports and handoffs were counted as engineering churn and inflated this audit's scope. The comment at line 6-8 is now false (R-332).

**Fix direction.** Decide where audits live post-migration (see P2-12) and make the lookup and the exclusion agree with that decision; if reports stay under `claude/`, both the glob and the pathspec need a depth-tolerant form rather than a hardcoded top-level `docs`. `to confirm:` whether the surface key (`segments[1] "/" segments[2]`, line 50) still produces meaningful surfaces in a monorepo, where every path begins with `claude/` and the "surface" granularity has effectively shifted down one level; and whether `sync.sh` and other root-level files being skipped entirely (`segment_count < 2`, line 48) is still intended now that root-level files carry real logic.

## P1-4: the session handoff is never loaded in this repo, and its SHA no longer resolves

**Severity: P1.** Governing rule: R-001 step 1 and R-602 (`claude/CLAUDE.md`).

`claude/hooks/session-start.sh:53`:

```bash
HANDOFF="docs/session-handoff/session-handoff.md"
```

Relative path, resolved from the session cwd. Verified from both locations:

```
$ pwd -> <repo root>
$ echo '{}' | bash claude/hooks/session-start.sh | jq -r '...additionalContext' | grep "Most recent handoff doc"
NO HANDOFF SECTION INJECTED (repo root)

$ cd claude && echo '{}' | bash hooks/session-start.sh | jq -r '...additionalContext' | grep "Most recent handoff doc"
50:## Most recent handoff doc (auto-loaded per R-001, R-602 path)
```

The file exists only at `claude/docs/session-handoff/session-handoff.md`. From the repo root, which is the natural cwd for this project, the handoff is silently skipped. R-001 step 1 instructs the session to "confirm the SessionStart hook injected ... the SHA-verified `docs/session-handoff/session-handoff.md`", and in this repo that confirmation can only ever fail.

Second defect, independent of the first. `session-start.sh:61-65` verifies the handoff by resolving the first backticked hex string in it against git log. The current handoff's first such token is `b908724`:

```
$ git cat-file -e b908724^{commit}
fatal: Not a valid object name b908724^{commit}
```

The squash-merge SHAs from the pre-import `claude-global-rules` repo did not survive the history import. So even once the path is fixed, the handoff will be injected labeled `UNVERIFIED: recorded SHA not found in this repo's git log; treat contents with suspicion`, which is the exact opposite of the confidence signal the mechanism was built to carry.

Third, content drift. The handoff header still reads `# Session Handoff: 2026-09-07 slice loop (PR #16) and dependency guard plus refactor mode (PR #17) merged`, and section 2 states "Nothing is live in Ian's `~/.claude` until the branch merges and is pulled," describing the pre-migration install model. Nine days and the entire monorepo migration are missing from it.

**Fix direction.** Make the handoff path resolve where the handoff actually lives (either move the file to a root `docs/session-handoff/` or make the hook search the toplevel and one level down), and rewrite the handoff for the post-migration state with a SHA that exists in this repo's history. `to confirm:` whether R-602's canonical path should now be interpreted repo-relative or `claude/`-relative, since the same ambiguity produces P1-3 and P2-12; and whether `session-start.sh`'s deliberate "no fallback: only the canonical file qualifies" comment (line 51-55) should be relaxed, given it was written to fix a *different* wrong-path bug in 2026-07-31 and has now produced a second one.

---

# P2 findings

## P2-1: a git global option defeats every push-boundary hook, including R-514

**Severity: P2.** Governing rules: R-514, R-512, R-511, R-508, R-513, R-801, R-315/316/317 (judge), plus the four push lint gates.

`claude/hooks/git-workflow-guard.sh:41` lifts exactly two global options:

```bash
CMD=$(printf '%s' "$CMD" | sed -E 's/git([[:space:]]+(-C|-c)[[:space:]]+[^[:space:];&|]+)+/git/g')
```

Every push-boundary hook then requires `git` adjacent to the subcommand. `git-workflow-guard.sh:43`:

```bash
printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*(git[[:space:]]+(push|commit)|gh[[:space:]]+pr[[:space:]]+merge)([[:space:]]|$)' || exit 0
```

and the identical shape in `push-eslint-gate.sh:14`, `push-ruff-gate.sh:17`, `push-rubocop-gate.sh:16`, `push-golangci-gate.sh:17`, `constant-change-guard.sh:13`, `audit-signal-check.sh:17`, `single-file-folder-gate.sh:12`, `llm-rule-judge.sh:17`, `build-cheatsheets.sh:13`:

```bash
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0
```

Any other global option breaks the adjacency. Verified against a throwaway repo with a non-exempt origin:

```
CMD: git push origin main                                  -> ask     (R-514 fires)
CMD: git --git-dir=<repo>/.git push origin main            -> SILENT
CMD: git --work-tree=<repo> --git-dir=<repo>/.git push ... -> SILENT
CMD: git --no-pager push origin main                       -> SILENT  (git-workflow-guard)
CMD: git --no-pager push origin main                       -> SILENT  (audit-signal-check)
```

This is the same class as the `git -C` bypass already found and closed as 2026-08-21 P2-3, recurring because the fix enumerated two options instead of generalizing. `--git-dir`, `--work-tree`, `--no-pager`, `--exec-path`, `--namespace`, `--literal-pathspecs`, `--no-replace-objects`, and `-p` all reach the same result. It is unlikely to be hit by accident but the guards exist precisely to be non-bypassable, and a model composing a command from an unusual template reaches it without intent.

**Fix direction.** Normalize the git invocation once, in one shared place, by stripping any run of leading `git` global options rather than a hardcoded pair, and have all nine hooks consume that normalized form (the `resolveOutgoingBase.sh` sourcing pattern is the existing precedent for shared hook logic). `to confirm:` whether `--git-dir`/`--work-tree` should also redirect the inspected repository the way `-C` does at `git-workflow-guard.sh:36-40`, or whether an unrecognized redirect should instead force a conservative `ask`; and whether a single shared normalizer is worth the coupling versus a fixture that asserts each hook independently against a shared bypass corpus.

## P2-2: the hooksPath guard blocks the read its own comment exempts, and R-107 requires that read

**Severity: P2.** Governing rules: R-107 ("Investigate any `core.hooksPath` resolving outside the expected git hooks path"), R-332 (comment truth).

`claude/hooks/destructive-command-guard.sh:72-76`:

```bash
# Reads are fine; hookspath-drift-check.sh depends on them.
if printf '%s' "$norm" | grep -Eqi "${AT}git config[^|;&]*core\.hooksPath" \
    && ! printf '%s' "$norm" | grep -Eqi 'git config (--get|--get-all|--list|-l)([[:space:]]|$)'; then
    emit deny "destructive-command-guard hook BLOCKED this call: writing core.hooksPath redirects or disables every git hook in one command (R-107, R-203). Change it manually if the move is deliberate."
fi
```

The exemption covers only the explicitly-flagged read forms. The bare read form, which is the one an operator or a model actually types, is denied. Verified:

```
CMD: git config core.hooksPath          -> deny
CMD: git config --get core.hooksPath    -> SILENT
```

I hit this live during this audit: `git config core.hooksPath` was denied with that exact message while investigating hook installation, which is the R-107 investigation the rule mandates. The comment at line 72 says "Reads are fine" and is false for the common spelling (R-332).

Second layer, same problem. `claude/settings.json:49`:

```json
"Bash(git config *core.hooksPath*)",
```

in the `deny` list. This is a glob on the whole command, so it also blocks `git config --get core.hooksPath`, the form the hook deliberately exempts. Deny rules carry no exceptions, so the permission layer is strictly stricter than the guard and closes the escape hatch the guard left open.

**Fix direction.** Distinguish read from write by the presence of a value argument rather than by flag spelling, in both the hook regex and the settings glob; a `git config` invocation with `core.hooksPath` as the final token is unambiguously a read. `to confirm:` whether `settings.json`'s deny entry can express "has a trailing value" at all given prefix-glob semantics, or whether the settings rule must simply be narrowed to the write forms and the hook left as the real gate (which is the pattern `destructive-command-guard.sh`'s own header at lines 9-13 already argues for).

## P2-3: the session-injected memory index contradicts settings.json on model routing

**Severity: P2.** Governing rule: R-604, R-903; `INDEX.md` is injected verbatim into **every** session by `session-start.sh:44-48`.

`claude/global-memory/INDEX.md:35`:

```
- [`feedback_default_sonnet_proactive_switch.md`](...): **HARD RULE.** Default every session to Sonnet. Opus is the exception the user asks for. When the main session drifts into mechanical work, Claude proactively tells the user to `/model sonnet` rather than silently burning Opus. Cannot switch mid-session; must prompt user.
```

`claude/settings.json:116`:

```json
"model": "opusplan",
```

and the underlying memory file it summarizes, `claude/global-memory/feedback_default_sonnet_proactive_switch.md:13`, already records the correction:

```
- `~/.claude/settings.json` sets `"model": "opusplan"` (decided 2026-09-05 after the config audit): Opus while in plan mode, Sonnet for execution...
```

`claude/ISSUES.md` (Resolved, 2026-09-05) claims this contradiction is closed: "The Sonnet-default memory now records the `opusplan` decision instead of contradicting settings.json." The *file* was updated. The **index line was not**, and the index line is the one that reaches the model every single session while the corrected file is read-on-demand and usually never read. The remediation landed on the surface nobody sees and skipped the surface everybody sees.

Third-party inconsistency in the same block: `INDEX.md:8` marks `feedback_model_routing.md` "**Canonical** model-routing rule. Opus for hard tasks, Sonnet for medium, Haiku for simple," while line 35 marks a different file "**HARD RULE.** Default every session to Sonnet." Two entries, both claiming primacy, both injected together. Also minor: "Cannot switch mid-session" is false, `/model` switches mid-session, which is the premise of `model-switch-guard.sh`.

**Fix direction.** Bring `INDEX.md:35` in line with the file it summarizes and resolve which of lines 8 and 35 is canonical; more durably, a fixture asserting that each `INDEX.md` one-liner does not contradict the `settings.json` key it describes would make this class self-detecting, since it has now recurred twice. `to confirm:` whether any other `INDEX.md` summary has drifted from its file (this audit checked only the two model-routing entries).

## P2-4: a global memory file claims an enforcement the rulebook says does not exist

**Severity: P2.** Governing rules: R-903, R-332.

`claude/global-memory/feedback_default_sonnet_proactive_switch.md:13`:

```
`hooks/model-switch-guard.sh` asks before any manual switch up the price ladder. The contradiction the audit filed as P1-3 is closed.
```

`claude/rulebook/cost.md:22`:

```
  Enforcement: manual. hooks/model-switch-guard.sh exists and is unit-tested, but PreModelSwitch is not a real Claude Code hook event, so it is never invoked by the harness. Routing stays honor-system until a real event exists
```

Both statements are about the same script. `cost.md` is correct: cross-checking `settings.json`, `model-switch-guard.sh` is one of only five scripts in `hooks/` with no registration under any event, and the other four are helpers invoked by their parents (`clean-code-scan.mjs`, `dependency-add-scan.py`, `log-rule-fire.sh`) or manual setup (`install-git-hooks.sh`). `model-switch-guard.sh` is the only *guard* that is registered nowhere.

`cost.md`'s honest disclosure means the inert hook itself is a **documented override, not a violation** (R-804(b)). The finding is the contradiction: the memory file asserts the protection exists and declares the prior audit's P1 closed, and memory files are the artifact a future session trusts when deciding whether a risk is handled. The optimistic claim outlives the honest one.

**Fix direction.** Make the memory file defer to `cost.md` rather than restate enforcement independently, and reopen the "closed" claim to state what actually closed it (`model: opusplan` in settings) versus what did not (the hook). `to confirm:` whether `PreModelSwitch` has since become a real hook event on the installed build, which would flip this finding entirely and is a one-command check.

## P2-5: `strict-permissions.json` documents a configuration that was replaced two commits ago

**Severity: P2.** Governing rule: R-332.

`claude/enforce/strict-permissions.json:2`:

```json
"_comment": "... Kept here as the documented swap-in. settings.json allows the whole Bash tool with a single \"Bash\" entry (the 2026-09-04 config audit collapsed the 45 prefix entries it made redundant); to adopt strict, replace that entry with the `allow` list below, which is the curated prefix list minus the interpreter and network entries, and add the `ask` entries (deny stays identical either way). The residual risk of the lenient list is recorded in ISSUES.md.",
```

Commit `8f249b6` ("chore(settings): adopt the strict Bash permission list") already did this. `claude/settings.json:4-38` now *is* the strict list, and `Bash(bash *)` / `Bash(sh *)` are in `ask` at lines 111-112 exactly as `ask_additions` prescribes. The comment describes a `settings.json` that no longer exists, instructs the reader to perform a migration already performed, and points at an ISSUES.md risk entry that has moved to `## Resolved`.

The file is now a duplicate of live configuration with no stated relationship to it. Two copies of the same list with no sync check is the drift shape that `lexicon-spec-sync.test.sh` was written to prevent for the verb registry.

**Fix direction.** Either retire the file now that its contents are live, or rewrite `_comment` to state its new role and add a fixture asserting the two lists agree, matching the `lexicon.json` / `reference.md` precedent. `to confirm:` whether anything besides prose references `strict-permissions.json` (a grep of `hooks/` and `enforce/` found no consumer, so retiring it appears safe, but `settings-change-guard.sh` and `enforcement-guard-check.sh` derive their required sets from `manifest.json` and should be re-read before deleting).

## P2-6: `claude/README.md` misstates its own title and five inventory counts

**Severity: P2.** Governing rule: R-508 (README updated in the same commit as structure change); spec-vs-implementation drift.

`claude/README.md:1`:

```markdown
# claude-global-rules
```

The repo is `agent-governance`; `claude/` is one of three peer folders. `README.md` at the root says so; `claude/README.md` still opens as though it were the repository root.

`claude/README.md:36` (counts verified against the tree):

```
... the 40 hook scripts under `hooks/` ... and 43 fixture tests), the 10 convention files ..., the 13 custom skills under `skills/` ..., the 31 global-memory files, the R-001..R-906 rule formalization in `CLAUDE.md` ...
```

| Claim | Actual | Source |
|---|---|---|
| 40 hook scripts | **47** (excluding `install-git-hooks.sh`) | `ls hooks/*.sh hooks/*.mjs hooks/*.py` -> 48 |
| 43 fixture tests | **60** (48 enforcement + 12 hook) | `ls enforce/tests/*.test.sh`, `ls hooks/tests/*.test.sh` |
| 13 custom skills | **15** | `ls -d skills/*/` |
| 31 global-memory files | 31 | correct |
| 10 convention files | 10 | correct |
| `R-001..R-906` | highest is **R-908** | `R-907`, `R-908` in `rulebook/cost.md` |

`claude/README.md:51` compounds it: "`hooks/`, wired in `settings.json` (44 scripts across 8 events)". Actual: 48 command registrations across **7** events (`PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, `Stop`, `SubagentStop`, `ConfigChange`). `claude/README.md:127` repeats "43 fixture tests" in the tree diagram.

Individually cosmetic. Collectively this is the README of a project whose thesis is that documentation drifts unless it is mechanically checked, drifting.

**Fix direction.** Correct the title and counts, and consider generating the inventory numbers the way `reference.md`'s verb lists are generated from `lexicon.json` between markers, with a fixture failing on divergence. `to confirm:` whether the three-tool monorepo wants one root README plus thin per-tool READMEs, or three full ones, since that decision determines how much of `claude/README.md:1-40` is even the right content for this file now.

## P2-7: a fixture mutates live user configuration outside any sandbox

**Severity: P2.** Governing rule: R-401 (tests that fail when the implementation is wrong; the nine anti-patterns), test hygiene.

`claude/enforce/tests/structure-gate.test.sh:3` sets `set -euo pipefail`, then at lines 71-80:

```bash
# R-313 co-location exemption is scoped to repos named in colocated-test-repos.txt.
COLOCATED_FIXTURE=$(mktemp -d)
ALLOWLIST="$HOME/.claude/enforce/colocated-test-repos.txt"
ALLOWLIST_BACKUP=$(mktemp)
cp "$ALLOWLIST" "$ALLOWLIST_BACKUP" 2>/dev/null || : >"$ALLOWLIST_BACKUP"
printf '%s\n' "$COLOCATED_FIXTURE" >>"$ALLOWLIST"
allow "{\"tool_name\":\"Write\",...}"       # exempt repo
deny  '{"tool_name":"Write",...}'            # non-exempt repo still denied
cp "$ALLOWLIST_BACKUP" "$ALLOWLIST"
rm -rf "$COLOCATED_FIXTURE" "$ALLOWLIST_BACKUP"
```

Three problems, in order of severity.

Under `set -e`, if either the `allow` or the `deny` assertion on lines 77-78 fails, the script exits before line 79 and the live `$HOME/.claude/enforce/colocated-test-repos.txt` **keeps the appended temp path permanently**. The restore has no `trap`. That file is the R-313 co-location exemption allowlist: a guard input, left mutated by a failing test run. Blast radius is bounded (the leaked line names a deleted `mktemp` directory that can never match a real file), which is why this is P2 and not higher, but a test that can permanently edit a guard's input on failure is the wrong shape regardless.

The test is not hermetic and not re-entrant. Two concurrent runs clobber each other's backup and restore. R-501 explicitly contemplates parallel sessions on the same tree.

The file is the one piece of live `~/.claude` state that does **not** exist in the repo (confirmed by `diff -rq ~/.claude/enforce <repo>/claude/enforce` -> `Only in ~/.claude/enforce: colocated-test-repos.txt`), and it is gitignored at `claude/.gitignore:59` as client-identifying. In CI, where `$HOME/.claude` is a symlink into the workspace, this test **creates** the file inside the checkout and leaves an empty one behind.

**Fix direction.** Point the hook's allowlist lookup at an overridable variable the way `enforcement-guard-check.sh` uses `CLAUDE_MANIFEST_FILE` / `CLAUDE_SETTINGS_FILE`, so the fixture can supply a temp allowlist and never touch live state; failing that, wrap the mutation in a `trap ... EXIT` restore. `to confirm:` whether `structure-gate.sh:96` is the only consumer of `COLOCATED_ALLOWLIST` (grep suggests yes) and whether the same live-file pattern appears in the other fixtures, which this audit did not exhaustively check.

## P2-8: deny-tier guards use `set -euo pipefail` and fail open silently on an internal error

**Severity: P2.** Governing rule: R-203, R-405 (never weaken the protection that surfaced the failure).

Two conventions coexist in `claude/hooks/` with nothing documenting the split.

`set -euo pipefail` (33 scripts), including every deny-tier gate: `secret-scan.sh`, `content-gate.sh`, `structure-gate.sh`, `no-em-dash.sh`, `commit-message-guard.sh`, `conflict-markers.sh`, `fix-commit-requires-test.sh`, `global-repo-push-guard.sh`, `mcp-action-guard.sh`, `migration-defaults-guard.sh`.

`set -uo pipefail`, no `-e` (6 scripts): `destructive-command-guard.sh`, `destructive-db-guard.sh`, `protected-path-guard.sh`, `dependency-add-guard.sh`, `codex-billing-guard.sh`, `verification-gate.sh`.

No `set` at all (7 advisory reminders): `clean-code-reminder.sh`, `dockerfile-reminder.sh`, `flat-directory-reminder.sh`, `log-rule-fire.sh`, `new-file-header-reminder.sh`, `observability-reminder.sh`, `spec-glossary-check.sh`.

Under `-e`, any unexpected non-zero exit inside the hook terminates it before it can emit a `permissionDecision`, and a `PreToolUse` hook that emits nothing is an allow. The guard fails **open**, silently, with no log line. The six scripts in the second group made the safer choice; the ten deny-tier scripts in the first group did not, and there is no note anywhere explaining why the same author chose differently.

This has already bitten once. `claude/ISSUES.md` (Resolved, 2026-08-21) records it verbatim:

```
A `set -e` landmine introduced by the P2-3 fix (an unguarded `grep` in a command
substitution silenced the entire hook) was caught by the new fixtures, not by review.
```

The remediation fixed the instance. The class is untouched, and no fixture in either suite asserts that a guard fails closed when its own internals error: the closest thing, `hook-latency.test.sh`, discards output with `|| true`.

**Fix direction.** Pick one convention for deny-tier guards, write it into `enforce/README.md`, and add a fixture that injects a forced internal failure (an unset command, a missing input file) into each deny-tier hook and asserts the hook still produces a decision or is loudly detectable. `to confirm:` how Claude Code actually treats a `PreToolUse` hook that exits non-zero with empty stdout (the assumption here is "allow", which is the conservative reading of the observed behavior but should be verified on the installed build before the fix is sized); and whether `emit`/`deny` helpers can be restructured so an early `-e` exit is impossible rather than merely unlikely.

## P2-9: the CI workflow names a dependabot config that does not exist

**Severity: P2.** Governing rule: R-332; dependency and supply-chain hygiene.

`.github/workflows/enforce.yml:37-40`:

```
      # v7: the v4 majors of both actions declare a node20 runtime, which GitHub
      # removes from hosted runners on 2026-09-23. Dependabot (.github/dependabot.yml)
      # carries the next bump.
      - uses: actions/checkout@v7
```

```
$ ls .github/
workflows
$ cat .github/dependabot.yml
cat: .github/dependabot.yml: No such file or directory
```

`claude/ISSUES.md` (Resolved, 2026-09-04) lists `.github/dependabot.yml` as shipped with the config-audit remediation. It existed in the pre-migration repo; commit `cb503d3` ("chore: migrate CI, scope paths to `claude/`") brought the workflow across and left dependabot behind.

Consequence: nothing bumps the pinned `actions/checkout@v7`, `actions/setup-node@v7`, `ruff==0.16.6` (`enforce.yml:60`), or the `claude/enforce/package.json` dependency set (`eslint ^10.10.0`, `eslint-plugin-import-x ^4.17.1`, `typescript-eslint ^8.69.0`, `vitest 5.0.0` pinned exact). The comment asserts a bump mechanism that is not present, and the GitHub runtime deprecation it references lands on **2026-09-23, seven days from this audit**. The current pins are ahead of that deadline, so nothing breaks next week; the exposure is that the next such deadline has no owner.

**Fix direction.** Restore `.github/dependabot.yml` scoped to `/claude/enforce` (npm) and `/` (github-actions), or delete the comment's claim if automated bumps are deliberately not wanted in this repo. `to confirm:` whether the pre-migration `dependabot.yml` is recoverable from history under its old path, and whether its ecosystem directories need re-scoping for the `claude/` prefix the way `enforce.yml` was.

## P2-10: a new skill prescribes a TDD loop that the enforced harness will block

**Severity: P2.** Governing rules: R-412 (`[hook:protected-path-guard]`), R-410, R-411.

`claude/skills/build-by-slice-require-review/SKILL.md` (added `dd8827b`, the newest commit in scope), "TDD rules (every task)":

```
1. **Red:** write the failing test first; run it and confirm it fails.
2. **Green:** write the minimal implementation to pass.
3. **Refactor:** clean up with tests green.
```

R-412 (`claude/CLAUDE.md`) is the mechanized version of the same loop:

```
R-412: Work in slices: `tdd.sh open`, the failing test, `tdd.sh red` before any production edit, `tdd.sh green` before the commit, `tdd.sh close`; the lock denies production writes while open and test writes once red. [hook:protected-path-guard]
```

The skill never mentions `tdd.sh`, `enforce/tdd-lock.json`, the lock states, or R-412. A session that follows the skill literally will attempt production edits without an open slice and test edits after RED, both of which `protected-path-guard.sh` denies. The model then has a skill it was told to follow and a guard denying it, with no instruction on which wins.

Compounding, the trigger surfaces collide. Three skills claim overlapping phrases in their `description` frontmatter:

- `build-by-slice-require-review`: "Triggers on \"build\", \"implement\", \"start the slice\", \"next slice\", or kicking off work from an approved spec."
- `tdd-gated-dispatch`: "Use for any Standard, Complex, or Saga task once a spec exists, to run each behavior as one RED/GREEN/REFACTOR/REVIEW slice with the harness proving each step."
- `feature-create`: "Use when starting implementation of a feature that already has an approved plan... Triggers on \"start feature\", \"create feature\", \"kick off\"."

`tdd-gated-dispatch` is the harness-aware one. `build-by-slice-require-review` is the newer, more specific-sounding one, and it is the one that omits the harness.

Separately, the skill asserts as fact: "No auto-merge, no CLI merge; branch protection requires manual approval." Branch protection is not enabled on this repo (P1-2), so in the repo where the skill was authored the statement is false.

**Fix direction.** Have `build-by-slice-require-review` delegate its inner TDD cycle to `tdd-gated-dispatch` / `tdd.sh` rather than restate it, and disambiguate the three descriptions so one skill owns each trigger phrase. `to confirm:` whether the skill was intended as a Claude-Code-enforced procedure at all or as portable prose cloned to the `cursor/` and `codex/` ports (commit `dd8827b` says "cloned to codex and cursor ports"), which are outside this audit's scope and have no `tdd.sh`; if it is deliberately harness-free for portability, the fix is a scope note in the skill, not a rewrite.

## P2-11: `~/.claude` is an untracked full copy and nothing verifies it matches the repo

**Severity: P2.** Governing rule: R-107 (supply-chain drift signal), R-203; workspace hygiene.

Post-migration, `~/.claude` is a plain directory, not a symlink and not a git work tree:

```
$ ls -ld ~/.claude        -> drwxr-xr-x  (regular directory)
$ readlink ~/.claude      -> (nothing)
$ git -C ~/.claude rev-parse --show-toplevel
fatal: not a git repository (or any of the parent directories): .git
```

`sync.sh` copies content in. The live copy currently agrees with the repo:

```
$ diff -rq ~/.claude/hooks <repo>/claude/hooks       -> (no differences)
$ diff -rq ~/.claude/enforce <repo>/claude/enforce   -> Only in ~/.claude/enforce: colocated-test-repos.txt
$ diff -rq ~/.claude/rulebook <repo>/claude/rulebook -> (no differences)
$ diff -rq ~/.claude/skills <repo>/claude/skills     -> (no differences)
```

That agreement is a fact about today, not an invariant. `hook-integrity-check.sh:25-26` compares the live tree against `$CLAUDE_DIR/enforce/hook-hashes.txt`, where `CLAUDE_DIR` defaults to `$HOME/.claude`. Both sides of that comparison are the live copy. A hand-edit to a live hook followed by `hook-integrity-check.sh --update` is self-consistent and invisible to the repo. Conversely a repo change not yet synced is live nowhere. Nothing in either suite asserts `~/.claude == <repo>/claude`.

Pre-migration this could not happen: the install directory *was* the git work tree, so `git status` was the drift check. That property was traded away in the migration without a replacement, and R-107's whole premise is that the enforcement surface on disk must be verifiable against a committed manifest.

The one live-only file, `enforce/colocated-test-repos.txt`, is deliberately gitignored (`claude/.gitignore:59`, R-106 client-identifying) and is a documented exception, not a violation. See P2-7 for how it gets created.

**Fix direction.** Give the integrity check a second mode that compares the live install against the repo checkout (a `CLAUDE_INTEGRITY_ROOT` is already threaded through `hook-integrity-check.sh:22` and makes this cheap), and surface divergence at `SessionStart` the way hooksPath drift already is. `to confirm:` whether `sync.sh` or `sync-tests/` already covers this (both are out of scope for this audit and were not read); and whether the intended end state is a copy at all rather than a symlink, since a symlink would restore the original invariant for free and the CI workflow already installs it that way (`enforce.yml:71-73`).

## P2-12: audit reports and the R-802 canonical path now disagree

**Severity: P2.** Governing rule: R-802 (`claude/rulebook/audits.md:15`).

```
  - Reports to `docs/audits/YYYY-MM-DD-<role>.md`.
```

Nine prior reports live at `claude/docs/audits/` (`2026-07-03-engineering.md` through `2026-09-06-tdd-harness.md`). `audit-signal-check.sh:36` reads `$TOP/docs/audits`. `$TOP` is the repo root. The two locations are different directories and the rule text names neither unambiguously.

This report is written to `<repo>/docs/audits/2026-09-16-engineering.md` per its dispatch instruction, which is also the only location `audit-signal-check.sh` can see. That choice splits the audit history across two directories and should be resolved deliberately rather than by accretion.

Related stale record: `claude/ISSUES.md` still lists as open "P3 (2026-08-21 workspace hygiene): a duplicate clone of this repo's remote sits at `~/Desktop/code/personal/production/claude-config-snapshot`". A `find` across `~/Desktop`, `~/dev`, `~/code`, and `~/projects` for any directory matching `agent-governance*`, `claude-global-rules*`, `claude-config*`, `openai-global-rules*`, or `cursor-global-rules*` returned exactly one result: `<repo>`. A second search for any other tree containing an `enforce/` directory or a `hook-hashes.txt` also returned only this repo. The duplicate is gone; the issue entry is not.

**Fix direction.** Pick one home for audit reports, move the other eight there in one commit, and make `audits.md:15` state the path unambiguously relative to the repo root; then close the stale `claude-config-snapshot` entry. `to confirm:` whether `codex/` and `cursor/` are ever expected to carry their own audit reports, which decides whether a shared root `docs/audits/` or a per-tool one is correct.

---

# P3 findings

## P3-1: an allowed command prefix may auto-approve a chained destructive command

**Severity: P3, uncertain.** Governing rule: R-203.

`claude/settings.json:6` (`allow`) and `:102` (`ask`):

```json
      "Bash(cd *)",
...
      "Bash(rm -rf *)",
```

If permission matching is whole-string prefix matching, `cd /somewhere && rm -rf /something` matches the `allow` entry at line 6 and never reaches the `ask` entry at line 102, because `ask` globs are also prefix-anchored. This is structurally the same escape as the `bash -c` interpreter escape that commit `8f249b6` just closed by moving `Bash(bash *)` and `Bash(sh *)` to `ask`. The 2026-07-31 harness audit stated the premise explicitly: "Permission matching is on the command string, so `bash -c \"git push --force\"` or `sh -c \"rm -rf ~/x\"` matches an `allow` prefix and never reaches the `ask` entry."

Mitigations that keep this at P3: `deny` is evaluated first in every mode and still catches `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`; and `destructive-command-guard.sh` sees the full untruncated string. But `destructive-command-guard.sh:1-14` covers `gh api`, `curl|interpreter`, `core.hooksPath`, credential readout, and hooks-directory tampering, and does **not** cover `rm -rf`, so for that specific verb the settings list is the only layer.

**Fix direction.** If the escape is real, the pattern that closed it for interpreters applies here too: any allow entry whose command can precede a `&&` is a potential prefix. `to confirm:` **this finding is unverified and may be a false positive.** Whether Claude Code decomposes `&&`/`;`-joined commands and evaluates each segment against the permission lists independently is decidable in one experiment and settles the finding entirely. Do that before spending any effort on a fix.

## P3-2: `skipDangerousModePermissionPrompt` sits against R-203

**Severity: P3, documented risk.** `claude/settings.json:436`:

```json
  "skipDangerousModePermissionPrompt": true,
```

This removes the confirmation step in front of bypass-permissions mode in a configuration whose R-203 reads "never bypass a guard without the word 'approved' from the user in the current turn." Flagged in two prior audits already (`claude/docs/audits/2026-07-31-engineering-harness.md:438`, `2026-07-31-security.md:193`) and left in place, which makes it an accepted risk rather than a fresh finding. It is repeated here only because it is not recorded in the `### Accepted risks` block of `claude/ISSUES.md`, so the acceptance lives in two archived audit reports and nowhere a future session will look.

**Fix direction.** Move the acceptance into `claude/ISSUES.md` under `### Accepted risks (deliberate, revisit on incident)` where the other standing tradeoffs live, or remove the key. `to confirm:` nothing; this is a recording decision for the user.

## P3-3: repairing P0-1 will make the publish guard block legitimate pushes

**Severity: P3.** Direct consequence of the P0-1 fix, filed so it is not discovered as a surprise.

`claude/hooks/global-repo-push-guard.sh:82-83` scans added lines of the outgoing diff against:

```bash
PATTERN='sk-ant-api03-[A-Za-z0-9_-]{50,}'
```

Two tracked files contain full-length matches that clear that threshold: `claude/hooks/secret-scan.sh:30` (the documented manual-test invocation) and `claude/enforce/tests/credential-mutation-guard.test.sh:39,43`. They are synthetic all-`A` padding, not credentials. `secret-scan.sh:26` and `:47` note that discussion references "stay under the length threshold", but the example at line 30 is 54 characters of padding and does not.

The guard only inspects *added* lines, so this bites only when one of those lines is touched or the file is moved. But the P0-1 fix is likely to involve moving or editing exactly these files' neighbors, and a hard `deny` on a legitimate push of the fixture that proves the guard works is a confusing first experience of the repaired guard.

**Fix direction.** Shorten the padding in the two fixture literals to just clear the `{50,}` boundary from below where the test permits, or construct them at runtime the way `global-repo-push-guard.test.sh:66` already does (`FAKE_TOKEN="ghp_$(printf 'A%.0s' $(seq 1 35))"`). `to confirm:` whether `credential-mutation-guard.test.sh` requires a literal to exercise the path it tests, or whether runtime construction preserves the assertion.

## P3-4: the session-start SHA file is shared across all concurrent sessions

**Severity: P3.** Governing rule: R-501, R-602.

`claude/hooks/session-start.sh:83-85`:

```bash
if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  git rev-parse HEAD 2>/dev/null > "${TMPDIR:-/tmp}/claude-session-start-sha" || true
fi
```

One fixed filename, no session or project key. `session-end.sh` reads it to compute the R-602 velocity metric. Two sessions in different repos, or two worktrees of the same repo (which R-501 actively encourages), and the second session start overwrites the first session's baseline. The commit count in the resulting handoff is then wrong, silently and in a direction that flatters.

**Fix direction.** Key the file by session id or by a hash of the repo toplevel, the way `verification-gate.sh:96` already keys its memo file (`MEMO_FILE="$MEMO_DIR/$(printf '%s' "$ROOT" | shasum | awk '{print $1}')"`). `to confirm:` whether the session id is available in the `SessionStart` payload; if not, the repo-toplevel hash is the available approximation and still fixes the cross-project case.

## P3-5: `CLAUDE.md` marks R-203 `[manual]` while two hooks enforce it

**Severity: P3.** `claude/CLAUDE.md`:

```
R-203: Stay inside the safety harness; fix what fires and never bypass a guard without the word "approved" from the user in the current turn. [manual]
```

`claude/enforce/manifest.json` carries two entries for R-203: `hook:hook-integrity-check` (advisory/warn) and `hook:destructive-command-guard` (regex/error). The `CLAUDE.md` preamble defines the bracket as naming the enforcer and `[manual]` as "depends on recall".

This under-claims in the safe direction (the model believes recall is the only defense when a hook also exists), so it causes no unsafe behavior. It is filed because it is the only such mismatch in the whole corpus, and because the cross-check that would have caught it (`enforcement-guard-check.sh`, `manifest.test.sh`) reads only `rulebook/*.md` `Enforcement:` lines and never reads `CLAUDE.md`'s bracket tags, despite `manifest.test.sh:4-5` claiming otherwise:

```bash
# and closure against the rule files: every hook:/eslint:/ruff: named in a CLAUDE.md
# or rules/*.md Enforcement line has a manifest entry for that rule id,
```

The code at lines 12-16 reads `rulebook/reference.md`, `agents.md`, `audits.md`, `cost.md` only. The comment is false (R-332). I ran the missing direction manually during this audit: 71 tagged rules in `CLAUDE.md`, zero enforcers cited there without a manifest entry, so the gap is currently harmless.

**Fix direction.** Either correct R-203's bracket, or extend the closure test to parse `CLAUDE.md`'s bracket syntax so the check matches its own docstring. `to confirm:` whether the bracket tags are intended to be exhaustive per rule or to name only the primary enforcer, since four other rules (R-101, R-102, R-107, R-516) also list fewer hooks than the manifest does and are fine under the "primary enforcer" reading.

---

## Architecture & Design

The layering is sound and unusually well-reasoned. Rules are data (`manifest.json`, `lexicon.json`, `role-policy.json`), enforcement is code (`hooks/`, `enforce/rules/`), prose is a separate tier (`rulebook/`), and the boundaries between them are checked mechanically in both directions. The generated-verb-list pattern (`renderLexiconSpec.mjs` writing between markers in `reference.md`, with `lexicon-spec-sync.test.sh` failing on divergence) is the correct answer to doc drift and should be the template for the drift findings above (P2-3, P2-5, P2-6).

The structural weakness is a single unstated assumption repeated across the tree: **"`~/.claude` is the git repo."** It appears in `global-repo-push-guard.sh:45`, `verification-gate.sh:107-108`, `audit-signal-check.sh:36,46`, `session-start.sh:53`, `pre-push.sample:15`, `CLAUDE.md:19`, `README.md:1`, and the fixtures that back several of them. One commit (`6c841dc`) fixed one instance. Fixing the remaining seven individually will leave the eighth; the durable move is to define repo identity once (remote URL, as `git-workflow-guard.sh:36-40` already does) and have everything consume it.

Coupling is otherwise low and the dependency direction is clean: hooks depend on `enforce/` data, not the reverse; `resolveOutgoingBase.sh` and `log-rule-fire.sh` are the only shared helpers and both are sourced defensively with `|| true` fallbacks.

## Code Quality

Hook scripts are consistently structured: header comment stating purpose, rule ID, and known limitations (`R-320` applied to shell); `set` line; stdin drain; early return on non-matching input; helper functions for `deny`/`ask`; `exit 0`. Headers routinely state what the hook *cannot* see, which is rare and valuable.

Two quality gaps, both filed above: the `set -e` convention split (P2-8) and comments that outlived their code (P2-2 line 72, P2-9 line 39, P2-12 / `verification-gate.sh:108`, `manifest.test.sh:4-5`). R-332 is the governing rule for all four and is tagged `[manual]`, which is exactly the tier where this class recurs.

No dead code found beyond `model-switch-guard.sh`, which is documented as inert (P2-4) and therefore not dead by accident. `ntfy-notify.sh` was removed cleanly in `6133d97` with its settings wiring and its ISSUES entries in the same commit; that is the right shape.

`shellcheck` is not installed on this machine, so no static analysis of the 48 shell scripts was possible. That is a gap in this audit, not a finding: adding `shellcheck` to the CI `fixtures` job would be cheap and would catch the `set -e` landmine class (P2-8) and quoting issues before a fixture has to.

## Security

Covered by P0-1 (publish guard inert), P0-2 (credential scan), P2-2 (hooksPath read denied), P3-1 (chained-command prefix escape), P3-2 (`skipDangerousModePermissionPrompt`).

Working as designed, verified during this audit: `redact-output.sh` fired correctly twice on tool output containing full-length credential patterns and returned a redacted copy with an explicit exposure warning. `destructive-command-guard.sh` blocked a `core.hooksPath` write pattern. The auto-mode classifier refused two attempts to read shell history and vendor CLI config directories. Three independent layers each did their job unprompted.

The `deny` list correctly covers the R-102 read surfaces (`.env` variants, `~/.aws`, `~/.ssh`, `~/.gnupg`, `gh hosts.yml`, `~/.netrc`) and `security find-generic-password*`. The known `.env.*` glob gap is already recorded in `claude/ISSUES.md` as config-audit P1-4 residue and is a documented tradeoff, not a finding.

No prompt-injection surface in scope: the only LLM call is `llm-rule-judge.sh`, which is gated on a key that is documented as not yet provisioned, and `enforcement-guard-check.sh:52-58` warns at every session start that the judge tier cannot run. That disclosure is the correct handling of an inert tier and is a direct remediation of a prior P0.

## Credential Exposure Scan

Full results and methodology in **P0-2**. Summary:

| Target | Result |
|---|---|
| Git history, all refs (176 commits) | Clean. One distinct token, a synthetic all-`A` fixture, in two files. |
| Working tree incl. untracked | Clean. Same two fixture files. |
| Session transcripts, all 31 project dirs | 4 files matched. 3 benign (the same fixture). **2 need user triage** (one `ghp_` shape, one `ASIA` shape), both outside this repo. |
| Shell history | **Not scanned.** Blocked by the auto-mode permission classifier. |
| Vendor CLI configs | **Not scanned.** Blocked by the auto-mode permission classifier. |
| Editor / tool caches | Not scanned (low priority, no direct match surfaced in the broader sweep). |

No matched value appears anywhere in this report. Rotations completed: **none** (auditors do not rotate, R-802). Rotations pending: the two triage items, if triage confirms them live. The `PreToolUse` secret-scan hook is installed and demonstrably working, so remediation step (c) from the role definition is already satisfied.

## Database / API Design / Deployment

Not applicable. This repo has no database, no HTTP surface, and no deployed artifact. `claude/CLAUDE-DATABASE.md`, `CLAUDE-BACKEND.md`, and `CLOUD-DEPLOYMENT.md` are convention documents *about* those surfaces for other projects, not implementations, and were out of this audit's scope.

The one deployment-adjacent surface, `.github/workflows/enforce.yml`, is reviewed under P1-2 and P2-9. Its construction is careful: concurrency group with `cancel-in-progress` scoped to PRs only, `permissions: contents: read`, pinned ruff, explicit rationale for why ruff is installed for real while rubocop and golangci are stubbed. The `push`/`pull_request` overlap that double-billed every PR branch is already fixed and documented inline.

## Performance

Client-side polling: not applicable, no client.

Hook latency is governed by `claude/enforce/tests/hook-latency.test.sh`, which is the right design: it reads the registered chains from `settings.json` rather than a hand-kept list (the hand-kept list drifted in three consecutive audits), and normalizes against a same-environment bare-spawn control with an absolute floor. It passes.

One structural observation, not a finding. The `PreToolUse`/`Bash` chain is 20 hooks. Nine of them are push-boundary gates carrying `"if": "Bash(git *)"`, and all nine also self-guard internally on a `git push` regex (verified in each). The `if` key is not documented in the settings reference this audit could consult, so it is either an effective pre-filter or an ignored key; either way behavior is correct, because the self-guards are the real filter. The redundancy is deliberate defense in depth and costs one `jq` spawn per Bash call in the worst case, which `hook-latency.test.sh` measures and accepts. Flagging only so the `if` key is understood as belt-and-braces rather than load-bearing.

## Testing

60 fixtures, both suites green. Quality is above average for this kind of repo: fixtures assert observable decisions (`permissionDecision == "deny"`, empty output for allow) rather than mock call counts, they build throwaway git repos and drive the real scripts, and several deliberately drive real binaries (`push-ruff-gate.test.sh` runs actual ruff, which is why CI installs it).

Gaps, in priority order:

1. **Fixtures encoding a vanished environment.** P0-1 is the case in point: a green test for a dead guard. `claude/ISSUES.md` already generalizes this from the 2026-08-21 audit ("a fixture that sidesteps the environment quirk tests the hook against a world that does not exist") and names three offenders. P0-1 adds a fourth, on the highest-severity guard in the tree. The generalization is correct and has now been proven twice; it deserves promotion from an ISSUES line to a fixture-review checklist item.
2. **No fail-closed assertions.** Nothing tests what a guard does when its own internals error (P2-8).
3. **A fixture mutating live state** (P2-7).
4. **Test runner accepts partial passes.** `enforce/tests/run-tests.sh:11` and `hooks/tests/run-tests.sh:10`: `if out=$(bash "$t" 2>&1) && printf '%s' "$out" | grep -q "PASS"`. A test that prints both `FAIL: case A` and `PASS: case B` and exits 0 is reported `ok`. `global-repo-push-guard.test.sh` is exactly this shape (`set -uo pipefail`, per-case `check()` printing `PASS:`/`FAIL:`, `exit "$fail"`), so its non-zero exit saves it, but the runner's `grep -q "PASS"` is not what makes it safe. **P3, not separately filed above:** tighten the runner to require a terminal `ALL ... PASS`-style sentinel or to reject any output containing `FAIL`. `to confirm:` which fixtures emit per-case `PASS:` lines versus a single terminal one, since the two conventions coexist.
5. **Session-lifecycle hooks are environment-heavy** and thinly tested; already recorded as an open P3 in `claude/ISSUES.md` with an honest rationale, so not re-filed.

## Dependencies & Supply Chain

`claude/enforce/package.json` is small and current: `eslint ^10.10.0`, `eslint-plugin-import-x ^4.17.1`, `typescript-eslint ^8.69.0`, `vitest 5.0.0` (pinned exact, deliberately, for the `tdd.sh` fixture). `package-lock.json` is committed, and CI uses `npm ci` with lockfile-keyed caching and an `|| npm install` fallback. The 2026-09-04 remediation already moved off the deprecated `eslint-plugin-import` to `import-x` and recorded 0 advisories.

`node_modules/` is present in the working tree and correctly ignored at both `/.gitignore:1` and `claude/enforce/.gitignore:1`.

The supply-chain gap is process, not inventory: no dependabot (P2-9). Nothing bumps these pins, and nothing scans for new advisories between audits.

## Bug Fix Discipline

Scanned the last 60 days of commits touching `claude/` (window chosen larger than the 30-day minimum to cover the pre-migration history import). Fourteen `fix:`-prefixed commits.

**Paired with a test change (12):** `6c841dc`, `5746912`, `319cc8d`, `f54de18`, `a7c28cb`, `5fc4bc8`, `d315f97`, `01464bc`, `36dbb66`, `c2ffb08`, `936a514`, `2d0343a`.

**Unpaired (2):**

- `8119719` `fix(audits): replace the absolute home path in the engineering report`. Touched only `claude/docs/audits/2026-08-21-engineering.md`. A prose correction to an archived document; R-403 governs bug fixes to code. **Not a violation.**
- `7ce4e2f` `fix(settings): close the interpreter allow-list escape and gate the cheatsheet auto-exec`. Touched `claude/hooks/build-cheatsheets.sh` and `claude/settings.json`, no test file. A genuine unpaired fix to product code, and a security-relevant one. Outside the 30-day window. Already recorded in `claude/ISSUES.md` alongside the analogous `266d05e`.

**Verdict: compliant.** Zero unpaired code fixes inside the 30-day review window; the single in-window `fix:` (`6c841dc`) shipped with `claude/enforce/tests/git-workflow-guard.test.sh` in the same commit. One unpaired fix in 60 days is a P2 pattern note per the role definition, and it is already on the register. `fix-commit-requires-test.sh` is doing its job.

## Runbook-vs-Code Drift Scan

No `docs/runbooks/` tree exists. The functional equivalents are `claude/SETUP.md`, `claude/README.md`, `claude/PROTOCOL.md`, and the skill files, checked against code:

| Doc claim | Code reality | Direction | Severity |
|---|---|---|---|
| `CLAUDE.md:19` "Every push of `~/.claude` is publishing" | `~/.claude` is not a repo; guard inert | Both stale | **P0-1** |
| `audits.md:15` "Reports to `docs/audits/...`" | Nine reports at `claude/docs/audits/`; hook reads `$TOP/docs/audits` | Ambiguous | **P1-3 / P2-12** |
| `verification-gate.sh:108` "The `~/.claude` repo itself" | No such repo; branch unreachable | Comment stale | **P1-1** |
| `audit-signal-check.sh:6-8` "docs/ and root-level files are excluded" | `claude/docs` counted, 16 commits | Comment stale | **P1-3** |
| `destructive-command-guard.sh:72` "Reads are fine" | Bare read form denied | Comment stale | **P2-2** |
| `enforce.yml:39` "Dependabot (`.github/dependabot.yml`) carries the next bump" | File absent | Comment stale | **P2-9** |
| `strict-permissions.json:2` "settings.json allows the whole Bash tool with a single `Bash` entry" | Strict list already adopted in `8f249b6` | Comment stale | **P2-5** |
| `manifest.test.sh:4-5` "every ... named in a CLAUDE.md or rules/*.md Enforcement line" | Reads `rulebook/*.md` only | Comment stale | **P3-5** |
| `README.md:36,51,127` inventory counts | Five counts wrong | Doc stale | **P2-6** |
| `INDEX.md:35` "HARD RULE ... default to Sonnet" | `settings.json:116` `"model": "opusplan"` | Doc stale | **P2-3** |
| `feedback_default_sonnet...md:13` "model-switch-guard asks before any manual switch" | `cost.md:22`: never invoked | Doc stale | **P2-4** |
| `build-by-slice...SKILL.md` "branch protection requires manual approval" | No branch protection | Doc stale | **P1-2 / P2-10** |

Twelve drift instances. Eight of them trace to the 2026-09-15 migration. This is the single highest-yield category in the audit and the one with the clearest common cause.

## Workspace Hygiene

Searched `~/Desktop`, `~/dev`, `~/code`, `~/projects` to depth 4-5 for directories matching `agent-governance*`, `claude-global-rules*`, `claude-config*`, `openai-global-rules*`, `cursor-global-rules*`, and separately for any tree containing `enforce/` or `hook-hashes.txt`.

**One checkout only:** `<repo>`. The `claude-config-snapshot` duplicate filed in the 2026-08-21 audit is gone; its `claude/ISSUES.md` entry is stale and should be closed (P2-12).

The remaining hygiene item is the untracked `~/.claude` copy (P2-11). It is not a duplicate checkout, so it does not fragment git history, but it is a second ancestor directory for the same content with no verification that the two agree. No deletions recommended.

## Tech Debt Register

Existing register (`claude/ISSUES.md`) is well maintained: one line per item, dated, with the reasoning inline and a substantial `## Resolved` section. Two maintenance actions fall out of this audit: close the `claude-config-snapshot` entry (resolved, P2-12) and record the `skipDangerousModePermissionPrompt` acceptance under `### Accepted risks` where it belongs (P3-2).

New debt identified by this audit, for the register:

| Item | Risk |
|---|---|
| Repo identity is re-derived independently in 8+ places | **High.** Root cause of P0-1, P1-1, P1-3, P1-4. Will recur on the next path change. |
| Deny-tier guards fail open on internal error, untested | **Medium.** Observed once (2026-08-21), class untouched. |
| `~/.claude` live copy has no drift check against the repo | **Medium.** The migration traded away `git status` as the drift detector. |
| Push-boundary hooks enumerate git global options instead of stripping them | **Medium.** Second occurrence of the same bypass class. |
| Nine inventory counts and comments drift with no mechanical check | **Low.** Individually cosmetic, collectively corrosive to a repo about drift. |
| Test runner accepts partial passes | **Low.** No fixture currently exploits it. |
| `shellcheck` absent from CI | **Low.** Would have caught the `set -e` class statically. |

---

## Prioritized Recommendations

| # | Recommendation | Finding | Impact | Effort |
|---|---|---|---|---|
| 1 | Repair the R-106 publish guard to recognize the repo by remote URL, and rebuild its fixture around remote identity | P0-1 | **H** | **L** |
| 2 | Triage the two credential-shaped transcript matches; run the two classifier-blocked scans manually | P0-2 | **H** | **L** |
| 3 | Wire R-509 for this repo (root `.claude/verify.sh` or depth-tolerant self-detection) | P1-1 | **H** | **L** |
| 4 | Enable branch protection with `fixtures` required; install the pre-push hook; repoint `pre-push.sample` at the pushed repo | P1-2 | **H** | **L** |
| 5 | Define repo identity **once** and have all eight consumers read it, instead of fixing each path individually | P0-1, P1-1, P1-3, P1-4, Architecture | **H** | **M** |
| 6 | Decide the canonical audit and handoff location; move the eight prior reports; fix the lookup and the `':(exclude)docs'` pathspec | P1-3, P1-4, P2-12 | **M** | **L** |
| 7 | Generalize the git global-option strip across all nine push-boundary hooks | P2-1 | **M** | **M** |
| 8 | Correct `INDEX.md:35` and add a fixture asserting `INDEX.md` summaries do not contradict `settings.json` | P2-3, P2-4 | **M** | **M** |
| 9 | Settle the `set -e` convention for deny-tier guards; add fail-closed fixtures | P2-8 | **M** | **M** |
| 10 | Stop `structure-gate.test.sh` mutating live user config | P2-7 | **M** | **L** |
| 11 | Fix the bare `core.hooksPath` read false positive in both the hook and the settings deny glob | P2-2 | **M** | **L** |
| 12 | Restore `.github/dependabot.yml` scoped for the monorepo layout | P2-9 | **M** | **L** |
| 13 | Reconcile `build-by-slice-require-review` with R-412 and disambiguate the three overlapping skill triggers | P2-10 | **M** | **M** |
| 14 | Add a live-vs-repo drift check to `hook-integrity-check.sh` | P2-11 | **M** | **M** |
| 15 | Correct `claude/README.md` title and counts; consider generating the inventory | P2-6 | **L** | **L** |
| 16 | Retire or re-scope `strict-permissions.json` | P2-5 | **L** | **L** |
| 17 | Settle the `&&`-chaining permission question experimentally before acting on it | P3-1 | **L** | **L** |
| 18 | Add `shellcheck` to the CI `fixtures` job | Code Quality | **L** | **L** |
| 19 | Tighten both test runners to reject partial passes | Testing | **L** | **L** |
| 20 | `ISSUES.md` maintenance: close `claude-config-snapshot`, record the `skipDangerousModePermissionPrompt` acceptance | P2-12, P3-2 | **L** | **L** |

Items 1 through 4 are each under an hour and each close a blocker. Item 5 is the one that prevents the next recurrence.

---

*Findings only. Nothing in this report was applied. Per R-802 and R-804, the dispatcher verifies each finding against the code before acting, and P2/P3 items that are not taken up now belong in `claude/ISSUES.md`.*
