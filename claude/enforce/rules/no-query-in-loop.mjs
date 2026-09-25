/**
 * Custom ESLint rule deciding the decidable half of R-361: a database call
 * that runs once per element of a collection (the N+1 query). It reports a
 * data-access call (data-access-call.mjs) that sits where it is evaluated on
 * every iteration:
 *   - the body of a `for`, `for...of` (including `for await`), `for...in`,
 *     `while`, or `do...while`, and the test or update clause of a `for` or
 *     `while`;
 *   - a callback passed to an array iteration method (`.map`, `.forEach`,
 *     `.flatMap`, `.filter`, `.reduce`, `.some`, `.every`, `.find`, ...) or to
 *     `Array.from`, which is how `Promise.all(ids.map((id) => getJob(id)))`
 *     is caught: parallel N+1 is still N round trips and N pool checkouts.
 *
 * Not repeated, so not reported: the iterable of a `for...of` and the init of
 * a `for`, which run once. A function declared elsewhere and called inside a
 * loop is not followed (the walk stops at a function boundary that is not an
 * iteration callback); the runtime query budget covers that case.
 *
 * A loop that is bounded on purpose (keyset batching, one query per 1000 rows)
 * takes `// eslint-disable-next-line dataAccess/no-query-in-loop -- <why>`.
 */
import { collectDataAccessBindings, describeDataAccessCall } from "./data-access-call.mjs";

const ITERATION_METHODS = new Set([
  "every",
  "filter",
  "find",
  "findIndex",
  "findLast",
  "findLastIndex",
  "flatMap",
  "forEach",
  "map",
  "reduce",
  "reduceRight",
  "some",
]);

const FUNCTION_TYPES = new Set(["ArrowFunctionExpression", "FunctionDeclaration", "FunctionExpression"]);

/** Names the loop construct when `child` is re-evaluated on each of its iterations, else null. */
function describeRepeatingLoop(parent, child) {
  switch (parent.type) {
    case "ForStatement":
      return child === parent.body || child === parent.test || child === parent.update ? "for loop" : null;
    case "ForOfStatement":
      return child === parent.body ? (parent.await ? "for await...of loop" : "for...of loop") : null;
    case "ForInStatement":
      return child === parent.body ? "for...in loop" : null;
    case "WhileStatement":
      return "while loop";
    case "DoWhileStatement":
      return "do...while loop";
    default:
      return null;
  }
}

/** Names the iteration callback when `fn` is one, else null. */
function describeIterationCallback(fn) {
  const call = fn.parent;
  if (!call || call.type !== "CallExpression" || !call.arguments.includes(fn)) return null;
  const { callee } = call;
  if (callee.type !== "MemberExpression" || callee.computed || callee.property.type !== "Identifier") return null;
  const method = callee.property.name;
  if (ITERATION_METHODS.has(method)) return `.${method}() callback`;
  const isArrayFrom = callee.object.type === "Identifier" && callee.object.name === "Array" && method === "from";
  return isArrayFrom && call.arguments[1] === fn ? "Array.from() callback" : null;
}

/** Walks outward from the call to the nearest construct that repeats it, stopping at a plain function boundary. */
function findRepetition(callNode) {
  let child = callNode;
  let parent = callNode.parent;
  while (parent) {
    const loop = describeRepeatingLoop(parent, child);
    if (loop) return loop;
    if (FUNCTION_TYPES.has(parent.type)) return describeIterationCallback(parent);
    child = parent;
    parent = parent.parent;
  }
  return null;
}

export default {
  meta: {
    type: "problem",
    docs: { description: "no database call runs once per iteration of a loop or iteration callback (R-361, N+1)" },
    schema: [],
  },
  create(context) {
    let bindings = new Set();
    return {
      Program(node) {
        bindings = collectDataAccessBindings(node);
      },
      CallExpression(node) {
        const callee = describeDataAccessCall(node, bindings);
        if (!callee) return;
        const repetition = findRepetition(node);
        if (!repetition) return;
        context.report({
          node,
          message: `R-361: \`${callee}(...)\` runs once per iteration of this ${repetition} (N+1). Load the set in one query (\`WHERE id = ANY($1::uuid[])\`, a JOIN, or a lateral \`json_agg\`) or write it in one statement (\`unnest\`), then work in memory. A deliberately bounded loop takes an eslint-disable-next-line comment stating the bound.`,
        });
      },
    };
  },
};
