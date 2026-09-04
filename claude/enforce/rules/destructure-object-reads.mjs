/**
 * Custom ESLint rule enforcing the decidable half of R-325: reading two or more
 * properties off the same object in one scope should destructure instead.
 *
 * R-325 sat on the llm-judge tier with nothing deciding it, yet "how many
 * distinct properties are read off this identifier in this scope" is a pure AST
 * count (2026-09-04 audit follow-up).
 *
 * Method calls are excluded, and that is the rule's other half working rather
 * than a gap: `obj.method()` must NOT become `const { method } = obj`, because
 * the detached function loses its receiver. Excluding call callees is precisely
 * what stops this rule from advising the thing R-325 forbids.
 *
 * What it does NOT decide: "never destructure a method off its object" as a
 * standalone check. Whether a destructured property holds a function is a type
 * question, not a syntax question, and faking it from the identifier's name
 * would be a proxy for a different rule. That half stays with the judge.
 */

const DESTRUCTURE_THRESHOLD = 2;

/** True when the member expression is being called, assigned to, or updated. */
function isExcludedContext(node, parent) {
  if (!parent) return false;
  if (parent.type === "CallExpression" && parent.callee === node) return true;
  if (parent.type === "TaggedTemplateExpression" && parent.quasi === node) return true;
  if (parent.type === "AssignmentExpression" && parent.left === node) return true;
  if (parent.type === "UpdateExpression") return true;
  if (parent.type === "MemberExpression" && parent.object === node) return true;
  return false;
}

/** True when this is a plain, non-computed `identifier.property` read. */
function isPlainPropertyRead(node) {
  return (
    !node.computed &&
    node.object.type === "Identifier" &&
    node.property.type === "Identifier"
  );
}

export default {
  meta: {
    type: "suggestion",
    docs: { description: "destructure when reading 2+ properties of an object (R-325)" },
    schema: [],
  },
  create(context) {
    const scopeStack = [];

    function enterScope() {
      scopeStack.push(new Map());
    }

    function exitScope() {
      const readsByObject = scopeStack.pop();
      for (const [objectName, record] of readsByObject) {
        if (record.properties.size < DESTRUCTURE_THRESHOLD) continue;
        const propertyList = [...record.properties].sort().join(", ");
        context.report({
          node: record.reportNode,
          message: `"${objectName}" is read for ${record.properties.size} properties (${propertyList}) in this scope (R-325): destructure instead.`,
        });
      }
    }

    return {
      ArrowFunctionExpression: enterScope,
      "ArrowFunctionExpression:exit": exitScope,
      FunctionDeclaration: enterScope,
      "FunctionDeclaration:exit": exitScope,
      FunctionExpression: enterScope,
      "FunctionExpression:exit": exitScope,
      Program: enterScope,
      "Program:exit": exitScope,
      MemberExpression(node) {
        if (scopeStack.length === 0) return;
        if (!isPlainPropertyRead(node)) return;
        if (isExcludedContext(node, node.parent)) return;

        const readsByObject = scopeStack.at(-1);
        const objectName = node.object.name;
        const record = readsByObject.get(objectName) ?? { properties: new Set(), reportNode: node };
        record.properties.add(node.property.name);
        if (record.properties.size === DESTRUCTURE_THRESHOLD) record.reportNode = node;
        readsByObject.set(objectName, record);
      },
    };
  },
};
