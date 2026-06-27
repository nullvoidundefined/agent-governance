/**
 * Bundled enforcement ESLint flat config for the global rule system.
 * Loaded by lint.mjs and invoked by push-eslint-gate.sh to check outgoing diffs
 * against the AST-tier rules declared in manifest.json (R-231, R-218, R-235).
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
    "no-restricted-syntax": [
      "error",
      { selector: "CallExpression[callee.type='FunctionExpression']", message: "No IIFE (R-215): use a named function and call it." },
      { selector: "CallExpression[callee.type='ArrowFunctionExpression']", message: "No IIFE (R-215): use a named async function and call it." },
    ],
  },
}, {
  // R-235: one exported symbol per file, scoped to the function-module trees only
  // (services, api, clients). Constants and types modules group multiple exports
  // per R-222 and are intentionally NOT subject to this rule.
  files: [
    "**/services/**/*.ts",
    "**/services/**/*.tsx",
    "**/api/**/*.ts",
    "**/api/**/*.tsx",
    "**/clients/**/*.ts",
    "**/clients/**/*.tsx",
  ],
  plugins: { local: { rules: { "one-export-per-file": oneExportPerFile } } },
  rules: { "local/one-export-per-file": "error" },
}, {
  // R-221/R-235/R-239: tests and fixtures are exempt from the source-tree-only
  // rules (key/import ordering target source). member-ordering and no-IIFE still apply.
  files: ["**/__tests__/**", "**/__fixtures__/**", "**/__mocks__/**"],
  rules: {
    "import/order": "off",
    "local/one-export-per-file": "off",
    "sort-keys": "off",
  },
});
