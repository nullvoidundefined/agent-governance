# Spec inventory and queued work

Audited 2026-09-17 against main at `4bc8746`, all-branch history, and named artifacts. This document is local planning state and intentionally ignored. Original specs are preserved locally, including completed and parked designs, because this recovery task prioritizes retaining surviving work. No implementation plans were found alongside the original nine specs; a tenth build-mode spec was added during this session.

## Inventory

| Spec | Status | Evidence and remaining work |
| --- | --- | --- |
| 2026-09-12-agent-governance-monorepo-design.md | PARTIAL; core delivered | `61da3ca`, `f73068c`, and `23592ae` implement tracked-file copy and no-delete sync. Current semantics supersede the original replace-everything wording. Remote archival and every historical acceptance criterion were not independently verified. Reconcile the old design before marking fully shipped. |
| 2026-09-17-codex-translator-design.md | SHIPPED | `8593356`, `translate/codex.mjs`, its renderer modules, port map, fixture, and CI check implement the translator. Preserve the design as local recovery material. |
| 2026-09-17-claude-config-public-hardening-design.md | PARTIAL on another branch | `claude/hardening-verification-core` contains doctor work in `c83c6b1`, `eb91976`, and `ea6009a`; it is not on main. Remaining criteria include broader doctor verification, sandboxing, status line, installer backup/merge, resume drift, capability matrix, instruction reduction, and override reporting. Public-doc work overlaps this task. Coordinate with that branch rather than rebuilding its doctor. |
| 2026-09-17-cross-model-dialogue-design.md | UNSTARTED | `cde9b45` and `4bc8746` are design commits. No named dialogue CLI, config, skill, assumption-reviewer, or dispute-reviewer exists in this checkout. Implement configurable primary/secondary routes, bounded review patterns, role restrictions, outcomes, and failure tests. |
| 2026-09-17-source-neutral-governance-sync-design.md | PARKED; selected work retained | `94de2b6` explicitly parks bidirectional sync. Cursor export and file-ownership classification are retained follow-ups. Do not implement the neutral model merely because the older handoff recommends it. |
| 2026-09-17-public-documentation-design.md | IMPLEMENTED IN CURRENT DIFF | Root and Claude READMEs, setup, recipes, and port links now describe a reusable third-party harness. Public relative-link checks, Codex translation check, sync fixture, and whitespace verification passed. |
| 2026-09-17-repository-artifact-cleanup-design.md | PARTIAL | Handoffs and all Superpowers docs are ignored and previously tracked copies removed from the index, preserving local files. A complete per-file retention audit of all docs and ports and remediation of legacy Cursor artifacts remain queued. Dated audits and runtime sources remain tracked. |
| 2026-09-17-harness-naming-normalization-design.md | UNSTARTED as a complete migration | Earlier hygiene commits include isolated naming changes (`a2fa34e`, `6fe0234`), but `gof` and existing role/skill names remain. The comprehensive lexicon, mapping table, compatibility strategy, and regeneration checks have not shipped. |
| 2026-09-17-setup-and-recipes-design.md | PARTIAL; guides now written | The original spec survived untracked. `claude/SETUP.md` is the stable setup path and root `RECIPES.md` covers all eight requested workflows. Selective runtime enablement is not implemented; the guide explains that sync copies all surfaces. Final names depend on the naming migration. |

## New request: delivery modes

`2026-09-17-build-spec-design.md` is UNSTARTED. It specifies a new speed-oriented `build-spec` skill and migration of the existing stability/flexibility-oriented `build-by-slice-require-review` skill to the approved name `build-spec-by-slice`. Implement one-shot orchestration over atomic TDD tasks without routine approval pauses, preserving author separation, locked tests, required reviews, checkpoint/resume, and final conformance. It does not authorize implementation or publication in this documentation task.

## Recommended queue

1. Complete and review the existing public-hardening branch, preserving its pending security work and avoiding overlap with these documentation changes.
2. Ground the dialogue CLI spec around runtime/provider/model selection and an optional secondary. Implement the smallest useful review workflow before expanding the six patterns.
3. Verify single-tool operation in both directions, quota and authentication fallback, billing boundaries, and read-only review. Preserve test/implementation author separation even when only one model provider is available.
4. Add Gemini CLI as the first additional adapter after the initial pairing works; evaluate OpenCode and Copilot against demand and integration cost. See `docs/model-targets.md` for the research.
5. Finish the artifact retention audit and Cursor exporter/file-classification follow-ups. Keep bidirectional source-neutral sync parked until there is evidence it is needed.
6. Perform naming normalization with compatibility checks, then update recipes to the final names. Do not hold a usable small release for purely cosmetic renaming.

## Dialogue requirements recovered from the user

The CLI must select both primary and secondary models, not only Claude versus Codex as tools. A secondary is optional. The current spec's tool-level settings leave individual model selection unspecified, and its fallback criteria are more explicit for Claude-only than Codex-only users.

The six retained patterns are spec critic loop, plan red-team/implementer, test-author/code-author split, parity judge, assumption ledger, and independent audit reports. Keep artifact boundaries and stopping conditions. Missing review is a visible outcome, not silent approval. Review fallback and primary-actor failover require different permissions.

## Retention decisions

| Artifact | Decision |
| --- | --- |
| Public guides and runtime source | Keep tracked. |
| Session handoff and Superpowers documents at any depth | Ignore; preserve local copies; remove tracked copies from the index. |
| Generated Codex files | Keep tracked with translator and check ownership. |
| Legacy Cursor manifests and headers | Keep pending the existing port follow-up; do not imply current generation. |
| Dated audit reports | Retain as historical evidence in this scoped cleanup. Full retention review remains queued. |

Ignoring files does not purge Git history or provide private backup. Preserve local planning separately before moving machines.
