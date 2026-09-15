# Engineering Audit: the five new enforcement hooks in `enforce/` and `hooks/` (2026-08-21)

## Scope

`~/.claude` on `main`, HEAD `a6c25a3` (`feat(enforce): mechanize R-514, R-512, R-511, R-508, and R-501`). Scoped per dispatch to the R-801 5+ commit signal since the 2026-07-31 engineering audit: `enforce/tests` (8 commits) and `enforce/hook-hashes.txt` (8 commits). Priority surface is the four commits `b16bcee..a6c25a3`:

| Commit | Surface |
|---|---|
| `8244974` | `hooks/structure-gate.sh` R-304 and R-305 checks |
| `b0b26e2` | `hooks/content-gate.sh` (new), `hooks/mcp-action-guard.sh` (new) |
| `a6c25a3` | `hooks/git-workflow-guard.sh` (new), `hooks/parallel-session-check.sh` (new) |

Dependencies read outside that boundary only where a scoped file cites them: `settings.json` registrations and permission lists, `enforce/manifest.json`, `enforce/hook-hashes.txt`, the `CLAUDE.md` norm lines and `rulebook/reference.md` `Enforcement:` lines for R-105/R-302/R-304/R-305/R-401/R-405/R-501/R-508/R-511/R-512/R-514, `CLAUDE-BACKEND.md` and `CLAUDE-FRONTEND.md` (the conventions R-304 and R-305 encode), and the sibling hooks the new ones interact with (`destructive-db-guard.sh`, `single-file-folder-gate.sh`, `secret-scan.sh`, `enforcement-guard-check.sh`, `hook-integrity-check.sh`, `build-cheatsheets.sh`).

Method: read every new hook and its fixture test; ran both fixture suites (`enforce/tests/run-tests.sh` 33/33 green, `hooks/tests/run-tests.sh` green); ran `hook-integrity-check.sh` and `enforcement-guard-check.sh` live (both silent, exit 0); executed each new hook directly against ~70 hand-built payloads covering the bypass and false-positive shapes the dispatch named (chained commands, heredocs, quoting, symlinked paths, `git -C`, short flags, refspec forms, camelCase tool names, package.json dependency variants, oversized command payloads); built throwaway git and monorepo fixtures under the scratchpad for every claim that needed a real repository or a real `package.json`; deregistered `git-workflow-guard.sh` from a settings copy to test the R-516 meta-guard's coverage of the new tier; diffed the registered `PreToolUse:Bash` chain against the modelled chain in `hook-latency.test.sh`; ran the Bug Fix Discipline scan over the last 60 commits; ran the credential-exposure sweep described below. Every finding below was reproduced on this machine; hypotheses that did not reproduce were dropped and are listed under "Probed and cleared".

## Executive summary

The five hooks are competent work. They are small, single-purpose, uniformly fail-open, uniformly documented with a header comment stating both intent and the deliberate carve-outs, and every one ships a fixture test that would fail if the hook were deleted. The manifest, `settings.json`, `hook-hashes.txt`, and both rule files are in agreement: no drift, no unregistered enforcer, no missing execute bit, no stale hash. Both prior-audit P1s are genuinely closed and the R-516 meta-guard was generalized past the specific gap that was reported.

The problem is coverage honesty rather than construction quality. Three of the five hooks match a narrower set of inputs than the rule text and the `Enforcement:` line claim, and in each case the gap is reachable through an ordinary idiom rather than an adversarial one. `git push origin HEAD` does not ask. A camelCase MCP tool name does not ask. A Neon or Supabase MCP `run_sql` reaches a managed production database with no gate of any kind, because `destructive-db-guard.sh` reads `.tool_input.command` and an MCP payload has none. Each of these looks enforced from the manifest and reads as enforced in `reference.md`, and that is worse than an honestly unenforced rule, because the mechanization is what retires the recall.

Top three priorities:

1. **P1-2**, the ungated MCP database path. R-101 and R-105 both have named enforcers and neither one can see a `run_sql` call. Two of the user's project configurations enable `neon` and `supabase` MCP servers today.
2. **P1-1**, `git push origin HEAD` and `git push origin refs/heads/main` silently skip R-514's ask while `reference.md:427` claims "any push whose target branch resolves to `main`/`master`".
3. **P1-3**, camelCase MCP tool names bypass `mcp-action-guard.sh` entirely, which is a whole naming convention outside the rule's only enforcer.

## Operational basics

| Check | Answer | Evidence |
|---|---|---|
| Do the tests run? | Yes | `enforce/tests/run-tests.sh` 33/33 `ALL ENFORCEMENT TESTS PASS`; `hooks/tests/run-tests.sh` `ALL HOOK TESTS PASS` |
| Is the suite wired to a trigger? | Yes, one trigger, unversioned | `.git/hooks/pre-push` runs both suites; it lives in `.git/hooks/`, is not tracked, and exists only on this machine |
| Is there CI? | No | no `.github/` directory; the pre-push hook is the only gate |
| Is monitoring in place? | Partial | `hooks/log-rule-fire.sh` writes `global-memory/rule_fires.md`; `hook-integrity-check.sh` and `enforcement-guard-check.sh` warn at SessionStart |
| Is there a rollback plan? | Yes | every hook is a tracked file in a git repo with a hash manifest; `hook-integrity-check.sh --update` is the documented re-baseline path |
| `core.hooksPath` drift (R-107)? | None | unset, matches the expected default |
| Working tree clean at audit time? | One expected modification | `M global-memory/rule_fires.md`, the telemetry file written by the hooks themselves |

Not a blocker, but stated plainly: the entire test-execution guarantee for this repository rests on one untracked file. A fresh clone of `claude-global-rules.git` has no gate at all, which is exactly the state the duplicate clone found under Workspace Hygiene is in.

## P0

None. The credential sweep produced no live secret; see the Credential Exposure Scan section for the full triage.

## P1

### P1-1: `git push origin HEAD` bypasses R-514's ask, and `reference.md` claims it does not

`hooks/git-workflow-guard.sh:62-72` derives the push target from the second non-flag argument:

```
62	if [ "$is_global_repo" -eq 0 ] && printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+push([[:space:]]|$)'; then
63	  PUSH_ARGS=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+push[^;&|]*' | head -1 |
64	    sed -E 's/^git[[:space:]]+push[[:space:]]*//' | tr ' ' '\n' | grep -vE '^(-.*)?$' || true)
65	  REFSPEC=$(printf '%s\n' "$PUSH_ARGS" | sed -n '2p')
66	  TARGET="$BRANCH"
67	  [ -n "$REFSPEC" ] && TARGET="${REFSPEC##*:}"
68	  case "$TARGET" in
69	    main | master)
```

`TARGET` is the literal refspec text, not a resolved branch. Three ordinary forms of a direct push to `main` therefore produce no ask. Reproduced against a fixture repo checked out on `main`:

```
$ probe 'git push origin main'            -> ask
$ probe 'git push origin HEAD'            -> (no output, allowed)
$ probe 'git push origin refs/heads/main' -> (no output, allowed)
$ probe 'git push origin +main'           -> (no output, allowed)
```

`git push origin HEAD` is the most common explicit-remote push form there is, and on a `main` checkout it pushes to `main`. `refs/heads/main` is the fully qualified spelling git itself prints in its own error messages. `+main` is the force-refspec form, which is the case where the ask matters most.

The gap contradicts the rule file. `rulebook/reference.md:427`:

```
  Enforcement: hook:git-workflow-guard (asks before `gh pr merge` and before any push whose target branch resolves to `main`/`master`; the ~/.claude repo is exempt, its pushes being R-106's business)
```

"Resolves to" is precisely what the code does not do. `CLAUDE.md:95` carries the same claim through `[hook:git-workflow-guard]` on R-514, whose norm is "direct pushes to `main` only on express request after naming the risks."

Governing rule: R-514 (`hook:git-workflow-guard`).

