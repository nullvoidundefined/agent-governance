/**
 * Custom ESLint rule deciding the decidable half of R-401 items 1 and 5 in
 * test files: a `vi.mock()` / `jest.mock()` / `.doMock()` whose specifier names
 * the module the test file is named for (item 1, the self-mock: the test can
 * no longer fail on the subject's behavior), and a repository test that mocks
 * the database pool (item 5: a repository test that never reaches a database
 * proves nothing about the query).
 *
 * "The module under test" is read from the file name: `score.test.ts` and
 * `score.spec.ts` test `score`; a mocked specifier whose basename (extension
 * stripped) equals that is the self-mock. A test named for nothing in
 * particular (`integration.test.ts`) is judged on item 5 only.
 *
 * What it does NOT decide: item 2 (mocking the dependency that IS the thing
 * under test) and items 4, 6, 7, which need the test's intent. Those stay with
 * the slice critic and the judge.
 */
import { basename } from "node:path";

const MOCK_OBJECTS = new Set(["vi", "jest"]);
const MOCK_METHODS = new Set(["mock", "doMock"]);
const TEST_SUFFIX = /\.(test|spec)$/;
const REPOSITORY_TEST = /repositor(y|ies)/i;
const POOL_MODULE = /^(pool|db|database|connection|client)$/;
const DATABASE_DIR = /(^|\/)(database|db)\//;

function stripExtension(name) {
  return name.replace(/\.[cm]?[jt]sx?$/, "");
}

export default {
  meta: {
    type: "problem",
    docs: { description: "a test never mocks the module it is named for, and a repository test never mocks the pool (R-401 items 1 and 5)" },
    schema: [],
  },
  create(context) {
    const filename = context.filename ?? context.getFilename();
    const subject = stripExtension(basename(filename)).replace(TEST_SUFFIX, "");
    const isRepositoryTest = REPOSITORY_TEST.test(basename(filename));
    return {
      CallExpression(node) {
        const { callee } = node;
        if (callee.type !== "MemberExpression" || callee.object.type !== "Identifier") return;
        if (!MOCK_OBJECTS.has(callee.object.name) || callee.property.type !== "Identifier" || !MOCK_METHODS.has(callee.property.name)) return;
        const [specifierNode] = node.arguments;
        if (!specifierNode || specifierNode.type !== "Literal" || typeof specifierNode.value !== "string") return;
        const specifier = specifierNode.value;
        const mockedModule = stripExtension(basename(specifier));
        if (subject !== "" && mockedModule === subject) {
          context.report({
            node,
            message: `R-401 item 1: this test is named for '${subject}' and mocks it; a self-mock cannot fail on the subject's behavior. Mock the subject's dependencies, not the subject.`,
          });
          return;
        }
        if (isRepositoryTest && (POOL_MODULE.test(mockedModule) || DATABASE_DIR.test(specifier))) {
          context.report({
            node,
            message: "R-401 item 5: a repository test mocks the database pool, so the query is never executed. Run it against a disposable test database instead.",
          });
        }
      },
    };
  },
};
