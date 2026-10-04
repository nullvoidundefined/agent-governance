# enforce/

Support files for the safety hooks and the status line:

- `secret-patterns.txt`: patterns `secret-scan.sh` and `redact-output.sh` match.
- `mcp-database-targets.txt` (optional, local): database identifiers `destructive-db-guard.sh` treats as production.
- `resolve-outgoing-base.sh`: the outgoing diff base `global-repo-push-guard.sh` scans.
- `agent-watchdog.sh`: wakes the main session when a background subagent stalls.
- `quota-pace.sh`: records quota snapshots and reports pace per provider.
- `security-ci-*.sh`, `semgrep/`: the semgrep and CodeQL steps of the security CI workflow.
- `tests/`: hook fixtures; `bash tests/run-tests.sh` runs every fixture.