Direction: resolve the refspec to a branch name before the `case`, rather than pattern-matching the raw text. The source side of a colon-form refspec is what needs resolving (`HEAD` to the current branch, `refs/heads/X` to `X`, a leading `+` stripped), and the existing `BRANCH` variable already holds the answer for the `HEAD` case. To confirm: whether `git rev-parse --abbrev-ref` against the destination side is safe to call inside a PreToolUse hook on every push (it is a local ref lookup, but confirm the latency against `hook-latency.test.sh`'s budget), and whether `git push origin HEAD:refs/heads/main` and `git push origin ':main'` (delete-branch form) should ask, deny, or pass, since the current `${REFSPEC##*:}` already handles the colon form correctly and a fix must not regress it.

### P1-2: MCP database tools reach a managed database with no gate, defeating both R-101's and R-105's enforcers

`hooks/destructive-db-guard.sh:14-16` is the named enforcer for R-101 ("Never run destructive data-loss actions against production... any write to a managed/remote DB, needs explicit confirmation this turn"):

```
14	input="$(cat)"
15	cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
16	[ -z "$cmd" ] && exit 0
```

An MCP tool payload has no `.tool_input.command`, so the hook exits 0 on line 16 for every MCP call. It is also registered only against the `Bash` matcher in `settings.json`. The new `mcp-action-guard.sh` is the only hook on the `mcp__.*` matcher, and its verb list (`hooks/mcp-action-guard.sh:26-33`) contains no `run`, `execute`, `query`, or `sql`:

```
27	    send | post | reply | forward | publish | share | invite | notify | respond)
29	    create | save | update | edit | write | add | apply | upload | move | duplicate | rename | submit | merge | generate | mark)
31	    delete | remove | trash | drop | archive | revoke | rotate | cancel | unmark | unlabel)
```

Reproduced:

```
$ mcp__db__execute_sql  -> (silent)
$ mcp__db__run_query    -> (silent)
```

`settings.json`'s `permissions.deny` and `permissions.ask` lists carry no MCP entries at all (17 deny entries, 31 ask entries, every one of them `Bash(...)`), so there is no second line of defence. This is not hypothetical: `~/.claude.json` enables `neon` and `railway-mcp-server` for `templates/template-graphql-js`, and `neon`, `supabase`, `railway`, `vercel`, `cloudflare`, `github`, `sentry`, `resend` for `projects/fullstack_ai_portfolio_projects`. The Neon MCP server's write primitive is `run_sql`; Supabase's is `execute_sql`. A `DROP TABLE` or `DELETE FROM` issued through either reaches a managed Postgres with no confirmation, which is the exact incident `destructive-db-guard.sh:9-11` says it was written after ("a staging wipe... integration-test cleanup ran against a remote DB and deleted real records").

Precedence check: R-105's own norm enumerates "delete, drop, rotate, send, post, create". A `run_sql` carrying `DROP TABLE` is a drop, so this is inside R-105's scope and not an out-of-scope extension of it. R-101 is the more specific rule for the database case and is unambiguous about managed and remote databases.

Governing rules: R-101 (`hook:destructive-db-guard`), R-105 (`hook:mcp-action-guard`).

Direction: two independent changes, and the second does not substitute for the first. Extend `mcp-action-guard.sh`'s verb list with the execution family (`run`, `execute`, `query`, `sql`, `migrate`, `deploy`, `restart`, `terminate`, `refund`, `transfer`) so a mutating call at least asks; and give the SQL-bearing MCP tools a content check equivalent to what `destructive-db-guard.sh` already does for Bash, since the verb in `run_sql` carries none of the destructiveness signal that `DROP` in the argument does. To confirm: the exact tool names the configured Neon and Supabase MCP servers expose (read them from the running server's tool list rather than guessing, since a verb list keyed to guessed names is the failure mode this finding is about); whether `destructive-db-guard.sh` should be registered on the `mcp__.*` matcher with a second input path reading the SQL argument, or whether the SQL check belongs in `mcp-action-guard.sh` to keep one hook per matcher; and whether any read-only MCP SQL tool exists that a blanket ask would make unusably noisy.

### P1-3: camelCase MCP tool names bypass `mcp-action-guard.sh` entirely

`hooks/mcp-action-guard.sh:25` lowercases the tool name before splitting it into verb tokens:

```
25	for token in $(printf '%s' "${TOOL##*__}" | tr 'A-Z-' 'a-z_' | tr '_' ' '); do
```

`tr 'A-Z-' 'a-z_'` destroys the camelCase word boundary instead of using it as a split point, so a camelCase action collapses into one unrecognized token. The header comment at lines 12-14 states the design intent as "Verbs are matched per token, not on the leading word", and that intent holds only for snake_case and kebab-case names. Reproduced:

```
$ mcp__linear__createIssue        -> (silent)
$ mcp__linear__updateIssue        -> (silent)
$ mcp__github__createPullRequest  -> (silent)
$ mcp__slack__chat_postMessage    -> (silent)
$ mcp__figma__use_figma           -> (silent)
$ mcp__figma__create_new_file     -> ask   (control: snake_case works)
```

`use_figma` is a separate miss in the same hook and needs no camelCase to trigger: the Figma MCP server's own instructions in this environment list it first under "Write designs INTO Figma from code, intent, or existing components (use_figma, generate_figma_design, create_new_file, upload_assets)". Three of those four ask; `use_figma`, the one the server documents as mandatory-skill-gated, does not.

The fixture test does not cover the case. `enforce/tests/mcp-action-guard.test.sh:9-27` uses snake_case and kebab-case names exclusively, so the suite is green while a whole naming convention passes through.

Governing rule: R-105 (`hook:mcp-action-guard`).

Direction: split on the camelCase boundary before lowercasing rather than after, so `createIssue` yields `create issue`; add `use` to the write-verb list, or special-case the Figma server the way the browser server is special-cased in the opposite direction. To confirm: whether inserting a separator at every lower-to-upper transition produces false verb tokens on real server names (check the actual tool lists of the configured servers, not synthetic names), and whether `use` as a general verb is too broad to be worth the noise compared with an explicit `use_figma` entry.

## P2

### P2-1: R-304 denies files in client packages that carry `express` as a devDependency

`hooks/structure-gate.sh:134-138` accepts a dependency match from any of the three dependency blocks:

```
134	package_depends_on() {
135	  jq -e --arg dep "$2" \
136	    '(.dependencies[$dep] // .devDependencies[$dep] // .peerDependencies[$dep]) != null' \
137	    "$1" >/dev/null 2>&1
138	}
```

and `structure-gate.sh:154-160` uses that to decide whether a `src/` root is "the Express server's src/ root":

```
154	if [ -n "$PACKAGE_FILE" ] && [[ "$FILE" == *.ts ]] && [[ "$FILE" != *.d.ts ]] && [ "$(basename "$PARENT_DIR")" = "src" ]; then
158	      if package_depends_on "$PACKAGE_FILE" express; then
159	        deny "'$BASE' would sit loose at the Express server's src/ root (R-304). ..."
```

`express` in `devDependencies` is a routine shape in a Vite or Next client package (a preview server, an SSR harness, a static-build server). Reproduced against a fixture client package whose `package.json` is `{"dependencies":{"react":"^18.3.0"},"devDependencies":{"express":"^4.19.0"}}`:

```
$ Write apps/client/src/setupTests.ts
  -> deny: 'setupTests.ts' would sit loose at the Express server's src/ root (R-304). That root is a fixed layer vocabulary: config/, constants/, types/, schemas/, middleware/, routes/, handlers/, services/, repositories/, clients/, database/, dependencyInjection/, prompts/, workers/...
```

The client is told to file a test-setup module under `repositories/` or `dependencyInjection/`, vocabulary that belongs to R-304's server track and that R-305 (`CLAUDE.md:42`) does not contain. This blocks legitimate work and gives wrong guidance while doing it.

The fixture picks the happy case and so cannot catch this. `enforce/tests/structure-gate.test.sh` (added by `8244974`) writes the client fixture as `printf '%s\n' '{"dependencies":{"react":"^18.3.1"}}' >"$VOCAB_FIXTURE/apps/client/web/package.json"` and then asserts `allow ... apps/client/web/src/queryClient.ts  # client src/ root out of scope`. There is no fixture in which one package carries both dependencies.

Governing rules: R-304 vs R-305 precedence. R-305 is the more specific rule for a package whose `src/` is a client tree, so an `express` devDependency must not let R-304's vocabulary land there.

