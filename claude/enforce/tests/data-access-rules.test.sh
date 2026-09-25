#!/usr/bin/env bash
# Shard: slow
# Covers: eslint:no-query-in-loop, eslint:transaction-client-required
# Verifies the two data-access rules against the bundled config.
#
# R-361 no-query-in-loop:
#   1. A repository call in a for...of body reports and names the loop.
#   2. Promise.all(ids.map(repo call)) reports: parallel N+1 is still N+1.
#   3. The pool wrapper's query() inside a while loop reports.
#   4. client.query in a .forEach callback reports.
#   5. The iterable of a for...of runs once and passes.
#   6. A single set query (WHERE id = ANY) followed by an in-memory map passes.
#   7. A call to a function that is not data access, inside a loop, passes.
#   8. A helper declared outside the loop is not followed (documented limit).
#   9. An eslint-disable-next-line comment with a reason silences a bounded loop.
#  10. Test files are exempt.
#
# R-362 transaction-client-required:
#  11. query() inside withTransaction without the client reports.
#  12. A repository call inside withTransaction without the client reports.
#  13. pool.query inside withTransaction reports.
#  14. A callback with no client parameter reports every data-access call.
#  15. fetch() and a clients/ call inside withTransaction report.
#  16. client.query, query(sql, values, client), repo(input, client), and
#      repo({ client, input }) all pass.
#  17. A repository call outside any transaction passes.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
E="$CLAUDE_HARNESS_ROOT/enforce"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
mkdir -p src/services/__tests__ src/repositories src/workers

LAST_REPORT=""
lint() { LAST_REPORT=$(node "$E/lint.mjs" "$TMP/$1" 2>&1 || true); }
expect_report() {
  lint "$1"
  grep -q "$2" <<< "$LAST_REPORT" || { echo "FAIL: $3"; echo "--- report ---"; printf '%s\n' "$LAST_REPORT"; exit 1; }
}
expect_clean() {
  lint "$1"
  # A crashed or unparsable lint also contains no rule ID; refuse to read that as clean.
  if grep -qE 'Parsing error|Error \[|Cannot find module' <<< "$LAST_REPORT"; then echo "FAIL: $3 (lint did not run)"; printf '%s\n' "$LAST_REPORT"; exit 1; fi
  if grep -q "$2" <<< "$LAST_REPORT"; then echo "FAIL: $3"; echo "--- report ---"; printf '%s\n' "$LAST_REPORT"; exit 1; fi
}

# --- R-361 -----------------------------------------------------------------
cat > src/services/loopRepo.ts <<'TS'
import * as jobsRepository from "../repositories/jobs.js";

export async function listJobs(jobIds: string[]) {
  const jobs = [];
  for (const jobId of jobIds) {
    jobs.push(await jobsRepository.getJobById(jobId));
  }
  return jobs;
}
TS
expect_report src/services/loopRepo.ts 'R-361' "1: a repository call in a for...of body must report"
grep -q 'jobsRepository.getJobById' <<< "$LAST_REPORT" || { echo "FAIL: 1: the report must name the callee"; exit 1; }
grep -q 'for...of loop' <<< "$LAST_REPORT" || { echo "FAIL: 1: the report must name the loop"; exit 1; }

cat > src/services/parallelMap.ts <<'TS'
import { getJobById } from "../repositories/jobs.js";

export async function listJobs(jobIds: string[]) {
  return Promise.all(jobIds.map((jobId) => getJobById(jobId)));
}
TS
expect_report src/services/parallelMap.ts 'R-361' "2: Promise.all over a .map of repository calls must report"
grep -q '.map() callback' <<< "$LAST_REPORT" || { echo "FAIL: 2: the report must name the .map() callback"; exit 1; }

cat > src/repositories/whileQuery.ts <<'TS'
import { query } from "../database/pool.js";

export async function drainQueue(queueIds: string[]) {
  while (queueIds.length > 0) {
    await query(`DELETE FROM queue WHERE id = $1`, [queueIds.pop()]);
  }
}
TS
expect_report src/repositories/whileQuery.ts 'R-361' "3: query() in a while loop must report"

cat > src/repositories/forEachClient.ts <<'TS'
import type { PoolClient } from "pg";

export function touchJobs(client: PoolClient, jobIds: string[]) {
  jobIds.forEach((jobId) => {
    void client.query(`UPDATE jobs SET updated_at = NOW() WHERE id = $1`, [jobId]);
  });
}
TS
expect_report src/repositories/forEachClient.ts 'R-361' "4: client.query in a .forEach callback must report"

cat > src/services/iterableOnce.ts <<'TS'
import { listJobsForUser } from "../repositories/jobs.js";

export async function countOpen(userId: string) {
  let open = 0;
  for (const job of await listJobsForUser(userId)) {
    if (job.status === "open") open += 1;
  }
  return open;
}
TS
expect_clean src/services/iterableOnce.ts 'R-361' "5: the iterable of a for...of runs once and must not report"

cat > src/services/setQuery.ts <<'TS'
import { query } from "../database/pool.js";

export async function listJobs(jobIds: string[]) {
  const result = await query(`SELECT * FROM jobs WHERE id = ANY($1::uuid[])`, [jobIds]);
  const jobsById = new Map(result.rows.map((row) => [row.id, row]));
  return jobIds.map((jobId) => jobsById.get(jobId));
}
TS
expect_clean src/services/setQuery.ts 'R-361' "6: one set query then an in-memory map must not report"

cat > src/services/pureLoop.ts <<'TS'
import { formatTitle } from "./formatTitle.js";

export function formatAll(titles: string[]) {
  return titles.map((title) => formatTitle(title));
}
TS
expect_clean src/services/pureLoop.ts 'R-361' "7: a non-data-access call in a loop must not report"

