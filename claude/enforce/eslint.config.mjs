/**
 * Bundled enforcement ESLint flat config for the global rule system.
 * Loaded by lint.mjs and invoked by push-eslint-gate.sh to check outgoing diffs
 * against the AST-tier rules declared in manifest.json (R-323, R-321, R-319).
 */
import tseslint from "typescript-eslint";
import importPlugin from "eslint-plugin-import";
import oneExportPerFile from "./rules/one-export-per-file.mjs";

export default tseslint.config({
  files: ["**/*.ts", "**/*.tsx"],
  plugins: {
    "@typescript-eslint": tseslint.plugin,
    import: importPlugin,
  },
  languageOptions: {
    parser: tseslint.parser,
    parserOptions: { ecmaFeatures: { jsx: true } },
  },
  rules: {
    "sort-keys": ["error", "asc", { natural: true, minKeys: 2 }],
    "@typescript-eslint/member-ordering": "error",
    "import/order": ["error", { "newlines-between": "always", alphabetize: { order: "asc" } }],
    "max-lines-per-function": ["warn", { max: 60, skipBlankLines: true, skipComments: true }],
    "no-magic-numbers": [
      "error",
      { detectObjects: false, enforceConst: true, ignore: [0, 1, -1], ignoreArrayIndexes: true, ignoreDefaultValues: true },
    ],
    "no-nested-ternary": "error",
    "no-restricted-syntax": [
      "error",
      { selector: "CallExpression[callee.type='FunctionExpression']", message: "No IIFE (R-326): use a named function and call it." },
      { selector: "CallExpression[callee.type='ArrowFunctionExpression']", message: "No IIFE (R-326): use a named async function and call it." },
    ],
  },
}, {
  // R-319: one exported symbol per file, scoped to the function-module trees only
  // (services, api, clients). Constants and types modules group multiple exports
  // per R-307/R-309 and are intentionally NOT subject to this rule, so types.ts /
  // constants.ts files (and promoted types/ constants/ folders) are ignored here
  // even when they live inside a services/api/clients tree.
  files: [
    "**/services/**/*.ts",
    "**/services/**/*.tsx",
    "**/api/**/*.ts",
    "**/api/**/*.tsx",
    "**/clients/**/*.ts",
    "**/clients/**/*.tsx",
  ],
  ignores: [
    "**/types.ts",
    "**/constants.ts",
    "**/types/**/*.ts",
    "**/constants/**/*.ts",
  ],
  plugins: { local: { rules: { "one-export-per-file": oneExportPerFile } } },
  rules: { "local/one-export-per-file": "error" },
}, {
  // R-313/R-319/R-314: tests and fixtures are exempt from the source-tree-only
  // rules (key/import ordering target source). member-ordering and no-IIFE still apply.
  files: ["**/__tests__/**", "**/__fixtures__/**", "**/__mocks__/**"],
  rules: {
    "import/order": "off",
    "local/one-export-per-file": "off",
    "no-magic-numbers": "off",
    "sort-keys": "off",
  },
});