Direction: make the scoping decision positive about which stack the package is rather than which dependency happens to be present. Checking `react` first and short-circuiting the R-304 branch when it matches would resolve the collision, as would restricting the `express` lookup to runtime `dependencies`. To confirm: whether any real server package in the user's projects declares `express` only in `devDependencies` (which would break the narrower lookup), and whether a package carrying both `react` and `express` as runtime dependencies exists anywhere (a classic SSR server), because that case needs an explicit precedence decision rather than an ordering accident.

### P2-2: R-305's prescribed component folder is the layout `single-file-folder-gate.sh` warns against

`hooks/structure-gate.sh:167-171` denies a flat component and names the replacement path:

```
167	if [ -n "$PACKAGE_FILE" ] && [[ "$FILE" == *.tsx ]] && [ "$(basename "$PARENT_DIR")" = "components" ]; then
168	  if package_depends_on "$PACKAGE_FILE" react; then
169	    COMPONENT_NAME="${BASE%.tsx}"
170	    deny "'$BASE' would sit loose in components/ (R-305). Each component owns a folder: components/$COMPONENT_NAME/$BASE alongside $COMPONENT_NAME.module.scss. Write it at that path instead."
```

`hooks/single-file-folder-gate.sh:29-30,46-48` counts `.module.scss` as a non-source file, so the prescribed folder holds exactly one source module:

```
29	    index.ts|index.tsx|constants.ts|types.ts) return 1 ;;
30	    __init__.py|constants.py|types.py|conftest.py|test_*.py|*_test.py) return 1 ;;
...
46	  if [ "$count" -eq 1 ]; then
47	    echo "single-file-folder-gate: '$dir' holds one source module; R-309 prefers a flat file. Add a second module or exempt the folder in .enforce.json." >&2
```

Reproduced end to end. A fixture repo where `src/components/Header/` holds exactly `Header.tsx` and `Header.module.scss`, the layout `CLAUDE-FRONTEND.md:44-47` prescribes verbatim:

```
$ printf '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | single-file-folder-gate.sh
single-file-folder-gate: 'src/components/Header' holds one source module; R-309 prefers a flat file. Add a second module or exempt the folder in .enforce.json.
```

One hook denies the flat file and orders the folder; the other warns that the folder should be flat. The escape hatch (`.enforce.json` `singleFileFolderExemptions`) is a per-directory list, so honoring both hooks means one exemption entry per component in every React repo.

Precedence: `CLAUDE-FRONTEND.md:47` ("Each component gets its own folder: `ComponentName/ComponentName.tsx` + `ComponentName.module.scss`") and `CLAUDE.md:42` R-305 ("one component per folder (`components/Header/Header.tsx`)") are the more specific rule for component directories, so R-309's general preference yields. The contradiction is in the R-309 enforcer, not in the new R-305 check, but the new check is what made it reachable.

Governing rules: R-305 (specific) over R-309 (general).

Direction: teach `single-file-folder-gate.sh`'s `is_source` or its per-directory loop that a folder whose single source module is a PascalCase `.tsx` matching the folder name is an R-305 component folder and exempt by construction. To confirm: whether the same pairing convention applies to feature-local `features/<name>/components/` trees (this audit observed the R-305 deny firing there too, which is consistent with `CLAUDE-FRONTEND.md` but was never explicitly decided), and whether a component folder with a co-located `.test.tsx` should still count as single-source under the existing test exclusions at `single-file-folder-gate.sh:28`.

### P2-3: `git -C <path>` bypasses `git-workflow-guard.sh` completely

`hooks/git-workflow-guard.sh:21` is the hook's sole trigger:

```
21	printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*(git[[:space:]]+(push|commit)|gh[[:space:]]+pr[[:space:]]+merge)([[:space:]]|$)' || exit 0
```

The pattern requires the subcommand to immediately follow `git`, so any global option between them defeats it. Reproduced against a fixture repo on `main`:

```
$ probe 'git push origin main'             -> ask
$ probe 'git -C /tmp/repo push origin main' -> (no output, allowed)
```

`git -C` is not exotic: it is the form this audit itself used throughout, and it is the natural form whenever the agent is not already in the target repository. The same bypass removes the R-511 and R-508 commit advisories for `git -C <path> commit`. Other global options (`-c user.name=X`, `--git-dir=`, `--no-pager`) bypass identically.

Verified not a bypass, for contrast: `cd /tmp && git push` does ask (the `&` in `&&` satisfies the leading character class), and `echo git push origin main` correctly does not fire.

Governing rules: R-514, R-512, R-511, R-508 (all `hook:git-workflow-guard`).

Direction: allow an optional run of global options between `git` and the subcommand in the trigger pattern, and make the same allowance in the `PUSH_ARGS` extraction at line 63 so the argument parsing does not then mistake `-C` or its path for the remote. To confirm: whether `sed -E 's/^git[[:space:]]+push[[:space:]]*//'` at line 64 still yields the right first-and-second positional arguments once global options can precede `push` (a `git -C /path push origin main` must not treat `/path` as the remote), and whether any sibling Bash hook shares the same `git[[:space:]]+<verb>` trigger shape and needs the same widening (`build-cheatsheets.sh:14` and `single-file-folder-gate.sh:12` use a looser `git[[:space:]]+push` pattern that does not have this specific hole but should be checked for consistency).

### P2-4: `gh pr merge -m` and `-r` bypass R-512's deny and downgrade to an ask

`hooks/git-workflow-guard.sh:44-48`:

```
44	if printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
45	  if printf '%s' "$CMD" | grep -qE '[[:space:]]--(merge|rebase)([[:space:]]|=|$)'; then
46	    deny "This merges the PR with a strategy R-512 does not allow. ..."
47	  fi
48	  ask "R-514: merging a PR needs explicit user authorization in the current turn, ..."
```

Only the long flags are matched. `gh pr merge` documents `-m, --merge` and `-r, --rebase` as equivalent short forms. Reproduced:

```
$ probe 'gh pr merge 42 --merge'  -> deny
$ probe 'gh pr merge 42 -m'       -> ask
$ probe 'gh pr merge 42 -r'       -> ask
```

The fallthrough to `ask` means the user is still prompted, so this is a downgrade rather than a hole, and `settings.json`'s pre-existing `"Bash(gh pr merge*)"` ask entry provides the same backstop. The finding is that the R-512 hard prohibition becomes a confirmable prompt for exactly the two spellings a user in a hurry is most likely to type.

Separately in scope and unenforced: R-512's norm is "Squash-merge feature branches; one commit per feature on `main`", and a local `git merge --no-ff feature/x` on `main` is the same violation with no `gh` involved. Reproduced as silent. `reference.md:415` scopes the enforcement claim honestly ("denies `gh pr merge --merge` and `--rebase`"), so this is a rule-coverage gap rather than doc drift.

Governing rule: R-512 (`hook:git-workflow-guard`).

