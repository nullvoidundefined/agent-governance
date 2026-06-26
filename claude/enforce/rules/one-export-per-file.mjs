/**
 * Custom ESLint rule enforcing R-235: at most one exported symbol per module.
 * Counts individual exported symbols (including multi-declarator const statements
 * and multi-specifier re-exports) so that `export const a = 1, b = 2` is treated
 * as two exports rather than one export node.
 */

/** Returns the number of exported symbols contributed by a named export node. */
function countNamedExportSymbols(node) {
  if (node.specifiers && node.specifiers.length > 0) {
    return node.specifiers.length;
  }
  if (node.declaration?.type === "VariableDeclaration" && node.declaration.declarations) {
    return node.declaration.declarations.length;
  }
  if (node.declaration) {
    return 1;
  }
  return 0;
}

export default {
  meta: { type: "problem", docs: { description: "one exported function/const per file (R-235)" }, schema: [] },
  create(context) {
    let symbolCount = 0;

    function trackAndReport(node, delta) {
      symbolCount += delta;
      if (symbolCount > 1) {
        context.report({ node, message: "More than one export (R-235): split into one file per exported symbol." });
      }
    }

    return {
      ExportDefaultDeclaration(node) {
        trackAndReport(node, 1);
      },
      ExportNamedDeclaration(node) {
        trackAndReport(node, countNamedExportSymbols(node));
      },
    };
  },
};
