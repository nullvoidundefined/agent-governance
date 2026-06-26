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
    local: { rules: { "one-export-per-file": oneExportPerFile } },
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
    "local/one-export-per-file": "error",
  },
});