Direction: extend the strategy pattern at line 45 to the short flags, taking care that a bare `-m` in a `gh` context is unambiguous (it is not `--message` for `gh pr merge`, but confirm against the installed `gh` version's help output rather than from memory). To confirm: whether `gh pr merge` supports flag bundling (`-md`) on the installed version, and whether a local `git merge` on `main` should join this hook's scope or is deliberately left to R-512's manual tier.

### P2-5: content and structure gates are blind to file creation through Bash

`hooks/content-gate.sh:14-15` and `hooks/structure-gate.sh:9-10` both exit on any tool that is not `Write` or `Edit`:

```
content-gate.sh:14	TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
content-gate.sh:15	case "$TOOL" in Write | Edit) ;; *) exit 0 ;; esac
```

Identical content therefore passes or fails purely on delivery mechanism. Reproduced with a heredoc that writes a loose module at an Express `src/` root containing both a wildcard CORS origin and an `it.only`:

```
$ (as Bash: cat > .../apps/server/src/logger.ts <<'EOF' ... EOF)
content-gate.sh    -> silent
structure-gate.sh  -> silent

$ (as Write: same content, same path)
content-gate.sh    -> deny
```

The precedent for closing this is in the same tree: `hooks/secret-scan.sh:43` reads all three fields at once, `(.tool_input.command // "") + "\n" + (.tool_input.content // "") + "\n" + (.tool_input.new_string // "")`, and is registered on both matchers. Heredoc file creation is a normal scaffolding idiom, not an adversarial one, so this will fire in ordinary use rather than only under attack.

Governing rules: R-401, R-405, R-302 (`hook:content-gate`); R-304, R-305, R-306, R-311, R-312, R-313 (`hook:structure-gate`).

Direction: for `content-gate.sh` the cheapest honest improvement is the `secret-scan.sh` treatment, folding `.tool_input.command` into the scanned text and registering the hook on the Bash matcher too, accepting that the path-derived `is_test` and R-302 depth checks degrade to unavailable for that input. For `structure-gate.sh` the equivalent is extracting redirect and `mkdir` targets from the command, which is materially harder and may not be worth it. To confirm: what the added Bash-matcher spawn does to `hook-latency.test.sh`'s `PreToolUse:Bash` budget (that chain already carries 18 hooks); and whether scanning command text for `it.only` produces false denies on legitimate commands such as `npx vitest run -t 'it.only'` or a grep for the pattern, which is the reason `content-gate.sh:29-35` gates on file extension in the first place and which a command-text path has no equivalent for.

### P2-6: `parallel-session-check.sh` treats any live PID as a Claude session

`hooks/parallel-session-check.sh:42-51` tests liveness and nothing else:

```
42	if [ -f "$REGISTRY" ]; then
43	  while IFS= read -r recorded_pid || [ -n "$recorded_pid" ]; do
44	    [ -z "$recorded_pid" ] && continue
45	    [ "$recorded_pid" = "$MY_PID" ] && continue
46	    kill -0 "$recorded_pid" 2>/dev/null || continue
```

The registry records a bare PID with no start time and no process identity, and `$LOCK_DIR` defaults to `$HOME/.claude/.session-locks` (line 17), which persists across reboots. Reproduced by registering the running Finder PID against a fresh tree:

```
$ registering a non-Claude live PID (610, /System/Library/CoreServices/Finder.app/.../Finder)
R-501: 1 other live Claude session(s) are already working in /private/var/folders/.../tmp.t0L1H9maKQ. Two sessions on one working tree overwrite each other silently. Move this session to a git worktree...
```

The practical failure is PID reuse. A registration written before a reboot survives it; macOS recycles PIDs from a low base, so a stale entry has a real chance of matching an unrelated live process, at which point every subsequent session in that working tree opens with a false R-501 warning and an instruction to move to a worktree. A false advisory that cannot be cleared without knowing where the lock files live is worse than no advisory, because it trains the reader to ignore the category.

The fixture at `enforce/tests/parallel-session-check.test.sh:20-23` uses `sleep 30 &` as the live sibling, which is itself a non-Claude process, so the test asserts the current behavior rather than catching it.

Governing rule: R-501 (`hook:parallel-session-check`).

Direction: record enough to make the registration falsifiable, and validate it on read. A process start time alongside the PID, or the `ps -o comm=` name the hook already knows how to read at line 31, would let a recycled PID be pruned rather than reported. To confirm: whether `ps -o lstart=` is stable enough across the macOS versions in use to compare as a string (an epoch-second field via `ps -o lstart=` parsing is fragile; `ps -o etime=` is relative and unusable for this), and whether the registry should simply be keyed under a per-boot directory so the reboot case is handled structurally rather than by comparison.

Related and lower severity, noted here rather than as its own finding: the hook is registered only on `SessionStart`, so the first session in a tree never learns that a second one joined. R-501's norm ("Check for a parallel session on the same working tree before the first edit") is satisfied for the joining session only. `enforce/manifest.json` and `reference.md:370` both describe it accurately as a SessionStart advisory, so this is a documented scope choice rather than drift. Also worth verifying separately: `$HOME/.claude/.session-locks/` does not exist on disk at audit time, which means the hook has not yet run in a live session since registration.

### P2-7: R-302 silently no-ops when the repository is reached through a symlinked path

`hooks/content-gate.sh:83-87`:

```
83	    TOP=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
84	    RELATIVE_DIR="${FILE#"$TOP"/}"
85	    RELATIVE_DIR=$(dirname "$RELATIVE_DIR")
86	    depth=0
87	    [ "$RELATIVE_DIR" != "." ] && depth=$(printf '%s' "$RELATIVE_DIR" | awk -F/ '{print NF}')
```

`git rev-parse --show-toplevel` returns the physical path. When `$FILE` arrives through a symlinked ancestor the prefix strip on line 84 is a no-op, `RELATIVE_DIR` stays absolute, `depth` becomes the absolute component count, and no `../` chain can ever exceed it. Reproduced with a repository at `real/` reached through a `link` symlink:

```
$ physical path:  .../real/src/services/a.ts  importing "../../../../other/src/x"  -> DENY
$ symlinked path: .../link/src/services/a.ts  importing "../../../../other/src/x"  -> allowed
```

Same file, same import, opposite decision. This matters on macOS, where `/tmp` and `/var` are symlinks and synced or aliased project roots are common.

The fixture is constructed to avoid the bug rather than to expose it. `enforce/tests/content-gate.test.sh:38` reads `REPO_FIXTURE=$(cd "$(mktemp -d)" && pwd -P)`; the `pwd -P` normalizes away exactly the condition that breaks the check.

Governing rule: R-302 (`hook:content-gate`).

Direction: normalize both sides before comparing, so the incoming `$FILE` is resolved to a physical path the same way `--show-toplevel` already is. To confirm: whether resolving the path is safe for a file that does not exist yet (the common case for a Write, and the reason line 82 walks up to the first existing ancestor), which likely means resolving the existing ancestor directory and re-appending the remainder rather than calling a resolver on the full path.

### P2-8: a quote character in a staged path kills `git-workflow-guard.sh` and both advisories

`hooks/git-workflow-guard.sh:94` pipes the staged file list into `xargs` under `set -euo pipefail` with no `|| true`:

```
93	  FILE_COUNT=$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')
94	  DIR_COUNT=$(printf '%s\n' "$CHANGED" | xargs -n1 dirname 2>/dev/null | sort -u | wc -l | tr -d ' ')
```

`xargs` applies shell-style quote parsing to its input, so a path containing an apostrophe raises "unterminated quote" and exits non-zero. `pipefail` propagates that through `sort` and `wc`, the command substitution fails, and `set -e` terminates the hook mid-check. Reproduced with five staged files across three directories, one named `src/services/user's.ts`:

```
$ (with the apostrophe path staged)   exit=1, no stderr, no advisory
$ (same commit, path removed)         exit=0, R-508 advisory emitted correctly
```

The `2>/dev/null` on line 94 suppresses the diagnostic, so the failure is completely silent: no R-511 advisory, no R-508 advisory, and a non-zero hook exit that Claude Code surfaces as a hook error rather than a rule fire.

This is the recurrence of the 2026-07-31 audit's P3-2 (unquoted `xargs` file lists in the push gates), now in a new hook and with a worse consequence. The original instances at `push-eslint-gate.sh:36`, `push-ruff-gate.sh:59`, and `push-rubocop-gate.sh:62` all carry `|| true` and therefore degrade rather than abort. `single-file-folder-gate.sh:37` (`DIRS=$(printf '%s\n' "$FILES" | xargs -n1 dirname | sort -u)`) has neither `|| true` nor `2>/dev/null` and shares the new hook's abort behavior.

Governing rule: none numbered; shell-correctness under `set -euo pipefail`, which the dispatch named explicitly.

Direction: derive the directory list without `xargs`. A `while IFS= read -r` loop calling `dirname`, or a parameter expansion per line, removes both the quote parsing and the process spawn. To confirm: whether `single-file-folder-gate.sh:37` should be fixed in the same change (it is a pre-existing instance of the identical pattern with the identical consequence) or tracked separately, and whether any repository the gates run against actually contains a quote-bearing path today, which decides whether this is urgent or merely correct.

### P2-9: R-401 denies Playwright's conditional `test.skip` and pytest's runtime `pytest.skip`

`hooks/content-gate.sh:52-57`:

```
52	  SKIPS=$(printf '%s' "$ADDED" | grep -E '\b(it|test|describe|context|suite)\.(skip|fixme)\(|\b(xit|xtest|xdescribe)\(|@pytest\.mark\.skip\b|\bpytest\.skip\(|\bt\.Skipf?\(|,[[:space:]]*skip:[[:space:]]*true' || true)
53	  if [ -n "$SKIPS" ]; then
54	    UNTRACKED=$(printf '%s' "$SKIPS" | grep -vE '[A-Z][A-Z0-9]+-[0-9]+' || true)
55	    if [ -n "$UNTRACKED" ]; then
56	      deny "This write adds a skipped test with no triage ID (R-401). ..."
```

The pattern cannot distinguish a suppression from a runtime capability guard. Reproduced:

```
$ /x/src/__tests__/a.test.ts  'test.skip(browserName === "firefox", "chromium only");'  -> DENY
$ /x/tests/test_a.py          'def test_x():\n    pytest.skip("no GPU")'                -> DENY
$ /x/tests/test_a.py          '@pytest.mark.skipif(sys.platform == "win32", ...)'       -> allowed (control)
```

Playwright's two-argument `test.skip(condition, description)` is the documented API for "this test does not apply on this browser", and an in-body `pytest.skip()` is the documented API for "the resource this test needs is absent". Neither is a deferral, so neither has a triage ID to name, and the carve-out at line 54 cannot be satisfied. The rule's own carve-out (anti-pattern 8) is about parked work; these are conditional applicability. The `@pytest.mark.skipif` decorator form is correctly allowed, which shows the distinction is already understood in the design and just does not extend to the two forms above.

Governing rule: R-401 (`hook:content-gate`), whose Enforcement line at `reference.md:333` claims "a skip is denied unless its line names a triage ID".

Direction: treat a skip that takes a condition expression as its first argument as a conditional guard rather than a suppression, the same way `skipif` is already treated. To confirm: how to distinguish Playwright's `test.skip(condition, reason)` from a bare `test.skip("name", fn)` in a regex (the first argument being a non-string expression is the signal, and a two-argument form where the first is a quoted string is the suppression); and whether an in-body `pytest.skip()` should be exempt unconditionally or only when it appears after a conditional, which needs a real Python test corpus to decide rather than a guess.

### P2-10: unpaired fix commit in the audited window

`21ea7ab` (2026-07-31, `fix(settings): close the interpreter allow-list escape and gate the cheatsheet auto-exec`) changed product code with no test file in the same commit:

```
$ git show --stat 21ea7ab
 hooks/build-cheatsheets.sh | 25 +++++++++++++++++++++++++
 settings.json              | 13 +++----------
 2 files changed, 28 insertions(+), 10 deletions(-)
```

This is the only unpaired fix in the 30-day window (2026-07-22 to 2026-08-21). The other five `fix:` commits in that window (`b16bcee`, `1beaa83`, `0873bbf`, `6beab94`, `354c8b4`, `2c0868b`, `5f8f1ae`) all changed a test file alongside source. One instance is a P2 pattern note under the Bug Fix Discipline threshold; three or more would be P1.

The underlying reason is worth more than the commit: `settings.json`'s `permissions.allow`, `deny`, and `ask` lists have no fixture harness anywhere in `enforce/tests/`, so a fix to a permission pattern is untestable by construction. The new `hooks/build-cheatsheets.sh` created in the same commit likewise has no fixture, and it is registered on the `PreToolUse:Bash` chain.

Governing rule: R-403 (`hook:fix-commit-requires-test`), R-516 (a rule with no fixture depends on recall).

Direction: none retroactively. The forward-looking gap is a fixture for the permission lists, testing that a representative escape (the interpreter allow-list case this commit closed) is matched by the deny or ask pattern that is supposed to catch it. To confirm: whether `permissions` pattern semantics can be evaluated outside the Claude Code runtime at all (if the matching is not reproducible in a shell fixture, the honest outcome is a documented manual tier rather than a fake test), and whether `build-cheatsheets.sh` warrants its own fixture given it is a trusted-repo-gated advisory that discards its own output.

## P3

### P3-1: R-405 denies a code comment that quotes the pattern it bans

`hooks/content-gate.sh:66` matches the added text with no comment awareness:

```
66	  WEAKENING=$(printf '%s' "$ADDED" | grep -oE "rejectUnauthorized[[:space:]]*:[[:space:]]*false|...")
```

Reproduced: writing `// never write rejectUnauthorized: false here` into `/x/src/clients/p.ts` is denied. A developer cannot document the prohibition in the code where it matters. The blast radius is small because `.md` and `.sh` are outside the extension gate at lines 32-35, so the rule files and the hooks' own headers are unaffected. Direction: strip line comments from `$ADDED` before matching, or accept the false positive as the cost of a one-line check. To confirm: whether comment stripping across six languages is worth the complexity for a case whose workaround (rephrase the comment) is trivial.

### P3-2: R-405 misses four ordinary spellings of the same weakening

All reproduced as allowed against `/x/src/...` non-test paths:

```
'rejectUnauthorized:\n    false'                 -> allowed  (value on the next line)
'rejectUnauthorized: isDev ? false : true'       -> allowed  (ternary)
'bcrypt.hash(password, 4 )'                      -> allowed  (space before the paren; regex requires [0-9]\))
'const SALT_ROUNDS = 4'  (at end of content)     -> allowed  (regex requires a trailing [^0-9])
```

The last two come from `content-gate.sh:70`, whose `[0-9][^0-9]` tail cannot match a digit at end of input. Direction: allow optional whitespace before the closing paren and make the trailing non-digit boundary optional at end of input; the multi-line and ternary cases are a genuine limit of line-oriented matching and are better left documented than chased. To confirm: whether making the bcrypt digit boundary `([^0-9]|$)` introduces false positives on longer numeric literals.

### P3-3: R-401 misses `it.todo` and vitest's `skipIf`

Reproduced as allowed in a test file: `it.todo("signs in");` and `describe.skipIf(true)("x", ...)`. Both are tests that cannot fail. `skipIf` with a literal `true` is a suppression in the same sense `.skip` is. Direction: add `skipIf`/`runIf` with a literal-boolean argument, and decide explicitly whether `todo` is in scope (it is arguably a tracked deferral by its own semantics). To confirm: whether the project's test runners are vitest, jest, or both, since `skipIf` is vitest-only.

### P3-4: R-305's deny message prescribes an impossible path for a barrel file

Reproduced: writing `components/index.tsx` produces `Each component owns a folder: components/index/index.tsx alongside index.module.scss`. The deny itself is correct (`CLAUDE-FRONTEND.md:65` bans barrel files outright, so `components/index.tsx` should not be written), but the remediation text is nonsense and would send a reader to create `components/index/`. Direction: special-case `index.tsx` in the message to cite the barrel ban instead of the folder pairing. To confirm: whether any framework requires an `index.tsx` inside `components/` (Next.js route files live under `app/`, so probably not, but confirm against `CLAUDE-FRONTEND-NEXT.md`).

### P3-5: the commit advisories over-count when the command contains `git add`

`hooks/git-workflow-guard.sh:80-86` unions the entire working tree, not the paths the `git add` names:

```
80	if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+add[[:space:]]'; then
81	  WORKING=$(git -C "$TOP" status --porcelain 2>/dev/null || true)
82	  CHANGED="$CHANGED
83	$(printf '%s\n' "$WORKING" | awk 'NF {print $NF}')"
```

`git add src/routes/foo.ts && git commit` in a repo with unrelated dirty files counts them all toward R-511's 5-files-across-3-directories threshold and toward R-508's surface detection. Both are stderr advisories that never block, so the cost is noise. The header comment at lines 74-76 states the union as deliberate ("a chained `git add X && git commit` runs this hook before anything reaches the index"), so this is an accepted approximation rather than an oversight; it is recorded because the approximation is loose enough to produce advisories on commits that do not warrant them. Direction: parse the `git add` arguments and intersect rather than union, or leave as is and accept the noise. To confirm: how often a chained add-and-commit actually coincides with an otherwise dirty tree in practice.

### P3-6: `find_package_file`'s six-level cap silently disables R-304 and R-305 in deep trees

`hooks/structure-gate.sh:123-132` walks at most six directories up looking for a `package.json`. A component at `src/features/jobs/detail/panels/components/X.tsx` exhausts the budget before reaching the package root, `PACKAGE_FILE` stays empty, and both new checks skip with no signal. The degradation is graceful and the fixture's own comment (`allow '{"...file_path":"/x/src/components/Card.tsx"}'  # no package.json, no deny`) documents the fail-open, so this is a note rather than a defect. Direction: walk until the filesystem root or until a `.git` directory is found rather than counting levels. To confirm: whether an unbounded walk risks reading a `package.json` from outside the project (the reason for the cap), which a `.git` boundary would solve.

### P3-7: `hook-latency.test.sh`'s modelled Bash chain has drifted again

`enforce/tests/hook-latency.test.sh:17` models 16 hooks; `settings.json` registers 18 on the `Bash` matcher. Diffed:

```
registered but NOT modelled:
  build-cheatsheets.sh
  destructive-command-guard.sh
```

Measured cost on the control payload is 14ms and 33ms respectively, both early-exiting, so there is no live latency problem. The finding is that the guard's stated invariant (modelling the real per-event chain) has drifted for the second consecutive audit; the 2026-07-31 P2-1 reported the same class for `push-ruff-gate.sh`, which was fixed by adding that one name rather than by removing the possibility of drift. The `PreToolUse:Write` list is currently accurate (5 modelled, 5 registered). Direction: derive `BASH_HOOKS` from `settings.json` at test time instead of maintaining a literal. To confirm: whether reading `settings.json` inside the latency test makes the test's own cost or its failure modes worse, and whether any registered hook must be excluded from timing for a legitimate reason (which would need an explicit exclusion list, itself a drift surface).

### P3-8: `git-workflow-guard.test.sh:39` asserts the weaker half of its claim

```
39	[ "$(decision 'git push origin feature/scoring' "$REPO")" = "ask" ] && exit 1  # a feature branch is not gated
```

The assertion is "not ask", so a regression that turned a feature-branch push into a `deny` would pass. Every other decision assertion in the file uses positive equality (`= "deny"`, `= "ask"`, `= "none"`), and `= "none"` is available here. Direction: invert to a positive assertion. To confirm: nothing; this is a one-token change, but it belongs to whoever touches the file next rather than to a standalone commit.

### P3-9: prior-audit P3-1 remains open

The 2026-07-31 audit's P3-1 (R-314's TypeScript-only nested-`__tests__` deny applied to Python test filenames) is unresolved. `hooks/structure-gate.sh:109-114` still routes a `test_*.py` under `*/src/*/__tests__/*` to the R-314 message with no `is_python` guard. Not re-litigated here; recorded so it does not disappear from the register. The prior P1-1 (Python `in_src` gate) and P1-2 (`ruff:` prefix blindness) are both genuinely closed, and P1-2's fix was generalized past the reported gap to `rubocop:` and `golangci:` as well.

