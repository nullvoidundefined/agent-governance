#!/usr/bin/env bash
# Covers: hook:push-ruff-gate
# Verifies the Python data-access checker (enforce/data-access/python_data_access.py)
# directly, then once end to end through push-ruff-gate.sh.
#
# R-361 (N+1):
#   1. A repository call in a for body reports and names the loop.
#   2. A repository call in an async for body reports.
#   3. A repository call in a list comprehension reports.
#   4. asyncio.gather over a generator of repository calls reports.
#   5. connection.execute in a while body reports; a map() lambda reports.
#   6. The iterable of a for runs once and passes.
#   7. One set query (= ANY) then a dict comprehension over its rows passes.
#   8. A call that is not data access, inside a loop, passes.
#   9. A helper defined elsewhere and called in a loop is not followed.
#  10. data-access-allow with a reason suppresses; without a reason it still reports.
#  11. A test path is exempt.
# R-362 (explicit begin/begin_nested blocks):
#  12. httpx inside begin() reports.
#  13. A clients/ call inside begin_nested() reports.
#  14. A repository call inside begin() as connection without it reports.
#  15. The same calls given the connection pass, including begin_nested on the
#      connection with a savepoint name bound, and the get_connection dependency.
# Robustness and wiring:
#  16. An unparsable file is skipped without a crash; bad usage exits 2.
#  17. The gate denies a pushed N+1 line with ruff stubbed, allows the fixed
#      line, scopes to added lines, fails open without python3 while ruff still
#      runs, and still runs the checker when ruff is unavailable.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
CHECKER="$CLAUDE_HARNESS_ROOT/enforce/data-access/python_data_access.py"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-ruff-gate.sh"
export CLAUDE_FIRE_LOG=/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
mkdir -p app/services app/repositories app/workers tests/services

LAST_REPORT=""
# Every check runs the checker and demands a JSON array: a crash, a traceback,
# or empty output fails the fixture instead of reading as "no findings".
check() {
  local status=0
  LAST_REPORT=$(python3 "$CHECKER" "$1" 2>&1) || status=$?
  if [ "$status" -ne 0 ] || ! printf '%s' "$LAST_REPORT" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "FAIL: the checker did not run cleanly on $1 (exit $status)"; printf '%s\n' "$LAST_REPORT"; exit 1
  fi
}
expect_report() {
  check "$1"
  printf '%s' "$LAST_REPORT" | jq -e --arg rule "$2" --argjson line "$3" 'any(.[]; .rule == $rule and .line == $line)' >/dev/null \
    || { echo "FAIL: $4"; printf '%s\n' "$LAST_REPORT"; exit 1; }
}
expect_clean() {
  check "$1"
  printf '%s' "$LAST_REPORT" | jq -e 'length == 0' >/dev/null || { echo "FAIL: $2"; printf '%s\n' "$LAST_REPORT"; exit 1; }
}

# --- R-361 ------------------------------------------------------------------
cat > app/services/for_body.py <<'PY'
from app.repositories import trips as trips_repository


async def list_trips(connection, trip_ids):
    trips = []
    for trip_id in trip_ids:
        trips.append(await trips_repository.get_trip(connection, trip_id))
    return trips
PY
expect_report app/services/for_body.py R-361 7 "1: a repository call in a for body must report"
grep -q 'trips_repository.get_trip' <<< "$LAST_REPORT" || { echo "FAIL: 1: the report must name the callee"; exit 1; }
grep -q 'for loop' <<< "$LAST_REPORT" || { echo "FAIL: 1: the report must name the loop"; exit 1; }

cat > app/services/async_for.py <<'PY'
from app.repositories.legs import list_legs


async def collect(connection, trip_stream):
    async for trip in trip_stream:
        await list_legs(connection, trip.id)
PY
expect_report app/services/async_for.py R-361 6 "2: a repository call in an async for body must report"

cat > app/services/comprehension.py <<'PY'
from app.repositories.legs import list_legs


async def collect(connection, trip_ids):
    return [await list_legs(connection, trip_id) for trip_id in trip_ids]
