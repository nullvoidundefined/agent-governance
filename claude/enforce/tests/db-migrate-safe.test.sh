#!/usr/bin/env bash
# Covers: M-1 M-2 M-3 M-4 M-9 (docs/specs/2026-10-05-migrate-backup.md)
# db-migrate-safe.sh: snapshot first, migrate only when the snapshot is good,
# one JSON log line per run, no secrets printed, bad usage exits 2.
# Every provider CLI (pg_dump, pg_restore, neonctl, aws) and the migration
# command are stubs on a temp PATH; nothing touches a real database or cloud.
#
# Interfaces this test assumes (the implementer creates them):
#   script   $CLAUDE_HARNESS_ROOT/enforce/db-migrate-safe.sh
#   options  --provider pg|neon|rds  --target NAME  -- CMD...
#            pg:   --url-env VAR  [--backup-dir DIR]
#            neon: --project-id ID --parent BRANCH
#            rds:  --db-instance-identifier ID
#   env      MIGRATE_LOG_DIR, MIGRATE_BACKUP_DIR
#   log      $MIGRATE_LOG_DIR/migrations.jsonl; snapshot_status is "ok" or
#            "failed"; migration_status is "ok" on a run, anything else
#            ("skipped") when blocked
#   neon     neonctl is stubbed to print JSON {"branch":{"id":"br-stub-1"}};
#            the wrapper must record that id as the snapshot
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/db-migrate-safe.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

WORK=$(mktemp -d) || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
umask 022

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "ok: $*"; }

if [ ! -f "$SCRIPT" ]; then
  fail "wrapper missing: $SCRIPT"
fi

BIN="$WORK/bin"; mkdir -p "$BIN"
# Each stub appends "<name> <argv>" to $STUB_CALLS and exits with its env rc.
mkstub() { # name, body
  cat >"$BIN/$1" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$1" "\$*" >>"\$STUB_CALLS"
$2
EOF
  chmod +x "$BIN/$1"
}
mkstub pg_dump 'f=""; prev=""
for a in "$@"; do
  case "$prev" in -f|--file) f="$a" ;; esac
  case "$a" in --file=*) f="${a#--file=}" ;; esac
  prev="$a"
done
{ [ "${STUB_PG_DUMP_RC:-0}" -eq 0 ] || [ -n "${STUB_PG_DUMP_PARTIAL:-}" ]; } && [ -n "$f" ] && echo dummy-dump >"$f"
exit "${STUB_PG_DUMP_RC:-0}"'
mkstub pg_restore 'exit "${STUB_PG_RESTORE_RC:-0}"'
mkstub neonctl 'if [ -n "${STUB_NEON_EMPTY:-}" ]; then echo "{}"; else echo "{\"branch\":{\"id\":\"br-stub-1\"}}"; fi; exit "${STUB_NEON_RC:-0}"'
mkstub migrate-slow 'touch "$STUB_MARKER"; sleep 30; exit 0'
mkstub aws 'case "$*" in
  *wait*) exit "${STUB_AWS_WAIT_RC:-0}" ;;
  *) echo "{\"DBSnapshot\":{}}"; exit "${STUB_AWS_CREATE_RC:-0}" ;;
esac'
mkstub migrate-cmd 'exit "${STUB_MIGRATE_RC:-0}"'

# run_case <name> <args...>: fresh dirs, runs the wrapper, sets OUT ERR RC
# CALLS LOGF BKDIR. Callers pass STUB_* and URL variables through the env.
run_case() {
  CASE="$1"; shift
  CDIR="$WORK/$CASE"; mkdir -p "$CDIR/log" "$CDIR/backup"
  CALLS="$CDIR/calls"; : >"$CALLS"
  LOGF="$CDIR/log/migrations.jsonl"; BKDIR="$CDIR/backup"
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    PATH="$BIN:$PATH" STUB_CALLS="$CALLS" \
    MIGRATE_LOG_DIR="$CDIR/log" MIGRATE_BACKUP_DIR="$BKDIR" HOME="$CDIR/home" \
    bash "$SCRIPT" "$@" >"$CDIR/out" 2>"$CDIR/err"
  RC=$?
  OUT=$(cat "$CDIR/out"); ERR=$(cat "$CDIR/err")
}
ran_migration() { grep -q '^migrate-cmd ' "$CALLS"; }
line_no() { grep -n "$1" "$CALLS" | head -1 | cut -d: -f1; }
check() { # description, condition-exit-code
  if [ "$2" -eq 0 ]; then pass "$CASE: $1"; else fail "$CASE: $1"; fi
}
log_json() { tail -1 "$LOGF" 2>/dev/null; }
check_log_keys() {
  local l; l=$(log_json)
  if printf '%s' "$l" | jq -e 'has("ts") and has("provider") and has("target") and has("snapshot") and has("command") and has("snapshot_status") and has("migration_status")' >/dev/null 2>&1; then
    pass "$CASE: log line has all M-2 keys"
  else fail "$CASE: log line missing M-2 keys: $l"; fi
  [ "$(wc -l <"$LOGF" 2>/dev/null | tr -d ' ')" = "1" ] && pass "$CASE: exactly one log line" || fail "$CASE: expected exactly one log line"
}
logf() { log_json | jq -r "$1" 2>/dev/null; }