## Architecture and design

The hook tree has a coherent shape and the four new files respect it: one hook per rule family, one matcher per hook, `set -euo pipefail` and a `deny`/`ask` helper that logs through `log-rule-fire.sh` with a `2>/dev/null || true` fallback so a missing logger cannot take down a gate. Every new hook fails open on missing tooling (`git`, `ps`, `shasum` all guarded), which is the right default for a gate that runs on every tool call.

Two structural observations, neither rising to a finding:

The `Write|Edit` matcher now carries five hooks and the `Bash` matcher carries eighteen. Each is a separate process spawn per tool call. `hook-latency.test.sh` guards the aggregate against a same-environment control, which is the right instrument, but the growth direction is one way. `content-gate.sh` and `structure-gate.sh` are already companions by design ("Companion to structure-gate.sh, which checks the path", `content-gate.sh:3`) and share the same `jq` extraction preamble; if the Write chain grows again, merging them is the obvious consolidation and the header comments have already anticipated it.

The `enforce/manifest.json` to `settings.json` to `reference.md` closure is genuinely bidirectional and was verified live: deregistering `git-workflow-guard.sh` from a settings copy produced the correct warning. That closure is the single most valuable piece of infrastructure in this repository and it held through the addition of four hooks and eleven rules.

## Code quality

