# Slice 05: a parsed guard for destructive operations

**Ticket:** IAN-606
**Merge mode:** owner merges (Gate 2). Every PR in this slice touches a security control, so R-514 hands each one to the owner under either mode.
**Risk:** high. This slice is a security control (R-110). Each PR runs the TDD lock with the test-author, implementer, and slice-critic roles, gets the R-517 pre-merge review, and gets the R-109 security review on `securityReviewModel`.
**Fuzzy controls:** the owner answered the four controls below on 2026-10-03.

## Incident and root cause

A subagent ran an unscoped `docker rm -f` on the owner's Mac and deleted every container. An audit on 2026-10-03 found four causes:

- The harness runs with `defaultMode: auto`, so any command that no rule or hook matches is decided by Claude Code's classifier, not by a person. Nothing in the harness mentioned docker.
- Every destructive-command check except the git-hook checks is either a text regex anchored at command position or a literal-prefix permission glob. Flag reordering defeats them (`rm -fr`, `rm -Rf`, `push origin x --force`), and so do wrappers (`/bin/rm`, `\rm`, `env`, `timeout`, `zsh -c`, `eval`, `xargs`) and quoting (`gh api -X "DELETE"`).
- Broad allow rules (`git *`, `gh *`, `npm *`, `mv *`, `cp *`, `python3 -c *`, `echo *`, `cat *`) let destructive subcommands run without a prompt.
- `hooks/shell-command-segments.py` already sees through `bash|sh|zsh -c`, `eval`, `$(...)`, backticks, heredocs fed to a shell, `xargs`, `env`, `sudo`, `command`, `exec`, `nohup`, `time`, `nice`, `timeout`, and absolute program paths. Only the git-hook checks use it.

## Design

A new PreToolUse(Bash) hook, `claude/hooks/destructive-ops-guard.sh`, reads every simple command that `shell-command-segments.py` produces and checks it against a per-program policy. The hook emits `deny` or `ask`; when several segments match, the strongest decision wins.

A hook's `ask` overrides an allow rule and the auto classifier, so a person approves the command. Under Codex the adapter's default turns `ask` into `deny` (`CLAUDE_CODEX_ASK_POLICY=deny`), which is stricter.

If the parser is missing, fails, times out (10 s), or prints nothing for a non-empty command, or `jq` is missing, the hook denies every Bash call (owner decision 2026-10-03, after the B-1 slice critic showed word matching is bypassed by quoting, case, and `eval` while the parser is down). This happens only on a broken install, and the deny names the fix. The hook is registered in `settings.json` and regenerated into `codex/hooks.json` and the cursor port.

The policy lives in data (`claude/enforce/destructive-ops.json`): for each program, its read-only subcommands, ask verbs, and deny forms. That way a new CLI is a data change. The deciding logic stays in code under test.

## Owner decisions (fuzzy controls)

### 1. rm and other deletion routes: tiered

**Threat model:** an agent writes the command, so it controls every argument, flag spelling, wrapper, and variable. A miss destroys user data outside version control.

**Hard deny** when any target resolves to:

- `/`
- `~` or `$HOME`
- a top-level home directory (`~/Library`, `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Music`, `~/Movies`, and the other dot or plain entries directly under home)
- a path outside the repository, reached through `..` or written as an absolute path
- a glob that expands at home or root level
- an unset or empty `$VAR`

**Ask** on every other recursive or forced delete:

- any flag spelling: `-r`, `-R`, `-f`, `--recursive`, `--force`, combined or apart
- `find -delete` and `find -exec`/`-execdir rm`
- `xargs rm`
- `rsync --delete`
- `git clean -f` in any flag order
- `unlink` and `trash` outside the repository
- interpreter one-liners that delete: `shutil.rmtree`, `os.remove`, `fs.rmSync`, `fs.rm`, `rimraf`, Perl `rmtree`
- `>` or `: >` truncation of a file outside the repository

**Runs:** a plain `rm <file>` inside the repository.

**Acceptance:** each spelling and wrapper the audit listed gets a fixture asserting its decision, and so does a harmless control case (`rm build/x.o`, `rm -rf node_modules` asks, it is not denied).

