# Setup documentation

## Goal

Create a professional installation and verification guide for the `agent-governance` harness: how to install it, how it is configured, how to sync it into each tool's live config directory, how to verify the install is healthy, and how to uninstall or revert. This spec owns the harness's single front door; day-to-day usage recipes are a separate spec (`2026-09-17-recipes-design.md`).

## Inputs

- Existing `claude/SETUP.md`.
- Root `README.md` and `claude/README.md`.
- Existing scripts: `sync.sh`, fixture test runners, translator checks, and install hooks.
- The recipes doc (sibling spec), for the "which document do I read?" table only; this spec does not define recipe content.

## Outputs

- `SETUP.md` at the repo root or an explicitly documented stable setup path, covering install, prerequisites, configuration, sync, verification, and uninstall/revert.
- README links to `SETUP.md` and to `RECIPES.md` (the sibling spec's output).
- A short "which document do I read?" table distinguishing setup (one-time install/verify) from recipes (day-to-day tasks).

## Acceptance criteria

- B-1: Setup docs include prerequisites for `jq`, `node`, `python3`, git hooks, Claude Code, Codex CLI when enabled, and Cursor when enabled.
- B-2: Setup docs explain how to run `./sync.sh`, what it copies, what it never deletes, and how live config directories differ from tracked repo folders.
- B-3: Setup docs include a verification section with the fixture suite commands and any doctor command when implemented.
- B-4: Setup docs explain how to configure optional Codex/Cursor support without making those tools mandatory.
- B-5: Setup docs are safe for public readers and contain no local paths beyond examples that use placeholders.
- B-6: Existing duplicated setup instructions in README files are replaced by links to `SETUP.md`.
- B-7: The README carries a "which document do I read?" table that sends installation questions to `SETUP.md` and day-to-day task questions to `RECIPES.md`.

## Invariants

- Optional surfaces (Codex, Cursor) remain optional; setup never states a supported tool is required.
- Setup commands are copy-paste safe from the repository root unless the doc says otherwise.

## Failure modes

- A command differs by operating system: document macOS as the maintained path and mark other paths as unverified unless tested.
- A command requires a secret or account login: state the prerequisite without asking the user to paste secrets into shell history.

## State transitions

Local installation: `uninstalled` to `synced` to `verified`. Setup implements and documents these transitions; the recipes doc may reference them but does not implement them.

## Non-goals

- No implementation of a doctor CLI unless that spec is active.
- No restructuring of runtime files.
- No publishing workflow or release automation.
- No day-to-day task recipes; see `2026-09-17-recipes-design.md`.

## Dependencies

- Public documentation refresh (`2026-09-17-public-documentation-design.md`) should link to this doc.
- The recipes spec depends on this doc existing for the disambiguation table; this spec does not depend on recipes content.

## Observability

- Setup verification records exactly which checks were run.

## Security

- Do not include tokens, account ids, local usernames, or real remote URLs.
- Include a warning that secret-bearing config stays outside the repo.

## Domain vocabulary

- setup doc - installation and verification guide for a new checkout - chosen over: bootstrap because setup is clearer for external readers.
- optional surface - a supported tool folder that a user may leave disabled, such as Codex or Cursor - chosen over: secondary surface because source-neutral sync avoids hierarchy.
