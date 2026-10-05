# Hardening PR 3: credential reads

Plan: hardening control 3 (credential scoping), approved by the owner
2026-10-04 with the other five PRs. Sibling spec:
`docs/specs/2026-10-04-harness-hardening.md`.

## Goal

An agent never puts a credential into its own context: it does not read a
credential file and does not print a credential environment variable. Programs
the agent runs may still use credentials (a test run reads `DATABASE_URL`); the
agent just never sees the value.

## Threat model

- **Attack to stop:** a Bash command or a Read/Grep call that brings a
  credential's value into the transcript, from a credential file or from the
  process environment, issued by an agent debugging, exploring, or "checking
  the config". Once in the transcript the value is in logs, prompts and
  possibly a commit.
- **Human-only means deny.** As in PR 2, `defaultMode` is `auto`, so every
  rule here is a deny; the message says a human can run the command by hand.
- **Severity ceiling:** a program the agent writes and runs can still read and
  print a credential. Output redaction (`redact-output.sh`) is detection only.
  Out of scope for hooks, noted.
- **Accepted cost:** debugging a broken `.env` becomes a human step.

## Credential paths

A path is a credential path when, after `~` and `$HOME` expansion, it is or
lies under one of:

- `.env` or `.env.*` in any directory, except `.env.example`, `.env.sample`,
  `.env.template`, `.env.dist`; and `.envrc`.
- `~/.aws/`, `~/.ssh/` (except `*.pub`, `known_hosts`), `~/.gnupg/`,
  `~/.kube/`, `~/.azure/`, `~/.config/gcloud/`, `~/.docker/config.json`,
  `~/.config/gh/hosts.yml`, `~/.netrc`, `~/.pgpass`, `~/.my.cnf`, `~/.npmrc`
  and a repo `.npmrc`, `~/.pypirc`, `~/.terraform.d/credentials.tfrc.json`,
  `~/.config/doctl/`, `~/.wrangler/` and `~/.config/.wrangler/`,
  `~/.cloudflared/`, `~/.fly/`.
- Any file named `*.tfvars`, `*.tfstate`, `*.tfstate.backup`, `*.pem`,
  `*.key`, `*.p12`, `*.pfx`, `id_rsa*`, `id_ed25519*` (except `*.pub`).

## Credential variable names

A variable name is a credential name when it matches (case-insensitive)
`*_TOKEN`, `*TOKEN_*`, `*_SECRET*`, `*_KEY`, `*_KEY_ID`, `*PASSWORD*`,
`*PASSWD*`, `*_DSN`, `DATABASE_URL`, `*_DATABASE_URL`, `*_DB_URL`,
`CLOUDFLARE_*`, `AWS_*` (except `AWS_REGION`, `AWS_DEFAULT_REGION`,
`AWS_PROFILE`), `GH_TOKEN`, `GITHUB_TOKEN`.

## Acceptance criteria

Shell reads (PreToolUse Bash, new hook `credential-read-guard.sh`, built on
`shell-command-segments.py`):

- C-1: a command that names a credential path as an operand denies, whatever
  the program (`cat`, `head`, `less`, `grep`, `base64`, `xxd`, `python`,
  `node`, `awk`, `sort`, `diff`, `cp` to anywhere, `scp`, `tar`, a redirect
  `< .env`, `source .env`, `. .env`, `set -a; . .env`).
- C-2: metadata-only programs pass: `ls`, `stat`, `test`, `[`, `[[`, `file`,
  `du`, `git check-ignore`, `git ls-files`, `git status`, and `find` without
  `-exec`, `-execdir`, `-ok`, `-delete`, `-fprint`.
- C-3: a non-credential look-alike passes: `.env.example` and the other
  exemptions, `~/.ssh/id_ed25519.pub`, `~/.ssh/known_hosts`, `envsubst`,
  `my.env.ts`, `environment.yml`.

Environment printing (same hook):

- C-4: dumping the whole environment denies: `env` or `printenv` with no
  command operand, `export -p`, `declare -p`, `declare -x`, `typeset -p`, `set`
  alone, and any read of `/proc/<pid or self>/environ`.
- C-5: printing one credential variable denies: `printenv NAME`, and `echo`,
  `printf` or a here-string whose words expand `$NAME` or `${NAME...}`, when
  NAME is a credential name. Also `env | grep ...` and `printenv | ...`.
- C-6: passing a credential variable to a program passes (`psql
  "$DATABASE_URL" -c ...`, `curl -H "Authorization: Bearer $GH_TOKEN" ...`),
  as does printing a non-credential variable (`echo $HOME`, `printenv PATH`)
  and `env FOO=1 cmd` used as a launcher.

Tool reads:

- C-7: a Read tool call on a credential path denies; a Grep tool call whose
  `path` is a credential path, or a directory listed above, denies. The
  permission deny list in `claude/settings.json` is widened to the same paths
  as a second layer.

Session start:

- C-8: a SessionStart hook prints one line naming (never valuing) each
  credential variable present in its environment, and nothing when there is
  none. A test sets a variable to a sentinel value and checks the output holds
  the name and never the value.

Ports and non-regression:

- C-9: the guard corpus runs the C-1 to C-6 rows through the Codex and Cursor
  adapters with the same decisions. The Read hook and the SessionStart hook are
  ported where the target has the event, and the port maps mark them otherwise.
- C-10: every row already in `fixtures/guard-corpus.txt` keeps its decision.

## Invariants

- The guard is stateless and fails closed on a parse failure.
- No reason or output ever contains a credential value.

## Non-goals

- Credentials inside a program the agent writes (see severity ceiling).
- Write protection for credential paths: R-103 in `secret-scan.sh` already
  denies mutations.
