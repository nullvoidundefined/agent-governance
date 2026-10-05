# Harness hardening against destructive "cleanup"

## Goal

Stop the failure mode where an agent with broad permissions removes something
it judges redundant, destroys production data or infrastructure (a production
database copy, SPF/DMARC records), and then reports it verified everything.
Safe work stays low-friction; only destructive or production-touching actions
are gated. Plan approved by the owner 2026-10-04 (six PRs; this spec covers
PR 2 in detail, the rest by reference to the plan).

## Threat model (owner answers, 2026-10-04)

- **Attack to stop:** a Bash command or MCP call that mutates cloud
  infrastructure, DNS or email-auth records, or a production database, issued
  by an agent that believes it is cleaning up.
- **Human-only means deny.** `defaultMode` is `auto`, so an `ask` can be
  resolved without a person. Anything that must be human-only is `deny`, and
  its message gives the command for the human to run.
- **Cloud CLIs (`aws`, `gcloud`, `az`, `doctl`): deny every mutation.** Only
  read verbs pass. Accepted cost: harmless mutations (tagging, a dev bucket)
  are also denied.
- **Unknown remote target: ask.** Only targets marked production are denied.
  Marking is by name (`prod`, `production`, `live`), by `*_ENV=production`,
  or by the repo's `.enforce.json` `environments.production` list. Local
  targets keep today's rules.
- **Severity ceiling:** a bypass that needs the agent to write and execute its
  own program (a script file, an SDK call inside Python) is out of scope for
  hooks and noted, not fixed (the OS sandbox investigation covers it).

## Inputs

PreToolUse Bash events (`tool_input.command`, `cwd`). The repo's
`.enforce.json`, optional key `environments`:

```json
{ "environments": { "production": ["db.prod.internal", "gke_acme_prod"],
                    "preview": ["*.preview.acme.dev"], "testing": ["ci-db"] } }
```

Each entry is a host, kube context, terraform workspace, AWS profile or
deploy environment name; `*` is a wildcard.

## Outputs

A PreToolUse decision (`deny` or `ask` with a reason naming the rule and, for
deny, the command to run by hand), or no output for allow.

## Acceptance criteria (PR 2)

Cloud CLIs:
- B-1: `aws`, `gcloud`, `az`, `doctl` subcommands whose verb is read-only
  (`list*`, `describe*`, `get*`, `show`, `ls`, `help`, `--version`,
  `sts get-caller-identity`, `config list|get`, `auth list`, `account show`)
  are allowed.
- B-2: every other `aws`, `gcloud`, `az`, `doctl` subcommand is denied,
  including `aws rds delete-db-instance`, `aws s3 rm --recursive`,
  `aws ec2 terminate-instances`, `gcloud sql instances delete`,
  `az group delete`, and unknown verbs.

DNS and email auth:
- B-3: any DNS record or zone change is denied: `aws route53
  change-resource-record-sets|delete-hosted-zone`, `gcloud dns record-sets
  create|delete|update|transaction`, `az network dns ... create|delete|update`,
  `doctl compute domain records create|update|delete`, `doctl compute domain
  delete`, `flarectl dns create|update|delete`, `wrangler` DNS subcommands.
- B-4: `curl`, `wget`, `http`/`https` (httpie) and `xh` with a non-GET method
  (`-X`/`--request` POST|PUT|PATCH|DELETE in any spelling, or `-d`/`--data*`/
  `-F`/`--form`, which imply POST) to a provider API host are denied. Hosts:
  `api.cloudflare.com`, any `*.amazonaws.com`, `*.googleapis.com`,
  `management.azure.com`, `api.digitalocean.com`, `api.vercel.com`,
  `api.fly.io`, `api.heroku.com`, `backboard.railway.app`,
  `api.netlify.com`, `api.namecheap.com`, `api.godaddy.com`, `api.gandi.net`,
  `api.porkbun.com`. A GET to the same hosts is allowed.

Infrastructure tools:
- B-5: `terraform` and `tofu` `plan|show|validate|fmt|init|output|providers|
  version|graph`, `state list|show`, and `workspace list|show` are allowed;
  `apply`, `destroy`, `import`, `taint`, `untaint`, `state rm|mv|push|replace-provider`,
  `workspace delete`, and `force-unlock` are denied.
- B-6: `pulumi preview|stack ls|stack output|whoami|about` are allowed;
  `up`, `destroy`, `refresh`, `cancel`, `stack rm`, `state delete` are denied.
- B-7: `kubectl` read verbs (`get`, `describe`, `logs`, `top`, `explain`,
  `version`, `api-resources`, `config view|get-contexts|current-context`,
  `auth can-i`, `diff`) are allowed in any context. Mutating verbs (`delete`,
  `drain`, `cordon`, `scale`, `patch`, `apply`, `create`, `edit`, `replace`,
  `rollout restart|undo`, `set`, `label`, `annotate`, `exec`, `cp`) are:
  allowed when `--context` names a local cluster (`kind-*`, `minikube`,
  `docker-desktop`, `k3d-*`, `rancher-desktop`); denied when the context
  is production-marked; asked otherwise (including no `--context`).
- B-8: `helm list|status|template|lint|show|get|history|version` are allowed;
  `install|upgrade|uninstall|rollback` follow the B-7 context rule
  (`--kube-context`).