MCMD="$BIN/migrate-cmd"

# ---- success: pg ----
SENT="sentinel-$(date +%s)-$RANDOM$RANDOM"
export TEST_DB_URL="postgres://app:${SENT}@localhost:5432/appdb"
run_case pg-ok --provider pg --target preview --url-env TEST_DB_URL --backup-dir "$WORK/pg-ok/backup" -- "$MCMD" up
check "exit 0" "$RC"
ran_migration; check "migration ran" $?
a=$(line_no '^pg_dump'); b=$(line_no '^pg_restore'); c=$(line_no '^migrate-cmd')
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
check "order pg_dump, pg_restore --list, migration" $?
grep -q '^pg_dump .*custom' "$CALLS"; check "pg_dump uses custom format" $?
grep -q '^pg_restore .*--list\|^pg_restore .*-l ' "$CALLS"; check "pg_restore --list called" $?
dump=$(ls "$BKDIR"/preview-*.dump 2>/dev/null | head -1)
[ -n "$dump" ] && [ -f "$dump" ]; check "dump file preview-<ts>.dump exists in backup dir" $?
if [ -n "$dump" ]; then
  mode=$(stat -c %a "$dump" 2>/dev/null || stat -f %Lp "$dump" 2>/dev/null)
  [ "$mode" = "600" ]; check "dump file mode is 0600 (got $mode)" $?
fi
check_log_keys
[ "$(logf .provider)" = pg ] && [ "$(logf .target)" = preview ] && [ "$(logf .snapshot_status)" = ok ] && [ "$(logf .migration_status)" = ok ]
check "log provider/target/statuses" $?
case "$(logf .snapshot)" in *preview-*.dump*) rc=0 ;; *) rc=1 ;; esac
check "log snapshot is the dump path" $rc
case "$(logf .command)" in *migrate-cmd*up*) rc=0 ;; *) rc=1 ;; esac
check "log command holds the migration argv" $rc
# M-3: sentinel never leaks
leak=0
for f in "$CDIR/out" "$CDIR/err" "$LOGF"; do grep -q "$SENT" "$f" && leak=1; done
[ "$leak" -eq 0 ]; check "M-3: URL secret absent from stdout, stderr, log" $?

# M-3 also on a failing pg_dump
STUB_PG_DUMP_RC=1 run_case pg-leak-fail --provider pg --target preview --url-env TEST_DB_URL -- "$MCMD"
leak=0; for f in "$CDIR/out" "$CDIR/err" "$LOGF"; do grep -q "$SENT" "$f" && leak=1; done
[ "$leak" -eq 0 ]; check "M-3: URL secret absent on snapshot failure" $?

# ---- snapshot failures: pg_dump, pg_restore --list ----
STUB_PG_DUMP_RC=1 run_case pg-dump-fail --provider pg --target preview --url-env TEST_DB_URL -- "$MCMD"
[ "$RC" -ne 0 ]; check "nonzero exit" $?
! ran_migration; check "migration never ran" $?
printf '%s\n%s' "$OUT" "$ERR" | grep -q 'pg_dump'; check "message names pg_dump" $?
check_log_keys
[ "$(logf .snapshot_status)" = failed ] && [ "$(logf .migration_status)" != ok ]; check "log shows failed snapshot, migration not ok" $?

STUB_PG_RESTORE_RC=1 run_case pg-restore-fail --provider pg --target preview --url-env TEST_DB_URL -- "$MCMD"
[ "$RC" -ne 0 ]; check "nonzero exit" $?
! ran_migration; check "pg_restore --list failure blocks migration" $?
printf '%s\n%s' "$OUT" "$ERR" | grep -q 'pg_restore'; check "message names pg_restore" $?
check_log_keys
[ "$(logf .snapshot_status)" = failed ]; check "log shows failed snapshot" $?

