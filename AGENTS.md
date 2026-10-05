# agent-governance (project instructions for Codex)

<!-- Hand-authored project-local bootstrap, not generated. codex/AGENTS.md beside it
     is the PAYLOAD that translate/codex.mjs generates and sync.sh installs into
     ~/.codex/AGENTS.md; this file is this repository's own project config, the Codex
     counterpart of .claude/settings.json and .cursor/rules/000-harness-bootstrap.mdc,
     and no exporter writes it. Codex merges this file with ~/.codex/AGENTS.md. -->

This checkout is the source of the governance harness, not a consumer of it. The prose
rules live in the tool-neutral `rules/` tree; `node translate/all.mjs --write` generates
`claude/`, `codex/` and `cursor/` from it (hooks, `enforce/` and `settings.json` stay
hand-authored in `claude/`), and `./sync.sh` installs `codex/` into `~/.codex`. No tool
is primary: edit `rules/` from any of them. Text meant for one tool only goes in an
`<!-- only: codex -->` ... `<!-- /only -->` block (targets: claude, codex, cursor).

## Do this first

Run `./sync.sh` from the root of this checkout before relying on any rule or gate.
Claude Code sessions do this automatically through a `SessionStart` hook registered in
`.claude/settings.json`; Codex has no equivalent automatic entry point, so the step is
yours. It is idempotent and never deletes a live file it did not install, a deliberate
tradeoff after an earlier destructive incident: it removes a file only when its own
manifest (`.sync-manifest` in each live directory) shows it installed that file, the
repository no longer tracks it, and its live content is unchanged.

Until it runs, the rules loaded from `~/.codex` are whatever was installed last, which
may predate every change in your working tree. The failure is silent: a stale rule file
reads exactly like a current one.

## Verify rather than assume

- `node translate/all.mjs --check` exits 0 when `claude/`, `codex/` and `cursor/` match
  their `rules/` sources, 1 when a source edit was never regenerated, 2 on a source
  error. A nonzero exit means the payload itself is stale and syncing would install the
  staleness; run `node translate/all.mjs --write` first.
- `diff -r codex ~/.codex` names the specific files that differ.

## What not to edit

Everything under `codex/` is generated except `codex/hooks/codex-hook-adapter.sh` and
`codex/README.md`, which the port map classifies hand-authored. Editing any other file
under `codex/` is lost at the next `--write`, and `--check` fails in CI and at push
until it is reverted. Change the `rules/` source (or, for hooks, the `claude/` hook) or
`translate/codex-port-map.json` instead, then regenerate with
`node translate/all.mjs --write`. The same holds for the prose files in `claude/`,
which are now generated from `rules/` too.

## What is weaker under Codex than under Claude Code

The adapter (`codex/hooks/codex-hook-adapter.sh`) replays each `apply_patch` as the
file edits the gates read, and translates decisions into Codex's shape. A rule tagged
`hook:X in Claude Code; manual in Codex` in `codex/AGENTS.md` has no Codex event behind
it and depends on recall here. Treat those rules as yours to honor rather than as
something the harness will catch.