PY
expect_report app/services/comprehension.py R-361 5 "3: a repository call in a list comprehension must report"

cat > app/services/gather.py <<'PY'
import asyncio

import app.repositories.trips


async def collect(connection, trip_ids):
    return await asyncio.gather(*(app.repositories.trips.get_trip(connection, trip_id) for trip_id in trip_ids))
PY
expect_report app/services/gather.py R-361 7 "4: asyncio.gather over a generator of repository calls must report"

cat > app/repositories/drain.py <<'PY'
from app.repositories.legs import list_legs


async def drain(connection, statements, trip_ids):
    while statements:
        await connection.execute(statements.pop())
    return list(map(lambda trip_id: list_legs(connection, trip_id), trip_ids))
PY
expect_report app/repositories/drain.py R-361 6 "5: connection.execute in a while body must report"
expect_report app/repositories/drain.py R-361 7 "5: a repository call in a map() lambda must report"

cat > app/services/iterable_once.py <<'PY'
from app.repositories.trips import list_trips_for_user


async def count_open(connection, user_id):
    open_count = 0
    for trip in await list_trips_for_user(connection, user_id):
        if trip.status == "open":
            open_count += 1
    return open_count
PY
expect_clean app/services/iterable_once.py "6: the iterable of a for runs once and must pass"

cat > app/repositories/set_query.py <<'PY'
from sqlalchemy import text

from app.db.tables import trips_table


async def trips_by_id(connection, trip_ids):
    statement = text("SELECT * FROM trips WHERE id = ANY(:trip_ids)")
    rows = (await connection.execute(statement, {"trip_ids": trip_ids})).mappings().all()
    columns = [trips_table.c[name] for name in ("id", "title")]
    by_id = {row["id"]: row for row in rows}
    return [by_id.get(trip_id) for trip_id in trip_ids], columns
PY
expect_clean app/repositories/set_query.py "7: one set query then a dict comprehension over its rows must pass"

cat > app/services/pure_loop.py <<'PY'
from app.services.formatting import format_title


def format_all(titles, result):
    names = [format_title(title) for title in titles]
    for row in titles:
        result.scalars()
    return names
PY
expect_clean app/services/pure_loop.py "8: a non-data-access call in a loop must pass"

cat > app/services/helper_outside.py <<'PY'
from app.repositories.trips import get_trip


async def load_trip(connection, trip_id):
    return await get_trip(connection, trip_id)


async def list_trips(connection, trip_ids):
    return [await load_trip(connection, trip_id) for trip_id in trip_ids]
PY
expect_clean app/services/helper_outside.py "9: a helper defined elsewhere is a documented limit and must pass"

cat > app/workers/batch.py <<'PY'
from app.repositories.trips import list_trip_batch


async def backfill(connection, batch_size):
    cursor = None
    while True:
        # data-access-allow: keyset batching, one query per batch_size rows
        rows = await list_trip_batch(connection, cursor, batch_size)
        if not rows:
            return
        cursor = rows[-1].id
PY
expect_clean app/workers/batch.py "10: a data-access-allow comment with a reason must suppress"

cat > app/workers/batch_no_reason.py <<'PY'
from app.repositories.trips import list_trip_batch


async def backfill(connection, cursors):
    for cursor in cursors:
        await list_trip_batch(connection, cursor)  # data-access-allow:
PY
expect_report app/workers/batch_no_reason.py R-361 6 "10: a data-access-allow comment without a reason must not suppress"

cp app/services/for_body.py tests/services/test_trips.py
expect_clean tests/services/test_trips.py "11: a test path must be exempt"

# --- R-362 ------------------------------------------------------------------
cat > app/services/tx_http.py <<'PY'
import httpx

from app.repositories import trips as trips_repository


async def archive(engine, trip_id):
    async with engine.begin() as connection:
        await trips_repository.archive_trip(connection, trip_id)
        await httpx.post("https://example.test/hook", json={"trip_id": str(trip_id)})