# ---- neon ----
run_case neon-ok --provider neon --target preview --project-id proj-1 --parent main -- "$MCMD" up
check "exit 0" "$RC"
ran_migration; check "migration ran" $?
a=$(line_no '^neonctl'); c=$(line_no '^migrate-cmd')
[ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; check "neonctl before migration" $?
grep -q '^neonctl .*branches create' "$CALLS" && grep -q -- '--project-id proj-1' "$CALLS" && grep -q -- '--parent main' "$CALLS" && grep -q -- '--name pre-migrate-' "$CALLS"
check "neonctl branches create with project, parent, pre-migrate- name" $?
check_log_keys
[ "$(logf .provider)" = neon ] && [ "$(logf .snapshot)" = br-stub-1 ] && [ "$(logf .snapshot_status)" = ok ] && [ "$(logf .migration_status)" = ok ]
check "log records neon branch id as snapshot" $?

STUB_NEON_RC=1 run_case neon-fail --provider neon --target preview --project-id proj-1 --parent main -- "$MCMD"
[ "$RC" -ne 0 ]; check "nonzero exit" $?
! ran_migration; check "migration never ran" $?
printf '%s\n%s' "$OUT" "$ERR" | grep -q 'neonctl'; check "message names neonctl" $?
check_log_keys
[ "$(logf .snapshot_status)" = failed ]; check "log shows failed snapshot" $?

# ---- rds ----
run_case rds-ok --provider rds --target testing --db-instance-identifier db-1 -- "$MCMD" up
check "exit 0" "$RC"
ran_migration; check "migration ran" $?
a=$(line_no '^aws .*create-db-snapshot'); b=$(line_no '^aws .*wait'); c=$(line_no '^migrate-cmd')
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]
check "order create-db-snapshot, wait, migration" $?
grep -q -- '--db-instance-identifier db-1' "$CALLS" && grep -q -- '--db-snapshot-identifier pre-migrate-testing-' "$CALLS"
check "aws args carry instance id and pre-migrate-<target>- snapshot id" $?
grep -q 'wait db-snapshot-available' "$CALLS"; check "aws rds wait db-snapshot-available" $?
check_log_keys
case "$(logf .snapshot)" in pre-migrate-testing-*) rc=0 ;; *) rc=1 ;; esac
check "log snapshot is the snapshot identifier" $rc
[ "$(logf .snapshot_status)" = ok ] && [ "$(logf .migration_status)" = ok ]; check "log statuses ok" $?

STUB_AWS_CREATE_RC=1 run_case rds-create-fail --provider rds --target testing --db-instance-identifier db-1 -- "$MCMD"
[ "$RC" -ne 0 ]; check "nonzero exit" $?
! ran_migration; check "migration never ran" $?
printf '%s\n%s' "$OUT" "$ERR" | grep -q 'create-db-snapshot'; check "message names create-db-snapshot" $?
check_log_keys
[ "$(logf .snapshot_status)" = failed ]; check "log shows failed snapshot" $?

STUB_AWS_WAIT_RC=1 run_case rds-wait-fail --provider rds --target testing --db-instance-identifier db-1 -- "$MCMD"
[ "$RC" -ne 0 ]; check "nonzero exit" $?
! ran_migration; check "wait failure blocks migration" $?
printf '%s\n%s' "$OUT" "$ERR" | grep -q 'wait'; check "message names the wait step" $?
check_log_keys
[ "$(logf .snapshot_status)" = failed ]; check "log shows failed snapshot" $?

# ---- M-4: bad usage exits 2, runs nothing ----
bad() { # name, args...
  local n="$1"; shift
  run_case "bad-$n" "$@"
  [ "$RC" -eq 2 ]; check "exit 2 (got $RC)" $?
  [ ! -s "$CALLS" ]; check "no stub ran" $?
  printf '%s\n%s' "$OUT" "$ERR" | grep -qi 'usage'; check "prints usage" $?
}
bad unknown-provider --provider mysql --target preview -- "$MCMD"
bad no-target --provider neon --project-id p --parent main -- "$MCMD"
bad no-dashdash --provider neon --target preview --project-id p --parent main "$MCMD"
bad no-command --provider neon --target preview --project-id p --parent main --
bad unset-url-env --provider pg --target preview --url-env TEST_DB_URL_NOT_SET_ANYWHERE -- "$MCMD"
bad no-provider --target preview -- "$MCMD"

