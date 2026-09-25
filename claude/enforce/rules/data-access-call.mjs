/**
 * Shared recognizer for the R-36x data-access rules (no-query-in-loop,
 * transaction-client-required): decides whether a call expression reaches the
 * database, from the call's own shape and the file's import declarations.
 *
 * A call reaches the database when it is:
 *   - the pool wrapper's `query(...)`, or any `<object>.query(...)` (`pool.query`,
 *     `client.query`);
 *   - a function imported from a `repositories/`, `database/`, or `db/` module,
 *     called by name (`getJobById(...)`) or through a namespace import
 *     (`jobsRepo.getJobById(...)`).
 *
 * What it does NOT see: a data-access call hidden behind a helper defined in
 * another module that is not a repository (a service calling a service that
 * queries). That is interprocedural and belongs to the query-budget test
 * `CLAUDE-DATABASE.md` prescribes, not to an AST rule.
 */

const DATA_ACCESS_SOURCE = /(^|\/)(repositories|database|db)(\/|$)/;
const QUERY_METHOD = "query";

/** Collects the local names bound by imports from data-access modules. */
export function collectDataAccessBindings(programNode) {
  const bindings = new Set();
  for (const statement of programNode.body) {
    if (statement.type !== "ImportDeclaration" || statement.importKind === "type") continue;
    if (!DATA_ACCESS_SOURCE.test(String(statement.source.value))) continue;
    for (const specifier of statement.specifiers) {
      if (specifier.importKind === "type") continue;
      bindings.add(specifier.local.name);
    }
  }
  return bindings;
}

/**
 * Returns a short label for the callee when the call reaches the database
 * (`query`, `pool.query`, `jobsRepo.getJobById`), or null when it does not.
 */
export function describeDataAccessCall(callNode, bindings) {
  const { callee } = callNode;
  if (callee.type === "Identifier") {
    return callee.name === QUERY_METHOD || bindings.has(callee.name) ? callee.name : null;
  }
  if (callee.type !== "MemberExpression" || callee.computed || callee.property.type !== "Identifier") return null;
  const objectName = callee.object.type === "Identifier" ? callee.object.name : "<expression>";
  if (callee.property.name === QUERY_METHOD) return `${objectName}.${QUERY_METHOD}`;
  if (callee.object.type === "Identifier" && bindings.has(callee.object.name)) return `${objectName}.${callee.property.name}`;
  return null;
}