PY
expect_report app/services/tx_http.py R-362 9 "12: httpx inside begin() must report"
grep -q 'httpx.post' <<< "$LAST_REPORT" || { echo "FAIL: 12: the report must name the network call"; exit 1; }

cat > app/services/tx_clients.py <<'PY'
from app.clients import email as email_client
from app.repositories import trips as trips_repository


async def share(connection, trip_id, address):
    async with connection.begin_nested():
        await trips_repository.mark_shared(connection, trip_id)
        await email_client.send_share_email(address)
PY
expect_report app/services/tx_clients.py R-362 8 "13: a clients/ call inside begin_nested() must report"

cat > app/workers/tx_no_connection.py <<'PY'
from app.repositories import trips as trips_repository


async def close_trip(ctx, trip_id):
    async with ctx["engine"].begin() as connection:
        await trips_repository.close_trip(connection, trip_id)
        await trips_repository.log_closure(trip_id)
PY
expect_report app/workers/tx_no_connection.py R-362 7 "14: a repository call without the connection inside begin() as connection must report"
if printf '%s' "$LAST_REPORT" | jq -e 'any(.[]; .line == 6)' >/dev/null; then echo "FAIL: 14: the call passing the connection must not report"; exit 1; fi

cat > app/workers/tx_clean.py <<'PY'
from fastapi import Request

from app.repositories import trips as trips_repository
from app.repositories.trips import TripsRepository


async def get_connection(request: Request):
    async with request.app.state.engine.begin() as connection:
        yield connection


async def close_trip(ctx, trip_id, user_id):
    async with ctx["engine"].begin() as connection:
        await trips_repository.close_trip(connection, trip_id)
        await trips_repository.log_closure(trip_id=trip_id, connection=connection)
        await connection.execute(trips_repository.touch_statement(connection, trip_id))
        repository = TripsRepository(connection, user_id)
        await repository.insert_trip(trip_id)


async def rename(connection, trip_id, title):
    async with connection.begin_nested() as savepoint:
        await trips_repository.rename_trip(connection, trip_id, title)
        await connection.execute(trips_repository.touch_statement(connection, trip_id))
        if not title:
            await savepoint.rollback()
PY
expect_clean app/workers/tx_clean.py "15: calls that carry the connection, and the get_connection dependency, must pass"

# --- Robustness ---------------------------------------------------------------
printf 'def broken(:\n    pass\n' > app/services/broken.py
expect_clean app/services/broken.py "16: an unparsable file must be skipped, not crash"
check_multi=$(python3 "$CHECKER" app/services/broken.py app/services/for_body.py)
printf '%s' "$check_multi" | jq -e 'length == 1 and .[0].file == "app/services/for_body.py"' >/dev/null \
  || { echo "FAIL: 16: an unparsable file must not hide findings in the next file; got: $check_multi"; exit 1; }
usage_status=0
python3 "$CHECKER" >/dev/null 2>&1 || usage_status=$?
[ "$usage_status" -eq 2 ] || { echo "FAIL: 16: no arguments must exit 2, got $usage_status"; exit 1; }

# --- The gate, end to end ------------------------------------------------------
# A stub ruff that reports nothing keeps this case independent of whether ruff
# is installed; a second stub reports one finding so the python3-missing case
# can prove ruff still ran.
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\necho "[]"\n' > "$STUBS/ruff-clean"
cat > "$STUBS/ruff-finding" <<'SH'
#!/usr/bin/env bash
printf '[{"filename":"%s/app/services/loop.py","location":{"row":1},"code":"E999","message":"stub finding"}]\n' "$PWD"
SH
chmod +x "$STUBS/ruff-clean" "$STUBS/ruff-finding"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

REPO="$TMP/repo"; mkdir -p "$REPO/app/services"; cd "$REPO"
git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git config user.email t@t && git config user.name t
git commit -q --allow-empty -m init

cat > app/services/loop.py <<'PY'
from app.repositories import trips as trips_repository


async def list_trips(connection, trip_ids):
    return [await trips_repository.get_trip(connection, trip_id) for trip_id in trip_ids]
