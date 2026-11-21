# enforce/

Support files for the safety hooks and the status line:

- `secret-patterns.txt`: patterns `secret-scan.sh` and `redact-output.sh` match.
- `mcp-database-targets.txt` (optional, local): database identifiers `destructive-db-guard.sh` treats as production.
- `resolve-outgoing-base.sh`: the outgoing diff base `global-repo-push-guard.sh` scans.
- `agent-watchdog.sh`: wakes the main session when a background subagent stalls.
- `route.sh`, `route-steps.json`: name the agent for a step from its tier and this machine's `agent-tier-assignments.json`.
- `qwen-implementer-dispatch.sh`: runs one GREEN attempt on the local Qwen model and judges the result (tests, protected paths, timeout).
- `quota-pace.sh`: records quota snapshots and reports pace per provider.
- `style-check.sh`: PR-scoped style check on the lines a change adds to `*.sh` files, skipping `tests/` and `node_modules/` paths (width over 100, functions without a comment block, shellcheck warnings); CI runs it on pull requests.
- `security-ci-*.sh`, `semgrep/`: the semgrep and CodeQL steps of the security CI workflow.
- `tests/`: hook fixtures; `bash tests/run-tests.sh` runs every fixture.
