#!/usr/bin/env node
// feedback.mjs: the resolve-user-feedback skill's retrieval and close steps
// (2026-09-17 skills audit, S-7), so the model never composes SQL against a
// managed database. `list` runs the skill's open-feedback SELECT and prints
// the Step 1 table; `close` runs the parameterized UPDATE for the given ids
// and refuses without --confirm (R-101: a write to a managed or remote
// database needs explicit confirmation in the current turn). Table and
// column names are validated identifiers passed as options, since every
// project names them differently; the SQL is composed from those and from
// bound parameters only.
//
// Usage:
//   feedback.mjs list  [--table app_feedback] [--status-col status] [--dry-run]
//   feedback.mjs close <id...> [--table app_feedback] [--status-col status] --confirm [--dry-run]
// Connection: DATABASE_URL from the environment, else from ./.env (parsed
// here, no dotenv dependency). The `pg` package resolves from the project's
// own node_modules, the same one its server uses. --dry-run prints the SQL
// and parameters and connects to nothing.
// Exit codes: 0 done; 2 usage or invalid identifier; 3 close without
// --confirm; 4 no DATABASE_URL; 5 pg not installed in the project; 6 query
// failed.
import { readFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const IDENT = /^[a-z_][a-z0-9_]*$/;
const args = process.argv.slice(2);
const command = args.shift();
const options = { table: "app_feedback", statusCol: "status", confirm: false, dryRun: false };
const ids = [];
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === "--table") { options.table = args[++i] ?? ""; continue; }
  if (arg === "--status-col") { options.statusCol = args[++i] ?? ""; continue; }
  if (arg === "--confirm") { options.confirm = true; continue; }
  if (arg === "--dry-run") { options.dryRun = true; continue; }
  if (arg.startsWith("--")) { usage(`unknown option ${arg}`); }
  ids.push(arg);
}

function usage(reason) {
  if (reason) console.error(`feedback: ${reason}`);
  console.error("usage: feedback.mjs list [--table t] [--status-col c] [--dry-run] | close <id...> [--table t] [--status-col c] --confirm [--dry-run]");
  process.exit(2);
}
if (command !== "list" && command !== "close") usage(command ? `unknown command ${command}` : "missing command");
for (const [name, value] of [["table", options.table], ["status column", options.statusCol]]) {
  if (!IDENT.test(value)) usage(`${name} '${value}' is not a plain identifier (letters, digits, underscore)`);
}
if (command === "close") {
  if (ids.length === 0) usage("close needs at least one id");
  for (const id of ids) if (!/^\d+$/.test(id)) usage(`id '${id}' is not an integer`);
}

// The SQL, composed only from validated identifiers; values are bound.
const sql = command === "list"
  ? `SELECT id, type, description, page_url, created_at FROM ${options.table} WHERE ${options.statusCol} = $1 ORDER BY created_at DESC`
  : `UPDATE ${options.table} SET ${options.statusCol} = $1 WHERE id = ANY($2::int[]) RETURNING id, type, ${options.statusCol}`;
const params = command === "list" ? ["open"] : ["closed", ids.map(Number)];

function loadDatabaseUrl() {
  if (process.env.DATABASE_URL) return process.env.DATABASE_URL;
  const envPath = path.resolve(process.cwd(), ".env");
  if (!existsSync(envPath)) return "";
  for (const line of readFileSync(envPath, "utf8").split("\n")) {
    const match = /^\s*(?:export\s+)?DATABASE_URL\s*=\s*(.*)\s*$/.exec(line);
    if (match) return match[1].replace(/^["']|["']$/g, "");
  }
  return "";
}

// The host only, never the credentials, for the confirmation line (R-102).
function describeTarget(url) {
  try { const parsed = new URL(url); return `${parsed.hostname}${parsed.pathname}`; } catch { return "(unparseable DATABASE_URL)"; }
}

if (command === "close" && !options.confirm) {
  const url = loadDatabaseUrl();
  console.error(`feedback: close would set ${options.statusCol}='closed' on ${ids.length} row(s) [${ids.join(", ")}] in ${options.table} at ${url ? describeTarget(url) : "(no DATABASE_URL)"}. This writes a managed database (R-101): confirm with the user in this turn, then re-run with --confirm.`);
  process.exit(3);
}

if (options.dryRun) {
  console.log(`feedback: dry run\n  sql:    ${sql}\n  params: ${JSON.stringify(params)}`);
  process.exit(0);
}

const databaseUrl = loadDatabaseUrl();
if (!databaseUrl) { console.error("feedback: no DATABASE_URL in the environment or ./.env"); process.exit(4); }
let pg;
try {
  pg = createRequire(path.resolve(process.cwd(), "package.json"))("pg");
} catch {
  console.error("feedback: the project has no `pg` package installed; run it from the server package that owns the feedback table");
  process.exit(5);
}
const client = new pg.Client({ connectionString: databaseUrl });
try {
  await client.connect();
  const result = await client.query(sql, params);
  if (command === "list") {
    if (result.rows.length === 0) { console.log("No open feedback"); }
    else {
      console.log("| # | ID | Type | Summary | Page | Created |\n|---|---|---|---|---|---|");
      result.rows.forEach((row, index) => {
        const summary = String(row.description ?? "").replace(/\s+/g, " ").slice(0, 80);
        console.log(`| ${index + 1} | ${row.id} | ${row.type} | ${summary} | ${row.page_url ?? ""} | ${new Date(row.created_at).toISOString().slice(0, 10)} |`);
      });
    }
  } else {
    console.log(`feedback: closed ${result.rows.length} row(s): ${result.rows.map((row) => row.id).join(", ")}`);
  }
} catch (error) {
  console.error(`feedback: query failed: ${error.message}`);
  process.exit(6);
} finally {
  await client.end().catch(() => {});
}