Consistent to a fault across the new files: same shebang, same option set, same input extraction, same helper shapes, same header comment structure explaining intent and carve-outs. Naming follows the repository's own conventions. No dead code, no duplication beyond the deliberately repeated `deny`/`ask` helpers (which are duplicated rather than sourced so that a broken shared file cannot silently disable every gate, a reasonable trade).

The complexity hotspot is `hooks/structure-gate.sh`, now 173 lines carrying six rules across four language tracks, with a segment-walking loop whose `in_src`/`in_app`/`is_python`/`is_ruby`/`is_go` state interacts in ways that already produced one P1 in the previous audit cycle. The two new checks at lines 154-172 are appended after the loop and are independent of it, which is the right way to have added them. If a seventh rule arrives, splitting the path-vocabulary walk from the package-scoped checks is the natural seam.

## Security

The new surface is enforcement code, not application code, so the relevant security questions are about the gates themselves.

Input handling: all four new hooks read untrusted JSON through `jq -r` with `// ""` defaults and never `eval` or re-expand the extracted values into a shell context. `mcp-action-guard.sh:25` uses an unquoted command substitution for word splitting, which is deliberate and safe here because the split values are alphanumeric tool-name fragments, but it does leave pathname expansion enabled on those tokens; no reachable tool name contains a glob character, so this is noted rather than flagged.

Fail-open posture: every hook exits 0 on missing tooling or unparseable input. For advisories this is correct. For the deny-tier rules (R-302, R-304, R-305, R-401, R-405) it means a missing `jq` disables the gate silently, which is a pre-existing property of the whole tree rather than something these commits introduced.

Prompt injection: not applicable to the new surface. None of the four hooks passes tool output into a model context; `llm-rule-judge.sh` is the only hook that does and it is outside this window.

The three security-relevant coverage gaps are P1-2 (MCP database path), P2-5 (Bash delivery bypasses the content gate, which includes the R-405 protection-weakening check), and P2-3 (`git -C` bypasses the push gate). All are reported above.

## Credential exposure scan

Run in full across the allowed targets. Result: no live credential found. Details, paths and counts only:

| Target | Result |
|---|---|
| Working tree, tracked and untracked, `.env*` excluded | 2 files match: `hooks/secret-scan.sh` (the pattern definitions themselves) and `enforce/tests/credential-mutation-guard.test.sh` (a fixture). Both expected. |
| Git history, all refs (`git log --all -p`) | 4 matching lines, all triaged as placeholders or pattern definitions: an all-`A` `sk-ant-api03-` example in a hook header comment, a `FAKE_KEY=` fixture assignment, and two `railway variables --set KEY=` fixture lines from `destructive-command-guard` tests. No real value. |
| Session transcripts, this project (`~/.claude/projects/-Users-iangreenough--claude/*.jsonl`) | 6 transcripts, 0 matches. |
| Session transcripts, all projects | 5 files matched and all 5 triaged as false positives. Three `re_[A-Za-z0-9_-]{30,}` hits are the tail of Python module paths (`..._memory_store_...`, `/tmp/pre_...`), 42 and 36 characters with 5 and 2 underscores and no adjacent key-word context. Two `ASIA[0-9A-Z]{16}` hits are 20-character all-uppercase runs embedded in lowercase base64-style blobs with zero digits and no AWS context; a real `ASIA` session key of that shape is improbable and no AWS token appears nearby. Triage used character-composition metadata only; no matched value was read into this report or into the session. |
| Shell history (`~/.zsh_history`, `~/.bash_history`) | 0 matches each. No fish history present. |
| Vendor CLI configs | Present: `~/.railway/config.json` (16696 bytes), `~/.config/gh/hosts.yml` (100 bytes), `~/.aws/credentials` (116 bytes). Not present: `~/.vercel/auth.json`, `~/.stripe/config.toml`, `~/.netrc`. **Not read**, per R-102 and R-805, which are the more specific rules and take precedence over the audit rubric's scan instruction. Listed by path and size only. |
| Editor and tool caches | Not scanned; no direct match surfaced during the broader filesystem sweep. |