- B-9: PaaS destroy-class commands are denied: `fly`/`flyctl apps destroy|
  volumes destroy|postgres destroy`, `heroku apps:destroy|pg:reset|addons:destroy`,
  `railway down|delete`, `vercel remove|rm`, `netlify sites:delete`,
  `wrangler delete|d1 delete|kv namespace delete|r2 bucket delete`.
- B-10: production deploys are denied: `vercel --prod` (any position),
  `railway up -e production`, `wrangler deploy --env production`,
  `fly deploy` with `--app` or `-c`/`--config` naming a production-marked
  app or file, `heroku` with `--app` naming a production-marked app.

Environment detection (shared by the SQL and infra rules):
- B-11: a command is production-targeted when any of these holds:
  `RAILS_ENV`, `NODE_ENV`, `APP_ENV`, `ENVIRONMENT`, `STAGE`, `MIX_ENV` or
  `DJANGO_SETTINGS_MODULE` is assigned a value containing `prod`; `-e`/`--env`/
  `--environment` is `production` or `prod`; `--context`, `--kube-context`,
  `--profile`, `AWS_PROFILE`, `TF_WORKSPACE` or a host in a connection URL or
  `-h`/`--host` contains `prod`, `production` or `live` as a word; or any of
  those values matches `.enforce.json` `environments.production`.
- B-12: a value matching `environments.preview` or `environments.testing`
  is never production-targeted, even when it contains `prod`.
- B-13: destructive SQL already caught by `destructive-db-guard.sh` is denied
  (not asked) when B-11 holds, e.g. `psql postgres://db.prod.acme.com/app -c
  "DROP DATABASE app"` and `RAILS_ENV=production rails dbconsole <<< "TRUNCATE x"`.

ORM and SQL:
- B-14: ORM data-loss commands ask, and are denied when B-11 holds:
  `prisma migrate reset`, `prisma db push --accept-data-loss|--force-reset`,
  `rails|rake db:drop|db:reset|db:purge|db:schema:load`, `manage.py flush|reset_db`,
  `alembic downgrade base`, `knex migrate:rollback --all`,
  `sequelize db:migrate:undo:all`, `typeorm schema:drop`, `drizzle-kit drop`.
- B-15: `UPDATE ... SET ...` with no `WHERE` asks, and is denied when B-11 holds.
- B-16: `DELETE FROM t WHERE ...` against a local target (no remote host, or
  `localhost`, `127.0.0.1`, a unix socket) is allowed. Without `WHERE` it
  asks as today.
- B-17: running a migration (`prisma migrate deploy`, `rails db:migrate`,
  `manage.py migrate`, `alembic upgrade`, `knex migrate:latest`) is denied
  when B-11 holds.

Evasion:
- B-18: a simple command whose command word is a command substitution
  (`$(...)` or backticks) asks.

Non-regression:
- B-19: every row already in `fixtures/guard-corpus.txt` keeps its decision.
- B-20: the corpus is also run through `codex/hooks/codex-hook-adapter.sh`
  and `cursor/hooks/claude-hook-adapter.sh`, and reaches the same decision
  for every row.

## Acceptance criteria (PR 2d: target environment propagation)

Owner-approved follow-up, 2026-10-05: a production target set in the
environment must reach every command that inherits it, not only the command
the assignment prefixes.

- B-33: a target assignment (`DATABASE_URL`, `*_DATABASE_URL`, `PGHOST`,
  `PGHOSTADDR`, `PGSERVICE`, `MYSQL_HOST`, `*_ENV`, `KUBECONFIG`,
  `AWS_PROFILE`, `CLOUDSDK_ACTIVE_CONFIG_NAME`) that prefixes a shell
  (`bash -c`, `sh -c`, `zsh -c`, `env VAR=... sh -c`, `eval`) applies to every
  command inside that shell's string: `DATABASE_URL=<prod> bash -c 'npx
  prisma migrate deploy'` denies under B-17.
- B-34: `export NAME=value`, `declare -x NAME=value`, `typeset -x`,
  `set -a` followed by `NAME=value`, and a plain `NAME=value;` statement each
  apply to every later command in the same command string:
  `export DATABASE_URL=<prod>; rails db:migrate` and
  `export PGHOST=<prod> && psql -c "DROP TABLE t"` deny (B-17, B-13).
  `unset NAME` ends it.
- B-35: the same propagation feeds the preview/testing rules and the
  unknown-remote asks, so a propagated non-production remote target asks as
  a prefixed one does, and a propagated local target changes nothing.
- B-36: a target assignment inside a subshell `( ... )` or a function body
  applies only inside it.

## Invariants

- The guard is stateless: one event in, one decision out, no files written.
- A parse failure fails closed, as the existing destructive-ops layer does.
- Messages never echo a secret: a connection URL in a reason has its
  password replaced by `***`.

## Non-goals (this PR)

- MCP tools that change DNS or cloud resources (PR 2b: `mcp-action-guard`
  name tokens `dns`, `record`, `zone`, `domain`, `route53`, plus verbs
  `change`, `set`, `put`, `run`, `call`, `invoke`).
- Scanning written script files for deny-class commands (PR 2b).
- Credentials, audit log, claim check, backups (PRs 3 to 6).

## Security

The guard reads only the event and `.enforce.json`. A `.enforce.json` the
agent edits could unmark production; `protected-path-guard.sh` already denies
session writes to it (R-410), and a Bash write to it is outside that guard's
reach (noted, not fixed here).