cat > src/services/helperOutside.ts <<'TS'
import { getJobById } from "../repositories/jobs.js";

async function loadJob(jobId: string) {
  return getJobById(jobId);
}

export async function listJobs(jobIds: string[]) {
  const jobs = [];
  for (const jobId of jobIds) jobs.push(await loadJob(jobId));
  return jobs;
}
TS
expect_clean src/services/helperOutside.ts 'R-361' "8: a helper declared outside the loop is a documented limit and must not report"

cat > src/workers/batch.ts <<'TS'
import { query } from "../database/pool.js";

export async function backfill(batchSize: number) {
  let cursor = "";
  for (;;) {
    // eslint-disable-next-line dataAccess/no-query-in-loop -- keyset batching, one query per batchSize rows
    const result = await query(`SELECT id FROM jobs WHERE id > $1 ORDER BY id LIMIT $2`, [cursor, batchSize]);
    if (result.rows.length === 0) return;
    cursor = result.rows[result.rows.length - 1].id;
  }
}
TS
expect_clean src/workers/batch.ts 'R-361' "9: a disable comment with a reason must silence a bounded loop"

cat > src/services/__tests__/loop.test.ts <<'TS'
import { getJobById } from "../../repositories/jobs.js";

export async function seed(jobIds: string[]) {
  for (const jobId of jobIds) await getJobById(jobId);
}
TS
expect_clean src/services/__tests__/loop.test.ts 'R-361' "10: test files are exempt"

# --- R-362 -----------------------------------------------------------------
cat > src/repositories/txNoClient.ts <<'TS'
import { query, withTransaction } from "../database/pool.js";

export async function moveJob(jobId: string, boardId: string) {
  return withTransaction(async (client) => {
    await client.query(`UPDATE jobs SET board_id = $2 WHERE id = $1`, [jobId, boardId]);
    await query(`UPDATE boards SET updated_at = NOW() WHERE id = $1`, [boardId]);
  });
}
TS
expect_report src/repositories/txNoClient.ts 'R-362' "11: query() without the client inside withTransaction must report"
grep -q 'does not receive `client`' <<< "$LAST_REPORT" || { echo "FAIL: 11: the report must name the client parameter"; exit 1; }

cat > src/services/txRepo.ts <<'TS'
import { withTransaction } from "../database/pool.js";
import * as boardsRepository from "../repositories/boards.js";
import * as jobsRepository from "../repositories/jobs.js";

export async function moveJob(jobId: string, boardId: string) {
  return withTransaction(async (client) => {
    await jobsRepository.updateJobBoard(jobId, boardId, client);
    await boardsRepository.touchBoard(boardId);
  });
}
TS
expect_report src/services/txRepo.ts 'boardsRepository.touchBoard' "12: a repository call without the client inside withTransaction must report"
if grep -q 'jobsRepository.updateJobBoard' <<< "$LAST_REPORT"; then echo "FAIL: 12: a repository call passing the client must not report"; exit 1; fi

cat > src/repositories/txPool.ts <<'TS'
import { pool, withTransaction } from "../database/pool.js";

export async function archiveJob(jobId: string) {
  return withTransaction(async (client) => {
    await client.query(`UPDATE jobs SET is_archived = true WHERE id = $1`, [jobId]);
    await pool.query(`INSERT INTO audit_events (job_id) VALUES ($1)`, [jobId]);
  });
}
TS
expect_report src/repositories/txPool.ts 'pool.query' "13: pool.query inside withTransaction must report"

cat > src/repositories/txNoParam.ts <<'TS'
import { query, withTransaction } from "../database/pool.js";

export async function archiveJob(jobId: string) {
  return withTransaction(async () => {
    await query(`UPDATE jobs SET is_archived = true WHERE id = $1`, [jobId]);
  });
}
TS
expect_report src/repositories/txNoParam.ts 'declares no client parameter' "14: a callback with no client parameter must report"

cat > src/services/txNetwork.ts <<'TS'
import * as emailClient from "../clients/email.js";
import { withTransaction } from "../database/pool.js";
import * as jobsRepository from "../repositories/jobs.js";

export async function applyToJob(jobId: string, userEmail: string) {
  return withTransaction(async (client) => {
    await jobsRepository.markApplied(jobId, client);
    await fetch("https://example.test/hook");
    await emailClient.sendApplicationEmail(userEmail);
  });
}
TS
expect_report src/services/txNetwork.ts 'fetch(...)` waits on the network' "15: fetch inside withTransaction must report"
expect_report src/services/txNetwork.ts 'emailClient.sendApplicationEmail' "15: a clients/ call inside withTransaction must report"

cat > src/services/txClean.ts <<'TS'
import { query, withTransaction } from "../database/pool.js";
import * as jobsRepository from "../repositories/jobs.js";

export async function moveJob(jobId: string, boardId: string) {
  return withTransaction(async (client) => {
    await client.query(`UPDATE jobs SET board_id = $2 WHERE id = $1`, [jobId, boardId]);
    await query(`UPDATE boards SET updated_at = NOW() WHERE id = $1`, [boardId], client);
    await jobsRepository.touchJob(jobId, client);
    await jobsRepository.logMove({ boardId, client, jobId });
  });
}
TS
expect_clean src/services/txClean.ts 'R-362' "16: every call carrying the client must pass"

cat > src/services/noTx.ts <<'TS'
import * as jobsRepository from "../repositories/jobs.js";

export async function getJob(jobId: string) {
  return jobsRepository.getJobById(jobId);
}
TS
expect_clean src/services/noTx.ts 'R-36' "17: a repository call outside any transaction or loop must pass"

echo "PASS: data-access-rules (R-361 no-query-in-loop, R-362 transaction-client-required)"