### 2. Docker, podman, nerdctl, docker compose, docker-compose: read-only allowlist

**Runs:**

- `ps`, `images`, `logs`, `inspect`, `version`, `info`, `stats`, `top`, `port`, `diff`, `history`, `search`
- `events`, `context ls/show/inspect`, `volume|network|image|container ls/inspect`, `system df`
- `compose ps/logs/config/ls/images/top/version`

**Asks:** every other subcommand, including unknown ones, so the allowlist fails closed. This covers `rm`, `rmi`, `prune`, `kill`, `stop`, `down -v`, `run`, `exec` and `build`.

**Threat:** the incident command, and `$(docker ps -aq)` style fan-out.

### 3. Cloud, IaC, cluster, database, disk, and system: ask on destructive verbs

**Ask** on delete, destroy, reset, drop, flush, terminate, uninstall, rollback-all, and their kin, for these tools:

- **IaC:** `terraform destroy`, `apply -auto-approve`, `state rm`; `pulumi destroy`; `cdk destroy`
- **Cloud CLIs:**
  - `aws`: `* delete-*`, `terminate-*`, `s3 rm`, `s3 rb`
  - `gcloud`: `* delete`
  - `gsutil`: `rm`
  - `az`: `* delete`
- **App platforms:**
  - `railway down`, `delete`
  - `fly destroy`, `apps destroy`
  - `vercel rm`
  - `supabase db reset`
  - `firebase *:delete`
  - `heroku *:destroy`
  - `wrangler delete`, `r2 bucket delete`
- **Cluster:** `kubectl delete`, `drain`, `scale --replicas 0`; `helm uninstall`
- **Databases:**
  - `redis-cli FLUSHALL`, `FLUSHDB`
  - `mongosh` `dropDatabase`, `drop`
  - `prisma migrate reset`, `db push --force-reset`
  - `rails db:drop`, `db:reset`
  - `manage.py flush`
  - `alembic downgrade base`
  - `knex migrate:rollback --all`
  - `dropdb`
  - SQL `DROP SCHEMA`
- **System:**
  - `kill -9 -1`, `pkill`, `killall`
  - `launchctl bootout`, `unload`
  - `systemctl stop`, `disable`
  - `crontab -r`
  - `brew uninstall`, `untap`
  - `npm unpublish`, `deprecate`
  - `cargo yank`, `gem yank`
  - `security delete-keychain`, `gpg --delete-*-keys`
  - `ssh-keygen` writing over an existing key
  - `history -c`, `unset HISTFILE`

**Hard deny:** disk wipes and whole-system forms: `dd of=/dev/*`, `diskutil erase*`/`partitionDisk`, `mkfs*`, `kill -1`/`-9 -1`, `shutdown`, `reboot`, `halt`.

**Runs:** reads and normal deploys, as today.

### 4. git and gh: ask on history-losing verbs

**Ask, git:**

- force push in any spelling (`--force`, `-f`, `--force-with-lease` anywhere, a `+ref` refspec, `-C <dir>` and other global options)
- `push --delete` and `:ref`
- `branch -D`
- `reset --hard` in any form
- `clean -f` in any flag order
- `checkout --` and `restore` on paths
- `switch -f`
- `stash drop`/`clear`
- `reflog expire`
- `gc --prune`
- `update-ref -d`
- `tag -d`

**Ask, gh:** `secret`/`variable`/`ssh-key`/`label`/`run`/`cache` delete, `workflow disable`, `pr close --delete-branch`.

**Deny:** a quoted or variable-built `gh api -X "DELETE"` stays a hard deny, matching today's unquoted form.

## PRs

### PR 1: the parsed guard and the rm tier

- **Context:** this is the first PR of slice 05. Today, the parser feeds only the git-hook checks.
- **Problem:** `rm` and every other deletion route escape through flag order, wrappers, and interpreters (decision 1).
- **Approach:**
  - Add `destructive-ops-guard.sh`, which reads the parser's segments and makes one decision per command. The parser is extended only if a fixture shows that a wrapper is missing.
  - Resolve each `rm`-family target against the cwd, `CD_PREFIX`, `HOME`, and the repository root, then classify it as root, home, a top-level home entry, outside the repo, an unset variable, or inside the repo.
  - Implement decision 1, register the hook, and regenerate the ports.
