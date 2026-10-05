#!/usr/bin/env bash
# db-migrate-safe.sh: takes a restorable snapshot of a database, then runs a
# migration command only when the snapshot succeeded
# (docs/specs/2026-10-05-migrate-backup.md, M-1 to M-4).
#
#   db-migrate-safe.sh --provider pg|neon|rds --target NAME [provider options] -- CMD...
#     pg:   --url-env VAR [--backup-dir DIR]
#           pg_dump --format=custom of the database whose URL is in $VAR to
#           DIR/NAME-<UTC timestamp>.dump (mode 0600), then pg_restore --list
#     neon: --project-id ID --parent BRANCH
#           neonctl branches create --name pre-migrate-<UTC timestamp>
#     rds:  --db-instance-identifier ID
#           aws rds create-db-snapshot, then aws rds wait db-snapshot-available
#
# Every run past usage checks appends one JSON line to
# ${MIGRATE_LOG_DIR:-$HOME/.local/state/agent-migrations}/migrations.jsonl,
# also when the snapshot fails. The database URL is read from the named
# variable only; it is never printed or logged.
# Exit: 2 bad usage (nothing runs); 1 snapshot failed (the migration never
# starts); otherwise the migration command's exit status.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDACTOR="$SCRIPT_DIR/../hooks/infra_judge.py"

usage() {
  [ -n "${1:-}" ] && echo "db-migrate-safe: $1" >&2
  cat >&2 <<'EOF'
usage: db-migrate-safe.sh --provider pg|neon|rds --target NAME [provider options] -- CMD...
  pg:   --url-env VAR [--backup-dir DIR]   (VAR holds the database URL; its name, never its value)
  neon: --project-id ID --parent BRANCH
  rds:  --db-instance-identifier ID
EOF
  exit 2
}

provider="" target="" url_env="" backup_dir="" project_id="" parent="" instance_id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    --provider|--target|--url-env|--backup-dir|--project-id|--parent|--db-instance-identifier)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case "$1" in
        --provider) provider="$2" ;;
        --target) target="$2" ;;
        --url-env) url_env="$2" ;;
        --backup-dir) backup_dir="$2" ;;
        --project-id) project_id="$2" ;;
        --parent) parent="$2" ;;
        --db-instance-identifier) instance_id="$2" ;;
      esac
      shift 2 ;;
    *) usage "unknown argument: $1 (the migration command goes after --)" ;;
  esac
done
[ $# -gt 0 ] || usage "no migration command after --"

case "$provider" in
  pg|neon|rds) ;;
  "") usage "--provider is required" ;;
  *) usage "unknown provider: $provider" ;;
