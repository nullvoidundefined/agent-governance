/**
 * Custom ESLint rule deciding the decidable half of R-362: every statement
 * inside a transaction runs on the transaction's client, and nothing inside it
 * waits on the network.
 *
 * Inside the callback passed to `withTransaction(async (client) => ...)`:
 *   - a data-access call (data-access-call.mjs) must run on the client: either
 *     as `client.query(...)`, or with the client passed as an argument
 *     (`query(sql, values, client)`, `jobsRepo.createJob(input, client)`,
 *     `createJob({ client, input })`). Anything else checks a different
 *     connection out of the pool, so it runs outside the transaction: it does
 *     not roll back, it cannot see the transaction's uncommitted writes, and
 *     with a small pool it can deadlock waiting for a connection the
 *     transaction itself holds.
 *   - a callback that declares no client parameter cannot pass one, so every
 *     data-access call inside it reports.
 *   - a call to `fetch` or to a function imported from a `clients/` module
 *     holds the transaction's locks and connection open for a network round
 *     trip; it belongs before the transaction or after commit.
 *
 * What it does NOT decide: whether a function that issues two writes needed a
 * transaction at all. That depends on whether the writes must succeed
 * together, which is intent; it stays manual under R-362.
 */
import { collectDataAccessBindings, describeDataAccessCall } from "./data-access-call.mjs";

const TRANSACTION_HELPER = "withTransaction";
const CLIENT_SOURCE = /(^|\/)clients(\/|$)/;
const FUNCTION_TYPES = new Set(["ArrowFunctionExpression", "FunctionExpression"]);

/** True when the call is `withTransaction(...)` or `<object>.withTransaction(...)`. */
function isTransactionCall(node) {
  const { callee } = node;
  if (callee.type === "Identifier") return callee.name === TRANSACTION_HELPER;
  return callee.type === "MemberExpression" && !callee.computed && callee.property.type === "Identifier" && callee.property.name === TRANSACTION_HELPER;
}

/** Collects local names imported from `clients/` modules (outbound network wrappers, R-307). */
function collectClientBindings(programNode) {
  const bindings = new Set();
  for (const statement of programNode.body) {
    if (statement.type !== "ImportDeclaration" || statement.importKind === "type") continue;
    if (!CLIENT_SOURCE.test(String(statement.source.value))) continue;
    for (const specifier of statement.specifiers) bindings.add(specifier.local.name);
  }
  return bindings;
}

/** True when an argument is the client identifier or an object literal carrying it. */
function passesClient(callNode, clientName) {
  return callNode.arguments.some((argument) => {
    if (argument.type === "Identifier") return argument.name === clientName;
    if (argument.type !== "ObjectExpression") return false;
    return argument.properties.some((property) => property.type === "Property" && property.value.type === "Identifier" && property.value.name === clientName);
  });
}

/** True when the call is `<client>.<method>(...)`. */
function isCalledOnClient(callNode, clientName) {
  const { callee } = callNode;
  return callee.type === "MemberExpression" && callee.object.type === "Identifier" && callee.object.name === clientName;
}

/** Names a network call (`fetch`, or a function imported from `clients/`), else null. */
function describeNetworkCall(callNode, clientBindings) {
  const { callee } = callNode;
  if (callee.type === "Identifier") return callee.name === "fetch" || clientBindings.has(callee.name) ? callee.name : null;
  if (callee.type === "MemberExpression" && callee.object.type === "Identifier" && clientBindings.has(callee.object.name)) {
    return callee.property.type === "Identifier" ? `${callee.object.name}.${callee.property.name}` : callee.object.name;
  }
  return null;
}

export default {
  meta: {
    type: "problem",
    docs: { description: "every call inside withTransaction runs on the transaction client, and none waits on the network (R-362)" },
    schema: [],
  },
  create(context) {
    let dataAccessBindings = new Set();
    let clientBindings = new Set();
    const transactions = [];

    function enterFunction(node) {
      const call = node.parent;
      if (!call || call.type !== "CallExpression" || call.arguments[0] !== node || !isTransactionCall(call)) return;
      const [firstParam] = node.params;
      transactions.push({ clientName: firstParam && firstParam.type === "Identifier" ? firstParam.name : null, node });
    }

    function exitFunction(node) {
      if (transactions.length > 0 && transactions[transactions.length - 1].node === node) transactions.pop();
    }

    return {
      Program(node) {
        dataAccessBindings = collectDataAccessBindings(node);
        clientBindings = collectClientBindings(node);
      },
      ArrowFunctionExpression: enterFunction,
      "ArrowFunctionExpression:exit": exitFunction,
      FunctionExpression: enterFunction,
      "FunctionExpression:exit": exitFunction,
      CallExpression(node) {
        if (transactions.length === 0 || FUNCTION_TYPES.has(node.callee.type)) return;
        const { clientName } = transactions[transactions.length - 1];
        const network = describeNetworkCall(node, clientBindings);
        if (network) {
          context.report({
            node,
            message: `R-362: \`${network}(...)\` waits on the network inside a transaction, holding its locks and connection for the round trip. Call it before \`withTransaction\` or after it commits.`,
          });
          return;
        }
        const callee = describeDataAccessCall(node, dataAccessBindings);
        if (!callee) return;
        if (!clientName) {
          context.report({
            node,
            message: `R-362: \`${callee}(...)\` is inside a \`withTransaction\` callback that declares no client parameter, so it runs on another pool connection, outside the transaction. Take \`async (client) => ...\` and pass \`client\` to every query.`,
          });
          return;
        }
        if (isCalledOnClient(node, clientName) || passesClient(node, clientName)) return;
        context.report({
          node,
          message: `R-362: \`${callee}(...)\` inside \`withTransaction\` does not receive \`${clientName}\`, so it checks out another pool connection and runs outside the transaction (no rollback, cannot see its writes). Pass \`${clientName}\` through.`,
        });
      },
    };
  },
};
