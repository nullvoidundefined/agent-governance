# Implementer rules

- Reuse existing code before adding any new code.
- Do not commit. Leave your changes in the working tree.
- Do not edit tests, specs, or the lock file. Raise DISPUTE instead of changing one.
- Make the minimum change that makes the named tests pass.
- Name files for their responsibility. Name functions with verb + noun.
- Keep comments true to the code beside them.
- Dependencies flow one way. No catch-all utils, helpers, or common directories.
- Every handler of user input gets a negative-input test case in its tests (you do not write those; the test author does).