PY
git add -A; git commit -q -m n-plus-one
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_RUFF_CMD="$STUBS/ruff-clean" CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || { echo "FAIL: 17: the gate must deny an added N+1 line; got: $OUT"; exit 1; }
grep -q 'app/services/loop.py:5 R-361' <<< "$OUT" || { echo "FAIL: 17: the denial must read path:line R-361; got: $OUT"; exit 1; }

cat > app/services/loop.py <<'PY'
from app.repositories import trips as trips_repository


async def list_trips(connection, trip_ids):
    return await trips_repository.list_trips_by_ids(connection, trip_ids)
PY
git add -A; git commit -q -m set-query
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_RUFF_CMD="$STUBS/ruff-clean" CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: 17: the set-query fix must pass the gate; got: $OUT"; exit 1; }

# Pre-existing N+1 on an untouched line plus a clean added line passes.
cat > app/services/legacy.py <<'PY'
from app.repositories.legs import list_legs


async def legacy(connection, trip_ids):
    return [await list_legs(connection, trip_id) for trip_id in trip_ids]
PY
git add -A; git commit -q -m legacy
printf '\n\ndef fresh():\n    return None\n' >> app/services/legacy.py
git add -A; git commit -q -m clean-addition
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_RUFF_CMD="$STUBS/ruff-clean" CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: 17: an N+1 on a line the diff does not add must not deny; got: $OUT"; exit 1; }

# No python3: the checker is skipped with a note, and ruff still runs and denies.
git rm -q app/services/loop.py; git commit -q -m drop
cat > app/services/loop.py <<'PY'
from app.repositories import trips as trips_repository


async def list_trips(connection, trip_ids):
    return [await trips_repository.get_trip(connection, trip_id) for trip_id in trip_ids]
PY
git add -A; git commit -q -m n-plus-one-again
ERR="$TMP/stderr"
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PYTHON_CMD=no-such-python3 CLAUDE_RUFF_CMD="$STUBS/ruff-finding" CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>"$ERR")
grep -q 'no python3 on PATH' "$ERR" || { echo "FAIL: 17: a missing python3 must leave a stderr note"; cat "$ERR"; exit 1; }
grep -q 'E999' <<< "$OUT" || { echo "FAIL: 17: ruff must still run without python3; got: $OUT"; exit 1; }
if grep -q 'loop.py:5 R-361' <<< "$OUT"; then echo "FAIL: 17: the checker must be skipped without python3"; exit 1; fi

# No ruff: the checker still runs. PATH keeps only directories without ruff or
# uvx; when that also drops a tool the gate needs, the case is skipped with a
# note instead of failing for a reason unrelated to the gate.
NO_RUFF_PATH=""
OLD_IFS=$IFS; IFS=:
for dir in $PATH; do
  [ -x "$dir/ruff" ] || [ -x "$dir/uvx" ] && continue
  NO_RUFF_PATH="${NO_RUFF_PATH:+$NO_RUFF_PATH:}$dir"
done
IFS=$OLD_IFS
if PATH="$NO_RUFF_PATH" command -v python3 >/dev/null 2>&1 && PATH="$NO_RUFF_PATH" command -v jq >/dev/null 2>&1 \
  && PATH="$NO_RUFF_PATH" command -v git >/dev/null 2>&1; then
  OUT=$(printf '%s' "$PAYLOAD" | env -u CLAUDE_RUFF_CMD PATH="$NO_RUFF_PATH" CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>"$ERR")
  grep -q 'no ruff or uvx' "$ERR" || { echo "FAIL: 17: a missing ruff must leave a stderr note"; cat "$ERR"; exit 1; }
  grep -q 'app/services/loop.py:5 R-361' <<< "$OUT" || { echo "FAIL: 17: the checker must still run without ruff; got: $OUT"; exit 1; }
else
  echo "note: skipped the missing-ruff case (python3, jq, or git share a directory with ruff on this PATH)"
fi

echo "PASS: data-access-python (R-361 and R-362 checker, push-ruff-gate wiring)"
