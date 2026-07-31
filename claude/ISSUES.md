# Issues

Deferred P2/P3 work for the `~/.claude` rule system, per R-802/R-601. One line per item; delete on resolution.

## Open

- P3 (2026-07-31 Ruby/Go parity): `enforce/golangci-enforce.yml` is written against the golangci-lint v1 schema and could not be validated locally (no Go toolchain); validate and migrate to the v2 schema if needed on the first real Go project. The gate fails open on unparseable output either way.
- P2 (2026-07-31 engineering audit): commit 266d05e is an unpaired `fix:` touching only `enforce/eslint.config.mjs` with no test; single instance, R-403 pattern note.
- P3 (2026-07-31 engineering audit): `structure-gate.sh` applies the TS-only R-314 nested-`__tests__` deny message to Python test filenames; untested edge, low likelihood.
- P3 (2026-07-31 engineering audit): `push-ruff-gate.sh` and `push-eslint-gate.sh` split the changed-file list with `xargs`, mishandling a space-containing path; pre-existing pattern shared by both gates.
- P3 (2026-07-03 engineering audit): session-lifecycle and notifier hooks (`session-start.sh`, `pre-compact.sh`, `ntfy-notify.sh`) have no fixture tests; they are environment-heavy (session payloads, network) and need harness design before testing is honest rather than performative.
- P3 (2026-07-03 engineering audit): `Enforcement: judge` is the template token for llm-judge-tier rules; R-320/R-322 additionally name their advisory reminder hooks. Reviewed and kept as-is: the bare token is template-conformant, and the suffixes carry real information. Recorded here so the style question does not resurface as a finding.

## Resolved

- 2026-07-31: structure-gate never fired for Python's app/-rooted layout (P1); R-516 guard and manifest test blind to ruff:* enforcers (P1); hook-latency chain missing push-ruff-gate (P2) -> fixed with fixture tests in the post-audit commit.
- 2026-07-03: agents/ audit-role files cited pre-renumber rule IDs (P1) -> migrated in 9c01327.
- 2026-07-03: ten guard-enforced rules missing manifest entries, closure unchecked (P1) -> closure test + entries in 77a8512.
- 2026-07-03: phantom R-503 manifest enforcer; R-505 subject format enforced but not codified (P2) -> 7ffaffc.
- 2026-07-03: seven blocking/advisory guards untested (P2) -> fixture tests + hooks/tests runner in d9a7bd8.