Two things to record rather than to act on:

The audit rubric's `re_[A-Za-z0-9_-]{30,}` (Resend) and `ASIA[0-9A-Z]{16}` (AWS session) patterns are the two that produced every false positive here. `re_` is a three-character prefix that occurs inside ordinary identifiers, and `ASIA` occurs inside any sufficiently long uppercase run. A future scan should expect these two to be noisy and should triage them on composition before escalating, exactly as this one did.

`~/.aws/credentials` exists on this machine. R-102 keeps it off-path and no hook reads it, but its presence means an AWS credential is available to any process on this machine, which is context worth carrying into the next security audit rather than this engineering one.

No rotation is required and none was performed. The `PreToolUse` secret-scan hook required by the rubric's remediation step is already present and registered (`hooks/secret-scan.sh`, on both the `Bash` and `Write|Edit` matchers).

## Database

Not applicable to this repository; there is no schema, no migration, and no connection management in scope. The one database-adjacent finding is P1-2, where the R-101 enforcer cannot see the MCP path to a managed Postgres.

## API design

Not applicable in the HTTP sense. The equivalent surface is the hook contract, and it is consistent: every hook reads a JSON object on stdin, writes either nothing or one `hookSpecificOutput` object on stdout, and exits 0. The two event shapes in use (`PreToolUse` with `permissionDecision`, `SessionStart` with `additionalContext`) are used correctly by the new hooks and match the shapes the existing hooks use. Advisories go to stderr and never to stdout, which keeps them out of the decision channel. One deviation from the contract was found and is reported as P2-8: `git-workflow-guard.sh` can exit 1.

## Performance

Measured, not estimated. `hook-latency.test.sh` passes both chains against its normalized budget. Spot measurements on the control payload: `build-cheatsheets.sh` 14ms, `destructive-command-guard.sh` 33ms, `secret-scan.sh` 28ms, all dominated by process spawn rather than work. Every new hook early-exits on the wrong tool name or the wrong command shape before doing anything expensive.

Client-side request frequency: not applicable. This repository ships no client and no polling primitive; `grep` for `refetchInterval`, `setInterval`, and `useInterval` across the tree returns nothing outside documentation prose.

The one growth risk is structural rather than measured: the `PreToolUse:Bash` chain is now 18 process spawns per Bash tool call, and P2-5's proposed fix would make it 19. That is the trade to weigh explicitly when deciding P2-5.

## Testing

Both suites are green and both are wired to a real trigger (`.git/hooks/pre-push`). The four new fixture files are honest tests, not vacuous ones: each `deny`/`ask` assertion would fail if its hook were deleted, and `content-gate.test.sh`, `git-workflow-guard.test.sh`, and `parallel-session-check.test.sh` all build real git repositories and real process state rather than asserting against synthetic strings. `parallel-session-check.test.sh:26` in particular looked vacuous on first read (its comment claims more than the line does) but was verified to genuinely catch a key-derivation collapse, so it is not reported.

The pattern that does need naming is not vacuous assertions but **fixtures constructed to avoid the failure mode**, which is a subtler version of the same problem. Three instances, each reported above with its finding:

- `content-gate.test.sh:38` normalizes the repository path with `pwd -P`, which is exactly what makes the symlink case in P2-7 invisible.
- `structure-gate.test.sh`'s client fixture declares `react` only, which is what makes the `express`-devDependency case in P2-1 invisible.
- `parallel-session-check.test.sh:20` uses `sleep 30 &` as the live sibling, a non-Claude process, which asserts the P2-6 behavior instead of catching it.

In all three the fixture author picked the clean shape. That is the natural thing to do when writing a test to confirm a hook works, and it is why a fixture suite being green says less about coverage than it appears to.

Coverage gaps beyond those: no fixture anywhere covers `settings.json`'s permission lists (see P2-10), and `hooks/build-cheatsheets.sh` has no fixture despite being registered on the Bash chain.

## Dependencies and supply chain

No package manifest, no lockfile, no third-party code in scope. The runtime dependency surface is the set of binaries the hooks shell out to: `jq`, `git`, `awk`, `sed`, `grep`, `shasum`, `ps`, `xargs`, `python3` (test-only). All are system-provided. `jq` is the single point of failure: every new hook calls it unguarded in its input-extraction preamble, so a missing or broken `jq` disables all five gates silently. Pre-existing property of the whole tree, noted for the record.

Integrity: `enforce/hook-hashes.txt` covers all 5 files in scope, `hook-integrity-check.sh` runs at SessionStart and exits 0 clean at audit time, and all three feature commits updated the manifest hash in the same commit as the code. `core.hooksPath` is unset (R-107 clean).

## Deployment and infrastructure

The deploy surface is `settings.json` registration plus the file on disk with its execute bit. All four new hooks are `-rwxr-xr-x`. All are registered. The R-516 guard verifies the manifest-to-settings mapping bidirectionally at every session start and was confirmed working against a deliberately broken settings copy.

The gap is that there is no CI. The only automated gate is the untracked `.git/hooks/pre-push`, which exists on this machine and nowhere else. A clone of `claude-global-rules.git` has no gate, which is not theoretical: see Workspace Hygiene.

## Bug fix discipline

Scanned the last 60 commits (2026-07-04 to 2026-08-21), which exceeds the 30-day window. Twelve `fix:`-prefixed commits, two unpaired:

| SHA | Date | Subject | Evidence |
|---|---|---|---|
| `21ea7ab` | 2026-07-31 | `fix(settings): close the interpreter allow-list escape and gate the cheatsheet auto-exec` | changed `hooks/build-cheatsheets.sh` and `settings.json`, no test file |
| `728043c` | 2026-07-07 | `fix(enforce): mirror trivago Prettier group boundaries in import/order pathGroups` | changed `enforce/eslint.config.mjs` only, no test file |

`728043c` is the commit reported as P2-2 in the 2026-07-31 audit (as `266d05e`, before the history rewrite recorded in `2e0f519`); it is outside the 30-day window and is not re-litigated. Within the window there is exactly one unpaired fix, `21ea7ab`, reported as P2-10 above. The remaining ten fix commits all paired source and test changes. One unpaired fix in a 30-day window is a P2 pattern note, not the P1 behavioral finding that three or more would be.

## Runbook-vs-code drift scan

No `docs/runbooks/` directory exists in this repository. The equivalent surface is the rule text, which is what the code claims to enforce, and it was compared line by line against the code for all eleven rules in scope.

One drift finding, and it is the reason P1-1 is P1 rather than P2:

- `rulebook/reference.md:427` states `hook:git-workflow-guard` "asks before `gh pr merge` and before any push whose target branch **resolves to** `main`/`master`". The code performs literal pattern matching on the refspec text and resolves nothing (`git-workflow-guard.sh:66-69`). `git push origin HEAD` on a `main` checkout is a push whose target branch resolves to `main` and it does not ask. Direction of the contradiction: the code is behind the doc. Severity P1, because a reader who trusts the Enforcement line stops applying R-514 from recall, which is precisely the trade a mechanized rule makes.

Everything else checked clean and is worth saying so explicitly, because the accuracy here is unusual:

- `reference.md:415` (R-512) scopes its claim to `--merge` and `--rebase` exactly, matching the code, and does not overclaim about short flags or local merges.
- `reference.md:350` (R-405) enumerates precisely the eight patterns the code matches and explicitly names what stays manual ("rate-limit ceilings and cookie flags"), even though `CLAUDE.md:74`'s R-405 norm line mentions "rate limits". The specific Enforcement line governs and is accurate.
- `reference.md:333` (R-401) states "anti-patterns 8 and 9 only" and names the rest as judge-tier, matching the code.
- `reference.md:137` and `:145` (R-304, R-305) both name the package.json dependency scoping explicitly, matching the code (the P2-1 false positive is a defect in that scoping, not a misdescription of it).
- `reference.md:370` (R-501) correctly describes a SessionStart advisory that warns and never blocks.
- `reference.md:401` and `:412` (R-508, R-511) both state the exact thresholds and the `~/.claude` exemption, matching the code.
- `enforce/manifest.json`'s eleven new entries carry accurate `tier` and `severity` values and notes that match the implementations.
- `CLAUDE.md` norm lines for all eleven rules carry the correct `[hook:...]` enforcer tag.

