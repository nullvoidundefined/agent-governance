/**
 * Custom ESLint rule deciding R-401 item 3 in test files: a test whose only
 * `expect()` matchers are mock-call matchers (`toHaveBeenCalled`,
 * `toHaveBeenCalledWith`, `toBeCalledTimes`, and their siblings) asserts that
 * code ran, not what it did. One behavior assertion beside them (a return
 * value, a thrown error, a resolved value, a database row) is enough.
 *
 * A test with no `expect()` at all is not judged: it may assert through
 * another library, or exist to prove a call does not throw. What the rule does
 * NOT decide: whether the behavior assertion is the right one, which is item 6
 * (tautology) and item 7 (loose shape), left to the critic and the judge.
 */

const TEST_FUNCTIONS = new Set(["it", "test"]);
const TEST_MODIFIERS = new Set(["only", "skip", "concurrent", "sequential", "fails", "todo"]);
const MOCK_MATCHERS = new Set([
  "lastCalledWith",
  "nthCalledWith",
  "toBeCalled",
  "toBeCalledTimes",
  "toBeCalledWith",
  "toHaveBeenCalled",
  "toHaveBeenCalledExactlyOnceWith",
  "toHaveBeenCalledOnce",
  "toHaveBeenCalledTimes",
  "toHaveBeenCalledWith",
  "toHaveBeenLastCalledWith",
  "toHaveBeenNthCalledWith",
]);

/** `it(...)`, `test(...)`, `it.only(...)`, `test.skip(...)`. */
function isTestCall(node) {
  const { callee } = node;
  if (callee.type === "Identifier") return TEST_FUNCTIONS.has(callee.name);
  return (
    callee.type === "MemberExpression" &&
    callee.object.type === "Identifier" &&
    TEST_FUNCTIONS.has(callee.object.name) &&
    callee.property.type === "Identifier" &&
    TEST_MODIFIERS.has(callee.property.name)
  );
}

/** The matcher name when `node` is the terminal call of an `expect(...)` chain, else null. */
function matcherOf(node) {
  const { callee } = node;
  if (callee.type !== "MemberExpression" || callee.property.type !== "Identifier") return null;
  let root = callee.object;
  while (root.type === "MemberExpression") root = root.object;
  const isExpectRoot =
    root.type === "CallExpression" &&
    (root.callee.type === "Identifier" ? root.callee.name === "expect" : root.callee.type === "MemberExpression" && root.callee.object.type === "Identifier" && root.callee.object.name === "expect");
  return isExpectRoot ? callee.property.name : null;
}

export default {
  meta: {
    type: "problem",
    docs: { description: "every test with an expect() asserts at least one behavior, not only mock calls (R-401 item 3)" },
    schema: [],
  },
  create(context) {
    const openTests = [];
    return {
      CallExpression(node) {
        if (isTestCall(node)) {
          openTests.push({ behavior: 0, mockOnly: 0, node });
          return;
        }
        const matcher = matcherOf(node);
        if (matcher === null || openTests.length === 0) return;
        const current = openTests[openTests.length - 1];
        if (MOCK_MATCHERS.has(matcher)) current.mockOnly += 1;
        else current.behavior += 1;
      },
      "CallExpression:exit"(node) {
        if (!isTestCall(node)) return;
        const finished = openTests.pop();
        if (finished.mockOnly > 0 && finished.behavior === 0) {
          context.report({
            node: finished.node.callee,
            message: "R-401 item 3: every assertion here is a mock-call matcher; add one behavior assertion (return value, thrown error, resolved value, stored row) so the test can fail on what the code does, not only on whether it ran.",
          });
        }
      },
    };
  },
};
