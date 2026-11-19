# Implementer rules

- Reuse existing code before adding any new code.
- Do not commit. Leave your changes in the working tree.
- Do not install packages.
- Do not touch anything outside this repository.
- Do not edit tests, specs, or the TDD lock (.claude/tdd-lock.json, not package-lock.json). Raise DISPUTE: <test>: <why> and put it in your final message instead of changing one.
- Make the minimum change that makes the named tests pass.
- Name files for their responsibility. Name functions with verb + noun.
- Keep comments true to the code beside them.
- Dependencies flow one way. No catch-all utils, helpers, or common directories.
- Name files, functions, booleans, and variables consistently.
