# Public documentation refresh

## Goal

Rewrite the externally facing documentation so `agent-governance` reads as professional documentation for an agentic governance harness. The public README and Claude-surface README should explain what the harness does, how it is installed, how it is verified, and how users adapt it, without war stories, autobiographical framing, casual tone, or incident memoir language.

## Inputs

- Root `README.md`.
- `claude/README.md`.
- `codex/README.md` and `cursor/README.md` for port explanations.
- `claude/SETUP.md` and any new setup or recipe docs created by the usage-docs spec.
- Existing specs for public hardening, source-neutral sync, and cross-model dialogue.

## Outputs

- A root README that introduces the repo as an agentic governance harness for Claude Code, Codex CLI, and Cursor.
- A Claude README that documents the Claude Code surface as one supported runtime surface, not as a personal operating-system memoir.
- A concise architecture section explaining rules, hooks, skills, agents, enforcement tests, sync, and ports.
- A public-readiness note that clearly separates reusable harness mechanisms from operator-specific preferences.
- Links to setup and recipes docs instead of long procedural prose embedded in the README.

## Acceptance criteria

- B-1: The root README states the project purpose, supported tool surfaces, high-level architecture, install entry point, verification entry point, and adaptation guidance in the first 100 lines.
- B-2: The root README removes biographical or casual phrases such as "personal operating system", "scar tissue", "got burned", "make it yours", and similar writer-centered framing.
- B-3: The Claude README explains the Claude surface in professional terms: runtime settings, hooks, rules, skills, agents, memory, enforcement, and sync.
- B-4: War-story content moves out of public onboarding docs unless it is required as a short rationale in `PROTOCOL.md` or a dated audit. Public README prose may reference incident-driven design without narrating incidents.
- B-5: Public docs distinguish reusable harness components from local preferences: output style, model routing defaults, em dash rule, audit cadence, and personal memory.
- B-6: Public docs include a "Trust boundaries" section explaining that permissions and hooks are anti-accident controls, while sandboxing or operating-system containment is the boundary for Bash subprocesses.
- B-7: Public docs include a "Generated and local artifacts" section explaining which docs are tracked, which are ignored, and how generated port files should be updated.
- B-8: Every claim about counts of hooks, rules, fixtures, or generated files is either generated from a checked source or removed.
- B-9: Links resolve to existing files after the rewrite.
- B-10: The final docs contain no secrets, local home paths, client-identifying references, or unpublished credentials.

## Invariants

- Documentation remains accurate for the current repo shape: `claude/`, `codex/`, and `cursor/` are peer folders in one monorepo.
- Public docs do not claim universal best practices. They present an opinionated harness and named extension points.
- Dated audit reports and protocol history may preserve incident details, but onboarding docs do not lead with them.

## Failure modes

- A README claim cannot be verified against the repo: remove the claim or rewrite it as a link to the source file.
- A personal preference is still presented as a general rule: move it to an adaptation section.
- A count drifts from source: remove the count unless a generator backs it.
- A link points to a soon-to-be-ignored doc: replace it with a stable setup or recipe link.

## State transitions

None. This spec rewrites documentation, not runtime state.

## Non-goals

- No implementation of sandboxing, doctor checks, source-neutral sync, or cross-model dialogue.
- No deletion of audit history or protocol rationale.
- No new branding package, logo, landing page, or website.
- No attempt to make the harness vendor-neutral beyond accurately documenting Codex and Cursor ports.

## Dependencies

- Repository file inventory at implementation time.
- Any setup and recipes specs implemented before or alongside this rewrite.
- Existing docs convention that specs live under `claude/docs/superpowers/specs/` until the docs-gitignore cleanup decides their tracked location.

## Observability

- Implementation reports the docs changed and the links checked.
- The final commit summary names which public docs were rewritten.

## Security

- Treat every public doc as publishable.
- Run the R-106 public-diff review before pushing.
- Do not include local filesystem paths except repo-relative paths.

## Domain vocabulary

- agentic governance harness - a repository of rules, hooks, skills, agents, tests, and setup guidance that constrains and verifies AI coding agents - chosen over: personal operating system because the public docs should describe the artifact, not the maintainer.
- runtime surface - one tool-specific configuration tree such as `claude/`, `codex/`, or `cursor/` - chosen over: target because source-neutral sync makes each surface both input and output.
- reusable component - a harness part intended for other users to adopt, such as hooks, role policies, or verification scripts - chosen over: generic part because reuse is a release decision.
- local preference - an operator-specific choice that a downstream user may remove or recalibrate - chosen over: personal quirk because the docs should stay professional.
