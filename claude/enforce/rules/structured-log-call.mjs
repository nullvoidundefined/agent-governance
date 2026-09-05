/**
 * Custom ESLint rule deciding the syntactic half of R-342: a logger call
 * carries its values in the context object, not in the message string, and
 * the context object comes first.
 *
 * Two defects are pure syntax:
 *   1. `logger.info(`user ${id} registered`)` or `"user " + id`: the value is
 *      interpolated into the message, so it is not a queryable field.
 *   2. `logger.info("User registered", { userId })`: Pino treats the object
 *      after the message as an interpolation argument and drops it silently.
 *
 * What it does NOT decide: whether the context carries the request ID
 * (R-341), whether the level is right, or whether a field is PII. Those stay
 * manual, as their Enforcement lines say.
 */

const LEVELS = new Set(["trace", "debug", "info", "warn", "error", "fatal"]);
const DEFAULT_LOGGER_NAMES = ["logger", "log"];

/** True for a template literal with expressions or a string built with `+`. */
function isInterpolatedMessage(node) {
  if (!node) return false;
  if (node.type === "TemplateLiteral") return node.expressions.length > 0;
  return node.type === "BinaryExpression" && node.operator === "+";
}

/** True for a plain string message with nothing interpolated. */
function isPlainStringMessage(node) {
  if (node.type === "Literal") return typeof node.value === "string";
  return node.type === "TemplateLiteral" && node.expressions.length === 0;
}

/** True when the callee is `<logger>.<level>` for a recognized logger name. */
function isLoggerLevelCall(callee, loggerNames) {
  if (callee.type !== "MemberExpression" || callee.computed) return false;
  if (callee.property.type !== "Identifier" || !LEVELS.has(callee.property.name)) return false;
  const { object } = callee;
  if (object.type === "Identifier") return loggerNames.includes(object.name);
  if (object.type === "MemberExpression" && !object.computed && object.property.type === "Identifier") {
    return loggerNames.includes(object.property.name);
  }
  return false;
}

export default {
  meta: {
    type: "problem",
    docs: { description: "logger calls take a context object first and never interpolate values into the message (R-342)" },
    schema: [
      {
        type: "object",
        properties: { loggerNames: { type: "array", items: { type: "string" } } },
        additionalProperties: false,
      },
    ],
  },
  create(context) {
    const loggerNames = context.options[0]?.loggerNames ?? DEFAULT_LOGGER_NAMES;
    return {
      CallExpression(node) {
        if (!isLoggerLevelCall(node.callee, loggerNames)) return;
        const [first, second] = node.arguments;
        if (!first) return;
        if (isInterpolatedMessage(first)) {
          context.report({
            node: first,
            message: "R-342: put values in the context object, not the message string: `logger.info({ userId }, \"User registered\")`.",
          });
          return;
        }
        if (isPlainStringMessage(first) && node.arguments.slice(1).some((arg) => arg.type === "ObjectExpression")) {
          context.report({
            node,
            message: "R-342: the context object comes first; Pino drops an object placed after the message.",
          });
          return;
        }
        if (isInterpolatedMessage(second)) {
          context.report({
            node: second,
            message: "R-342: put values in the context object, not the message string.",
          });
        }
      },
    };
  },
};