# ---- review r1 ----
# 1. a failed pg snapshot leaves no dump file behind
STUB_PG_DUMP_RC=1 STUB_PG_DUMP_PARTIAL=1 run_case pg-dump-fail-clean --provider pg --target preview --url-env TEST_DB_URL -- "$MCMD"
[ "$RC" -ne 0 ]; check "nonzero exit" $?
[ -z "$(ls "$BKDIR"/*.dump 2>/dev/null)" ]; check "pg_dump failure leaves no *.dump in backup dir" $?
STUB_PG_RESTORE_RC=1 run_case pg-restore-fail-clean --provider pg --target preview --url-env TEST_DB_URL -- "$MCMD"
[ "$RC" -ne 0 ]; check "nonzero exit" $?
[ -z "$(ls "$BKDIR"/*.dump 2>/dev/null)" ]; check "pg_restore --list failure leaves no *.dump in backup dir" $?

# 2. migration failure: exit 1, migration_status failed, snapshot_status ok
STUB_MIGRATE_RC=1 run_case migrate-fail --provider pg --target preview --url-env TEST_DB_URL -- "$MCMD" up
[ "$RC" -eq 1 ]; check "wrapper exits 1 when the migration exits 1 (got $RC)" $?
ran_migration; check "migration ran" $?
check_log_keys
[ "$(logf .migration_status)" = failed ] && [ "$(logf .snapshot_status)" = ok ]; check "log migration_status failed, snapshot_status ok" $?

# 3. neon returns no branch id: snapshot failed, migration blocked
STUB_NEON_EMPTY=1 run_case neon-no-id --provider neon --target preview --project-id proj-1 --parent main -- "$MCMD"
[ "$RC" -ne 0 ]; check "nonzero exit" $?
! ran_migration; check "migration never ran" $?
check_log_keys
[ "$(logf .snapshot_status)" = failed ]; check "log shows failed snapshot" $?

# 4. SIGTERM during the migration logs "interrupted", one line
CASE=interrupted; CDIR="$WORK/$CASE"; mkdir -p "$CDIR/log" "$CDIR/backup"
CALLS="$CDIR/calls"; : >"$CALLS"; LOGF="$CDIR/log/migrations.jsonl"; BKDIR="$CDIR/backup"
MARK="$CDIR/started"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
  PATH="$BIN:$PATH" STUB_CALLS="$CALLS" STUB_MARKER="$MARK" \
  MIGRATE_LOG_DIR="$CDIR/log" MIGRATE_BACKUP_DIR="$BKDIR" HOME="$CDIR/home" \
  bash "$SCRIPT" --provider pg --target preview --url-env TEST_DB_URL -- "$BIN/migrate-slow" >"$CDIR/out" 2>"$CDIR/err" &
WPID=$!
for _ in $(seq 1 100); do [ -f "$MARK" ] && break; sleep 0.1; done
[ -f "$MARK" ]; check "migration stub started" $?
kill -TERM "$WPID" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$WPID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$WPID" 2>/dev/null; then kill -KILL "$WPID" 2>/dev/null; fail "$CASE: wrapper did not exit after SIGTERM"; fi
wait "$WPID" 2>/dev/null
pkill -f "$BIN/migrate-slow" 2>/dev/null
[ "$(wc -l <"$LOGF" 2>/dev/null | tr -d ' ')" = "1" ]; check "exactly one log line" $?
[ "$(logf .migration_status)" = interrupted ]; check "log migration_status interrupted (got $(logf .migration_status))" $?

# 5. two pg runs for one target in the same second keep both dumps
CASE=pg-twice; CDIR="$WORK/$CASE"; mkdir -p "$CDIR/log" "$CDIR/backup"
CALLS="$CDIR/calls"; : >"$CALLS"; LOGF="$CDIR/log/migrations.jsonl"; BKDIR="$CDIR/backup"
for i in 1 2; do
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    PATH="$BIN:$PATH" STUB_CALLS="$CALLS" \
    MIGRATE_LOG_DIR="$CDIR/log" MIGRATE_BACKUP_DIR="$BKDIR" HOME="$CDIR/home" \
    bash "$SCRIPT" --provider pg --target preview --url-env TEST_DB_URL -- "$MCMD" up >"$CDIR/out$i" 2>"$CDIR/err$i"
done
n=$(ls "$BKDIR"/preview-*.dump 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 2 ]; check "two runs produce two distinct dump files (got $n)" $?

[ "$fails" -eq 0 ] && { echo "PASS: db-migrate-safe"; exit 0; }
echo "FAIL: db-migrate-safe ($fails failures)"
exit 1
