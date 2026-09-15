---
name: Use .mjs extension for prettier configs
description: Prettier config files must use .mjs, not .js, to avoid MODULE_TYPELESS_PACKAGE_JSON warnings
type: feedback
---

Always use `.mjs` extension for prettier config files, not `.js`.

**Why:** `.js` with `export default` causes Node to re-parse as ESM and emits `MODULE_TYPELESS_PACKAGE_JSON` warnings, which fail in some pnpm environments.

**How to apply:**
- When creating or referencing prettier configs in any repo, use `.mjs` extension.
- User uses 4-space indent, trailing commas, 100 char width across projects.
