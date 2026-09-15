/**
 * Custom ESLint rule deciding the decidable half of R-344: a `catch` binds
 * the error and references it. `catch {}` and `catch (e) { return null }`
 * both discard the only evidence of what failed; the second is worse because
 * it looks handled.
 *
 * What it does NOT decide: what the block does with the error. Logging with
 * `{ err }`, reporting, and rethrowing with `cause` all reference the binding
 * and pass; the quality of that handling stays manual.
 */

export default {
  meta: {
    type: "problem",
    docs: { description: "every catch binds the error and uses it (R-344)" },
    schema: [],
  },
  create(context) {
    const sourceCode = context.sourceCode ?? context.getSourceCode();
    return {
      CatchClause(node) {
        if (!node.param) {
          context.report({
            node,
            message: "R-344: bind the error (`catch (err)`) and log, report, or rethrow it; an unbound catch discards it.",
          });
          return;
        }
        const declared = sourceCode.getDeclaredVariables(node);
        const isReferenced = declared.some((variable) => variable.references.length > 0);
        if (isReferenced) return;
        context.report({
          node: node.param,
          message: "R-344: the caught error is never used; log it with `{ err }`, report it, or rethrow it with `cause`.",
        });
      },
    };
  },
};