## Workspace hygiene

One duplicate of this repository exists:

```
~/Desktop/code/personal/production/claude-config-snapshot
  origin: https://github.com/nullvoidundefined/claude-global-rules.git   (same remote as ~/.claude)
  HEAD:   b16bcee  (four commits behind; missing all three audited feature commits)
  carries: full enforce/ and hooks/ trees, agents/, backups/, cache/
  also present: an untracked .env (280 bytes) and a .DS_Store (14340 bytes)
```

This is a second working tree for the same remote, four commits stale, containing a complete copy of the enforcement tree. Three specific risks:

1. It has no `.git/hooks/pre-push`, so a push from it would run neither fixture suite.
2. Its `hooks/` copy is what a stale `core.hooksPath` or a mistaken absolute path would resolve to, and its content predates the four audited commits.
3. It contains a `.env`. Verified as gitignored (`​.gitignore:27`) and never committed (`git log --all -- '.env' '.env.*'` across the shared history is empty), so this is not a leak today. It is one `git add -f` away from being one, on a repository whose remote R-106 treats as publishing.

The `.env` was **not read**, per R-102 and R-805. Its contents were not scanned for credential patterns. If a scan is wanted, the user should run it in their own terminal.

Also present under the personal-code roots and worth including in a cleanup plan, though none is a copy of this repo: project-level `.claude/` directories at `Desktop/code/personal/`, `personal/development/`, `personal/production/`, `personal/templates/`, `code/work/bond/`, and three under `Desktop/pre-trash/`.

No deletions recommended. The recommendation is that the user produce a cleanup plan deciding whether `claude-config-snapshot` is a deliberate backup (in which case it should be read-only and dated, not a live clone of the same remote) or an abandoned copy.

## Tech debt register

| Item | Risk | Notes |
|---|---|---|
| No CI; one untracked pre-push hook is the entire gate | H | A clone has no protection at all. Already realized in the duplicate found above. |
| `settings.json` permission lists have no fixture harness | M | Produced the one unpaired fix in the window (P2-10). May not be testable outside the runtime. |
| `jq` is an unguarded single point of failure across all gates | M | Missing `jq` silently disables every deny-tier rule. Pre-existing. |
| `structure-gate.sh` at 173 lines, 6 rules, 4 language tracks | M | Already produced one P1 in the prior cycle. Has a clean seam if a seventh rule arrives. |
| 18 hooks on the `PreToolUse:Bash` chain, growing | M | Guarded by a normalized latency budget, but the direction is one way. |
| Bash-delivered file writes bypass all Write-matcher gates | M | P2-5. Systemic across `content-gate`, `structure-gate`, `migration-defaults-guard`. |
| Fixtures constructed to avoid the failure mode | M | Three instances found this cycle (P2-1, P2-6, P2-7). A green suite overstates coverage. |
| Unquoted `xargs` file lists | L | P2-8 plus four pre-existing instances; the two without `|| true` abort their hooks. |
| Prior P3-1 (R-314 message on Python paths) unresolved | L | Carried from 2026-07-31. |
| `claude-config-snapshot` duplicate clone with an untracked `.env` | L | Not a leak today. Needs a decision, not a deletion. |

## Prioritized recommendations

| # | Finding | Impact | Effort |
|---|---|---|---|
| 1 | P1-2: gate the MCP database path; extend `mcp-action-guard`'s verb list and give SQL-bearing MCP tools an argument check | H | M |
| 2 | P1-1: resolve the push refspec to a branch before matching, so `HEAD`, `refs/heads/main`, and `+main` ask | H | S |
| 3 | P1-3: split camelCase tool names on the case boundary; add `use_figma` | H | S |
| 4 | P2-1: fix the R-304 scoping so an `express` devDependency in a React package does not trigger the server vocabulary | H | S |
| 5 | P2-3: allow global git options between `git` and the subcommand in the trigger and argument parsing | M | S |
| 6 | P2-2: exempt R-305 component folders in `single-file-folder-gate.sh` | M | S |
| 7 | P2-8: replace `xargs -n1 dirname` with a read loop in `git-workflow-guard.sh:94` and `single-file-folder-gate.sh:37` | M | S |
| 8 | P2-9: distinguish conditional skips from suppressions in the R-401 check | M | M |
| 9 | P2-7: normalize `$FILE` to a physical path before the R-302 depth comparison | M | S |
| 10 | P2-6: record process identity or start time alongside the PID in the session registry | M | M |
| 11 | P2-4: match `gh pr merge` short strategy flags | M | S |
| 12 | P2-5: decide explicitly whether the Bash delivery path is in scope for `content-gate` | M | M |
| 13 | P3-7: derive `hook-latency.test.sh`'s `BASH_HOOKS` from `settings.json` instead of a literal | L | S |
| 14 | Workspace: decide the fate of `claude-config-snapshot` | L | S |

Remaining P3 items for `ISSUES.md`: P3-1 through P3-6, P3-8, P3-9.

## Probed and cleared

Hypotheses tested against the running code that did not reproduce, recorded so they are not re-investigated next cycle:

- **SIGPIPE in `printf | grep -q ... || exit 0`.** Tested `git-workflow-guard.sh` with a 200023-character command whose `git push origin main` appears at position 0. The hook still asked. Isolated the pattern separately under `set -euo pipefail` and the pipeline returned 0. No bypass.
- **`enforce/manifest.json` duplicate rule IDs.** Ten IDs appear more than once (R-101, R-102, R-107, R-203, R-320, R-322, R-324, R-326, R-327, R-329); all are multi-enforcer rules with distinct `enforcer` values, which is the intended shape. None of the eleven new rules is duplicated.
- **`allow`/`pass` helpers swallowing hook exit status.** `content-gate.test.sh:9`, `mcp-action-guard.test.sh:7`, and `structure-gate.test.sh:6` all use `[ -z "$(...)" ]`, which would pass if the hook were deleted. But each file's paired `deny`/`ask` helper uses `jq -e` on the decision and would fail, so no suite is vacuous as a whole.
- **`parallel-session-check.test.sh:26` ("same live PID, different tree").** The comment overstates what the line does, but the assertion genuinely catches a key-derivation collapse: a constant `KEY` would make `TREE_B` see `TREE_A`'s live registration and fail the assertion. Not a finding.
- **`set -e` and `[ -z "$X" ] && exit 0`.** Present in all four new hooks. Verified exempt from `set -e` (the failing test is not the command following the final `&&`), confirmed by both suites passing and by direct execution.
- **`git push` inside a quoted string or an `echo`.** `echo git push origin main` and `echo "git push origin main"` both correctly produce no fire. No false positive.
- **Structure-gate creation-only scoping.** An `Edit` against a pre-existing loose module correctly allows; an `Edit` against a path that does not exist correctly denies (the tool would fail anyway). Behaves as documented.
- **R-401 triage-ID carve-out.** `it.skip(...) // JOB-412 pending` allows, `it.skip(...) // flaky, revisit later` denies, `@pytest.mark.skipif(sys.platform == "win32", ...)` allows. Working as designed.
- **R-405 test-tree exemption.** `rejectUnauthorized: false` in `src/__tests__/...` allows, the same content in `src/clients/...` denies. Working as designed.
- **`mcp-action-guard` false positives on read-only names.** `list_issue_labels`, `untrash_message`, `notion-fetch`, `download_file_content` all correctly stay silent. The per-token match is doing its job on snake_case.
- **`git-workflow-guard` global-repo exemption.** `git push` with `cwd=~/.claude` correctly produces no ask; the realpath comparison at lines 52-55 handles the symlink case that broke R-302.
- **R-516 bidirectional closure over the new tier.** Deregistering `git-workflow-guard.sh` from a settings copy produced the correct warning naming the hook.
- **Hook hash integrity and execute bits.** All five in-scope files match `hook-hashes.txt`; all are `-rwxr-xr-x`.
- **Prior-audit P1-1 and P1-2.** Both genuinely closed; P1-2's fix was generalized to `rubocop:` and `golangci:` beyond what was reported.
