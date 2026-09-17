---
name: repo-setup
description: Use when creating a new GitHub repository, or when bringing an existing one up to the hygiene baseline before its first pull request - CI workflow, Dependabot, Greptile review, protected main and staging branches, squash-only merges, security alerts. Triggers on "set up the repo", "new repo", "repo hygiene", "protect main", or "add CI".
argument-hint: [owner/repo] [--check] [--stack node|python|go|ruby]
disable-model-invocation: true
---
<!-- Cloned from claude/skills/repo-setup/SKILL.md. Do not edit here; change the source and re-copy; enforce/tests/skills-lint.test.sh fails when this copy drifts. -->

# Repo Setup

Bring a GitHub repository to the baseline every project starts from, or audit one against it. The script decides every item; the session reads the report, does the one thing the API cannot (installing the Greptile app), and commits the files.

**Announce at start:** "I'm using the repo-setup skill to bring `<owner/repo>` to the hygiene baseline."

## The baseline

| Item | What it is | Why |
|---|---|---|
| `ci` | `.github/workflows/ci.yml`: lint, typecheck where the stack has one, and tests, on every PR and on pushes to the protected branches; the job is named `ci` | The rulesets below require a status check with that exact context, so nothing lands on main or staging without it |
| `dependabot` | `.github/dependabot.yml`: weekly updates for the workflow actions and the stack's package ecosystem, minor and patch bumps grouped | Dependencies age whether or not anyone looks |
| `pr-template` | `.github/pull_request_template.md` with the seven-field PR description format from build-by-slice-require-review | Every PR body carries context, problem, approach, contents, tests, and review focus |
| `gitignore` | A `.gitignore` for the stack, with `.env*` and the harness ledgers excluded (R-102) | A secret committed on day one is in history forever |
| `staging` | A `staging` branch, created from the default branch when absent | The deploy lane exists before the first deploy |
| `protect-refs` | Ruleset with no bypass actors: no deletion and no force push on `main` and `staging` | Nobody, the owner included, can delete or rewrite the protected branches by accident |
| `protect-merge` | Ruleset: changes to `main` and `staging` land by pull request with the `ci` check green; repository admins may bypass | Direct pushes stop being the default; the admin bypass is R-514's "on express request" |
| `merge-policy` | Squash merge only, delete the branch on merge, no auto-merge | R-512: one commit per feature on the trunk |
| `alerts` | Dependabot vulnerability alerts and automated security fixes on | A known CVE opens a PR instead of waiting for an audit |
| `secret-scan` | Secret scanning and push protection on | A pushed credential is blocked at the push, not found in an audit |
| `greptile` | The Greptile GitHub App installed for the owner | AI review on every PR; the API cannot install an app, so the script reports the install link |

`--required-reviews N` adds N required approvals to `protect-merge`; the default is 0 because a solo maintainer cannot approve their own PR and would be locked out. Pass 1 or more for a team.

## Procedure

1. From the repository's checkout, run the audit first so the user sees what will change:

   ```bash
   bash ~/.claude/skills/repo-setup/scripts/setup.sh <owner/repo> --check
   ```

   Every item prints `OK` or `MISSING` with the reason. Exit 1 means at least one item is missing.

2. Apply, which is idempotent (each item is checked before it is written, and an existing file is never overwritten):

   ```bash
   bash ~/.claude/skills/repo-setup/scripts/setup.sh <owner/repo> [--stack node|python|go|ruby] [--required-reviews N]
   ```

   The stack is detected from `package.json`, `pyproject.toml` or `requirements.txt`, `go.mod`, or `Gemfile`; pass `--stack` to override. The rulesets, the merge policy, the alerts, and secret scanning need an admin token (`gh auth status`); a `MISSING` with "admin token needed" or "not admin" means the user runs that line, not that the item is optional.

3. Do the one manual item when the report says so: open `https://github.com/apps/greptile/installations/new`, grant the repository, re-run `--check` to confirm `greptile OK`.

4. Commit the written files together (`chore(repo): CI, Dependabot, PR template, gitignore baseline`), open the first PR, and confirm the `ci` check appears on it; a ruleset that requires a context no workflow reports blocks every merge until the workflow runs once.

5. Report the final `--check` table to the user. Every row `OK` is the definition of done.

## Existing repositories

Run `--check` on any repository before its first PR of a session that touches process; `MISSING` rows are the hygiene debt. Applying to a repository with history is safe: files are written only when absent, the rulesets are added beside whatever protection exists (a classic branch protection rule stays until the user removes it), and the merge policy change affects future merges only.

## Common mistakes

- Applying before `--check`: the user should see the delta first, since the rulesets change who can push where.
- Leaving `greptile MISSING` because "the script did not do it": the script cannot; the install link is the action.
- Requiring 1 review on a solo repository: the owner cannot approve their own PR and every merge needs the admin bypass.
- Renaming the CI job: the ruleset requires the context `ci`; rename both or neither.
