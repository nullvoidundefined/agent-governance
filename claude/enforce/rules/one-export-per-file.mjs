/**
 * Custom ESLint rule enforcing R-319: at most one exported symbol per module.
 * Counts individual exported symbols (including multi-declarator const statements
 * and multi-specifier re-exports) so that `export const a = 1, b = 2` is treated
 * as two exports rather than one export node.
 *
 * Exemption (2026-07-10, Ian-approved): a pure re-export barrel named index.*
 * (every export statement re-exports from another module, no local declarations)
 * is the documented backend import surface in projects whose CLAUDE.md mandates
 * per-module barrels (doppelscript root rule 15). R-319 still binds every
 * non-barrel module and any index file that declares anything locally.
 */

const INDEX_FILENAME_PATTERN = /(^|[\\/])index\.(ts|tsx|mts|cts|js|mjs)$/;

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
  meta: { type: "problem", docs: { description: "one exported function/const per file (R-319)" }, schema: [] },
  create(context) {
    const trackedExports = [];

    function trackExport(node, symbolDelta, isReExport) {
      trackedExports.push({ isReExport, node, symbolDelta });
    }

    return {
      ExportAllDeclaration(node) {
        // `export * from` contributes no countable symbols (matching the rule's
        // historical behavior) but marks the statement as a re-export so a pure
        // star-barrel stays exempt.
        trackExport(node, 0, true);
      },
      ExportDefaultDeclaration(node) {
        trackExport(node, 1, false);
      },
      ExportNamedDeclaration(node) {
        trackExport(node, countNamedExportSymbols(node), node.source != null);
      },
      "Program:exit"() {
        const filename = context.filename ?? context.getFilename();
        const isPureBarrel =
          INDEX_FILENAME_PATTERN.test(filename) && trackedExports.every((entry) => entry.isReExport);
        if (isPureBarrel) return;
        reportExcessExports(context, trackedExports);
      },
    };
  },
};

/** Reports every export statement past the single allowed exported symbol. */
function reportExcessExports(context, trackedExports) {
  let symbolCount = 0;
  for (const entry of trackedExports) {
    symbolCount += entry.symbolDelta;
    if (symbolCount > 1) {
      context.report({
        message: "More than one export (R-319): split into one file per exported symbol.",
        node: entry.node,
      });
    }
  }
}