- **Contents:**
  - `claude/hooks/destructive-ops-guard.sh`
  - `claude/enforce/destructive-ops.json` (the rm entries)
  - `claude/hooks/tests/destructive-ops-guard-rm.test.sh`
  - `settings.json`, the regenerated `codex/` and `cursor/` ports, and the integrity manifest
- **Tests:** written by the `test-author` agent under the lock. They cover every audited `rm` spelling against every audited target, every wrapper, the alternative deletion routes, the harmless controls, and parser-failure deny.
- **Review focus:**
  - target resolution, especially globs, `~user`, `$VAR` and `${VAR:-x}`, `--` and paths beginning with `-`
  - fail-closed behavior when the parser fails
- **Size:** about 6 files and 700 lines, plus the generated ports.

### PR 2: Docker family read-only allowlist

- **Context:** PR 1 has merged, so the guard and its policy file exist.
- **Problem:** Docker, podman, nerdctl and compose have no guard at all. This is the incident.
- **Approach:** add a policy entry per program, with a global-option skipper (`-H`, `--context`, `--host`, `-f`, `-p`, `--project-name`, `--log-level`) and the `compose` and `docker-compose` spellings. Read-only subcommands run; everything else asks.
- **Contents:** `destructive-ops.json` entries, the guard's subcommand finder, and `destructive-ops-guard-docker.test.sh`.
- **Tests:**
  - the incident command, `$(docker ps -aq)` fan-out, and `system prune --volumes`
  - `compose down -v`, and `podman rm -af`
  - every read-only subcommand
  - an unknown subcommand (asks)
  - `sudo` and `bash -c` wrappers
- **Review focus:** that the allowlist fails closed on unknown subcommands and options.
- **Size:** about 3 files and 300 lines.

### PR 3: cloud, IaC, cluster, database, disk, and system verbs

- **Context:** PRs 1 and 2 have merged.
- **Problem:** the families in decision 3 have no guard.
- **Approach:** add policy entries for decision 3. Add a verb matcher for `aws * delete-*`-style shapes. Add hard-deny forms for disk wipes and system shutdown. Remove the `localhost` exemption from `destructive-db-guard.sh` for the new DB verbs only. The existing SQL behavior of that file is unchanged.
- **Contents:** `destructive-ops.json` entries, the verb matcher, and `destructive-ops-guard-infra.test.sh`.
- **Tests:** one ask case and one run case per tool, plus every hard-deny form.
- **Review focus:** that ordinary deploys and reads still run (false positives slow the owner down), and that every disk-wipe spelling is denied.
- **Size:** about 3 files and 500 lines.

### PR 4: git and gh history-losing verbs

- **Context:** PRs 1 to 3 have merged.
- **Problem:** the `git *` and `gh *` allow rules let decision 4's verbs run silently, and the quoted `gh api -X "DELETE"` beats the existing deny.
- **Approach:**
  - Add git and gh policy entries using the git-subcommand finder `destructive-command-guard.sh` already has. That finder is moved into a shared helper only if needed, and the move is called out in the PR.
  - Make the `gh api` method check read the parsed, unquoted word.
- **Contents:** `destructive-ops.json` entries, the gh method check, and `destructive-ops-guard-git.test.sh`.
- **Tests:**
  - every audited spelling: `push origin x --force`, `+ref`, `-C . reset --hard`, `clean -xdf`, `branch -D`, `stash clear`
  - quoted and variable-built `gh api` DELETE
  - control cases that must still run: `git push`, `git commit`, `git clean -n`, `gh pr view`
- **Review focus:** that ordinary git use stays silent, and that the force-push spellings are complete.
- **Size:** about 3 files and 400 lines.

## Not in this slice

- **Changing `defaultMode: auto` or the broad allow rules in `settings.json`.** The guard's `ask` overrides both, so they can stay. Narrowing them is a separate owner decision.
- **Sandboxing (`sandbox.enabled`).** This is a stronger, OS-level control. It is worth its own decision once the guard has landed.
