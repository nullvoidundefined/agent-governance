/**
 * Custom ESLint rule deciding the call-site half of R-343: an analytics event
 * is named by a registry constant, never by a string literal where it is
 * emitted. A literal at the call site is how `signup_complete` and
 * `signup_completed` both end up in the dashboard.
 *
 * Recognizes `.track(`, `.capture(`, and `trackEvent(` (configurable). What it
 * does NOT decide: that the constant exists in the registry, or that the
 * provider SDK is imported only from `clients/analytics` (R-307, manual).
 */

const DEFAULT_METHODS = ["track", "capture", "trackEvent"];

/** The called name: `x.track(` yields `track`, `trackEvent(` yields itself. */
function calledName(callee) {
  if (callee.type === "Identifier") return callee.name;
  if (callee.type === "MemberExpression" && !callee.computed && callee.property.type === "Identifier") {
    return callee.property.name;
  }
  return null;
}

/** True for a string literal or any template literal. */
function isStringLike(node) {
  if (node.type === "Literal") return typeof node.value === "string";
  return node.type === "TemplateLiteral";
}

export default {
  meta: {
    type: "problem",
    docs: { description: "analytics events are named from the event registry, never a literal at the call site (R-343)" },
    schema: [
      {
        type: "object",
        properties: { methods: { type: "array", items: { type: "string" } } },
        additionalProperties: false,
      },
    ],
  },
  create(context) {
    const methods = context.options[0]?.methods ?? DEFAULT_METHODS;
    return {
      CallExpression(node) {
        const name = calledName(node.callee);
        if (!name || !methods.includes(name)) return;
        const [eventName] = node.arguments;
        if (!eventName || !isStringLike(eventName)) return;
        context.report({
          node: eventName,
          message: `R-343: name the event from the registry (analytics/events.ts), not a literal in \`${name}(\`.`,
        });
      },
    };
  },
};
