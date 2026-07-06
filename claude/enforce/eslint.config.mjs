/**
 * Bundled enforcement ESLint flat config for the global rule system.
 * Loaded by lint.mjs and invoked by push-eslint-gate.sh to check outgoing diffs
 * against the AST-tier rules declared in manifest.json (R-323, R-321, R-319,
 * R-326, R-327, R-324, R-329, and R-303 when a repo opts in via .enforce.json).
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
  // "@/..." path aliases are internal modules, not scoped packages. Without this
  // they classify as "unknown" and import/order demands they trail relative
  // imports, the exact opposite of the projects' prettier importOrder
  // ["^@/(.*)$", "^[./]"], making both tools unsatisfiable at once.
  settings: { "import/internal-regex": "^@/" },
  rules: {
    "sort-keys": ["error", "asc", { natural: true, minKeys: 2 }],
    // R-329: @ts-expect-error self-invalidates when the underlying error is
    // fixed, so it stays legal with a description; blind suppressions do not.
    "@typescript-eslint/ban-ts-comment": [
      "error",
      { "ts-check": false, "ts-expect-error": "allow-with-description", "ts-ignore": true, "ts-nocheck": true },
    ],
    "@typescript-eslint/member-ordering": "error",
    "@typescript-eslint/no-explicit-any": "error",
    "import/order": [
      "error",
      {
        alphabetize: { order: "asc" },
        // distinctGroup:true so a before-positioned pathGroup (react, next) is
        // its own group for newlines-between: trivago Prettier configs with
        // importOrderSeparation:true put a blank line after the react/next
        // family, and with false the gate flagged that required blank line as
        // "empty line within import group" on every file whose react import
        // precedes other externals (voyager push deadlock, 2026-07-07).
        distinctGroup: true,
        groups: ["builtin", "external", "internal", "parent", "sibling", "index"],
        "newlines-between": "always",
        // R-804(b): projects using @trivago/prettier-plugin-sort-imports document
        // react/next-first and app//@/ as separated internal groups; the gate
        // accepts that documented layout instead of fighting pre-commit Prettier
        // (reconciled 2026-07-06 when the voyager push deadlocked between hooks).
        // The bare "react"/"next" patterns keep root-package imports in the same
        // before-positioned family as their subpaths, so Prettier's alphabetical
        // "next" then "next/link" (type import first) passes instead of the gate
        // demanding "next/link" ahead of the bare "next" type import.
        // One pathGroup per trivago Prettier group ('^react$', '^react-dom',
        // '^next'), so distinctGroup:true puts blank lines exactly at
        // Prettier's group boundaries: next and next/** share one pathGroup
        // (adjacent, no blank line), while react/react-dom/next families are
        // blank-line separated from each other and from other externals.
        pathGroups: [
          { pattern: "react", group: "external", position: "before" },
          { pattern: "react-dom{,/**}", group: "external", position: "before" },
          { pattern: "next{,/**}", group: "external", position: "before" },
          { pattern: "app/**", group: "internal" },
          { pattern: "@/**", group: "internal" },
        ],
        pathGroupsExcludedImportTypes: ["react", "react-dom", "next"],
      },
    ],
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
  // tests/ and e2e/ cover projects whose CLAUDE.md overrides R-314 with a
  // top-level mirror tree (R-313 also names tests/ as the Python layout).
  files: [
    "**/__tests__/**",
    "**/__fixtures__/**",
    // Co-located test files (legacy layout in some packages) are tests too.
    "**/*.test.ts",
    "**/*.test.tsx",
    "**/__mocks__/**",
    "**/tests/**",
    "**/e2e/**",
  ],
  rules: {
    "import/order": "off",
    "local/one-export-per-file": "off",
    "no-magic-numbers": "off",
    "sort-keys": "off",
  },
});