esac
[ -n "$target" ] || usage "--target is required"
# The target names the dump file and the snapshot id, so it stays a plain name.
[[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage "--target must be letters, digits, '.', '_' or '-'"
url=""
case "$provider" in
  pg)
    [ -n "$url_env" ] || usage "pg needs --url-env VAR"
    [[ "$url_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage "--url-env takes a variable name"
    url="${!url_env:-}"
    [ -n "$url" ] || usage "--url-env names $url_env, which is unset or empty"
    backup_dir="${backup_dir:-${MIGRATE_BACKUP_DIR:-${HOME:-}/.local/state/agent-migrations/backups}}"
    ;;
  neon)
    [ -n "$project_id" ] && [ -n "$parent" ] || usage "neon needs --project-id ID and --parent BRANCH" ;;
  rds)
    [ -n "$instance_id" ] || usage "rds needs --db-instance-identifier ID" ;;
esac

log_dir="${MIGRATE_LOG_DIR:-${HOME:-}/.local/state/agent-migrations}"
mkdir -p "$log_dir" || { echo "db-migrate-safe: cannot create log directory $log_dir; nothing ran" >&2; exit 1; }
stamp=$(date -u +%Y%m%dT%H%M%SZ)
rds_stamp=$(date -u +%Y%m%d-%H%M%S)

# scrub: prints stdin with the URL value and URL credentials removed.
scrub() {
  local text
  text=$(cat)
  [ -n "$url" ] && text="${text//"$url"/***}"
  printf '%s\n' "$text" | sed -E 's#(://[^/[:space:]:@]*:)[^@/[:space:]]*@#\1***@#g'
}

snapshot="" snapshot_status="failed" migration_status="skipped" failed_step=""

# run_step: runs a provider step, keeps its stdout in step_out, and on failure
# records the step and prints its scrubbed stderr.
run_step() { # step-name, command...
  local name="$1" err_file rc
  shift
  err_file=$(mktemp) || { failed_step="$name (mktemp)"; return 1; }
  step_out=$("$@" 2>"$err_file")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    failed_step="$name exited $rc"
    scrub <"$err_file" >&2
  fi
  rm -f "$err_file"
  return "$rc"
}

take_snapshot() {
  case "$provider" in
    pg)
      mkdir -p "$backup_dir" || { failed_step="mkdir $backup_dir"; return 1; }
      snapshot="$backup_dir/$target-$stamp-$$.dump"
      run_step pg_dump pg_dump --format=custom --file="$snapshot" --dbname="$url" || { rm -f "$snapshot"; return 1; }
      chmod 600 "$snapshot" 2>/dev/null
      run_step "pg_restore --list" pg_restore --list "$snapshot" || { rm -f "$snapshot"; return 1; }
      ;;
    neon)
      run_step "neonctl branches create" neonctl branches create --project-id "$project_id" \
        --parent "$parent" --name "pre-migrate-$stamp" --output json || return 1
      snapshot=$(printf '%s' "$step_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["branch"]["id"])' 2>/dev/null)
      [ -n "$snapshot" ] || { failed_step="neonctl branches create printed no branch id"; return 1; }
      ;;
    rds)
      # RDS identifiers allow letters, digits and single hyphens only.
      rds_target=$(printf '%s' "$target" | tr '._' '--' | sed -E 's/-+/-/g')
      snapshot="pre-migrate-$rds_target-$rds_stamp-$$"
      run_step "aws rds create-db-snapshot" aws rds create-db-snapshot --db-instance-identifier "$instance_id" \
        --db-snapshot-identifier "$snapshot" || return 1
      run_step "aws rds wait db-snapshot-available" aws rds wait db-snapshot-available \
        --db-snapshot-identifier "$snapshot" || return 1
      ;;
  esac
}

# write_log: appends the run's JSON line; the command is redacted the way the
# infra guard redacts command text, and the URL value is removed outright.
write_log() {
  MIGRATE_URL_VALUE="$url" python3 - "$REDACTOR" "$log_dir/migrations.jsonl" \
    "$provider" "$target" "$snapshot" "$snapshot_status" "$migration_status" "$@" <<'PY'
import datetime, importlib.util, json, os, re, shlex, sys
redactor, log_path, provider, target, snapshot, snapshot_status, migration_status = sys.argv[1:8]
command = shlex.join(sys.argv[8:])
url = os.environ.get("MIGRATE_URL_VALUE", "")
if url:
    command = command.replace(url, "***").replace(shlex.quote(url), "***")
try:
    spec = importlib.util.spec_from_file_location("infra_judge", redactor)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    command = module.redact(command)
except Exception:
    command = re.sub(r"(://[^/\s:@]*:)[^@/\s]*@", r"\1***@", command)
line = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "provider": provider, "target": target, "snapshot": snapshot, "command": command,
        "snapshot_status": snapshot_status, "migration_status": migration_status}
with open(log_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(line) + "\n")
PY
}

if take_snapshot; then
  snapshot_status="ok"
else
  echo "db-migrate-safe: snapshot failed ($provider: $failed_step); the migration was not run" >&2
  write_log "$@" || echo "db-migrate-safe: could not write $log_dir/migrations.jsonl" >&2
  exit 1
fi
echo "db-migrate-safe: snapshot ok ($provider: $snapshot)" >&2

interrupted=0
"$@" <&0 &
child=$!
trap 'interrupted=1; kill -TERM "$child" 2>/dev/null' TERM INT HUP
wait "$child"
rc=$?
if [ "$interrupted" -eq 1 ]; then
  wait "$child" 2>/dev/null
  rc=$?
fi
trap - TERM INT HUP
if [ "$interrupted" -eq 1 ]; then
  migration_status="interrupted"
  [ "$rc" -eq 0 ] && rc=143
elif [ "$rc" -eq 0 ]; then
  migration_status="ok"
else
  migration_status="failed"
fi
write_log "$@" || { echo "db-migrate-safe: could not write $log_dir/migrations.jsonl" >&2; [ "$rc" -eq 0 ] && rc=1; }
exit "$rc"
