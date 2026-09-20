# Session Handoff: 2026-09-20, the R-907 codex runtime marker (#89)

## 1. Last commit

- `321a9f1` on `main`: `fix(hooks): let the codex CLI edit test files under its own hook adapter (IAN-174) (#89)`. Squash-merged, branch deleted, presence on `main` verified by file content rather than the PR badge.
- `./sync.sh` has run since the merge, so the live `~/.claude`, `~/.codex` and `~/.cursor` all carry it. This also clears the previous handoff's pending item 1 (the stale harness from #83, #84 and #86).

## 2. Production state

- `~/.codex/hooks/codex-hook-adapter.sh` exports `CLAUDE_HOOK_RUNTIME=codex`, and `~/.claude/hooks/codex-test-author-guard.sh` exits on that value with a `codex-runtime` rule fire. The next `codex exec` on this machine can write test files.
- Codex is over quota until 2026-09-21 02:26. The dispatch was attempted this session and returned the usage-limit error, so both the test author and the pre-merge review ran on the recorded Claude fallback.
- The Linear connector sat at `pending` for roughly the first hour of the session and its tools surfaced on their own afterwards. Nothing in-session forces it.

## 3. Session metrics

- PRs merged: 1 (#89). Two TDD slices, seven commits before the squash.
- IAN-174 closed at 65 attributable minutes against a 102 estimate, ratio 0.64. `rework_count` 1 (the review round).
- Recalibration: the p80 overestimated and the 48 median would have underestimated. Next standard/llm estimate moves toward the median, with p80 reserved for a dependency that actually blocks rather than delays.

## 4. What shipped

- **The runtime marker (#89, IAN-174).** `codex-hook-adapter.sh` exports `CLAUDE_HOOK_RUNTIME=codex` once, near the top, so every hook child inherits it on both dispatch paths. `codex-test-author-guard.sh` exits silently on exactly that value, past the test-file decision, logging a `codex-runtime` fire so a silenced guard is visible in the fire log. A Claude Code session sets no such variable and still gets the R-907 ask. Equality, not a prefix: `codex-review` still asks.
- **Fixtures.** `codex-test-author-guard.test.sh` gains the runtime cases plus the telemetry assertions; `codex-adapter-contract.test.sh` proves the real adapter sets the marker on both doors, asserts the synthesized write event is really walked, and runs the guard and adapter together on the defect's own `apply_patch` shape.
- **The uv section** of `skills/tdd-gated-dispatch/SKILL.md` documents redirecting uv's cache into the workspace or `$TMPDIR` so `uv run pytest` works under `-s workspace-write`, with the inline-assignment form, the `shell_environment_policy.set` variant and `--add-dir`. All paths defer to `uv cache dir` and `uv python dir` rather than hardcoding.

## 5. Pending (by urgency)

1. **IAN-181** (about 48 minutes, HIGH): settle whether Codex has a write route reaching no `Write|Edit` gate. The 2026-09-19 create-versus-edit asymmetry is not reproducible; if reading 2 is right, five gates are being bypassed. Needs `CLAUDE_CODEX_HOOK_DEBUG=1` and the Codex quota.
2. **IAN-183** (about 48 minutes, HIGH): `hook-latency.test.sh` is flaky at its budget line and blocks `tdd.sh red` on every unrelated slice when it trips. Measured 296ms, 354ms, 279ms against budgets of 294ms, 318ms, 288ms in three consecutive runs.
3. **IAN-182** (about 48 minutes): key the R-907 silence on the test-author dispatch rather than the runtime. The marker currently names the runtime while the invariant is about role, which is documented as residual scope in R-907 and the guard header.
4. **IAN-157** (about 3 hours): three guards still match substrings instead of parsing.
5. **IAN-156** (about 90 minutes): the R-509 stop gate blocks a test-author subagent on its intended RED. Same class as IAN-183.
6. **IAN-140, IAN-142 to IAN-144**: the remaining ECC P1 ports (about 9 hours together).

## 6. Next session

1. `enforce/hook-hashes.txt` hashes `enforce/tests/*.test.sh`, so editing a FIXTURE drifts the manifest and reds `hook-hashes-closure`, which makes `tdd.sh red` refuse the whole slice with "the rest of the suite is red". That reads like a stale harness needing `./sync.sh` and is not. Regenerate with `CLAUDE_INTEGRITY_ROOT=$PWD/claude bash claude/hooks/hook-integrity-check.sh --update` before `tdd.sh red`, and again after the implementation.
2. Never guess the next free ticket key from git history. It was done here, IAN-164 collided with a ticket another session opened the same morning, and five commits needed `git filter-branch --msg-filter` to rewrite their `Refs:` trailers. `get_issue` the candidate first.
3. A connector at `pending` means "not yet", never "not coming". Keep probing at each natural pause rather than concluding the tracker is unavailable.
4. `claude/rulebook/cost.md` and `skills/tdd-gated-dispatch/SKILL.md` are translated surfaces: `node translate/codex.mjs --write` and `node translate/cursor.mjs --write` after editing either, or the pre-push port check refuses the push.
5. `docs/audits/2026-09-19-capability-assessment.md` is still untracked in the primary checkout, as it was at the start of this session. It is nobody's current work; decide whether to commit or delete it.
