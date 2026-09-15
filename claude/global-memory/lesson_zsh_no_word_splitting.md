---
name: zsh does not word-split unquoted parameters
description: In zsh (default macOS shell) an unquoted $var holding a space/newline-separated list expands as ONE argument, not many; iterate with while-read, an explicit array, or verified NUL xargs
type: feedback
---

zsh, unlike bash, does not perform word-splitting on unquoted parameter expansions. `cmd $list` where `$list` holds newline-separated paths passes the entire blob as a single argument, not one per line. This bit twice in a 2026-06-08 session: both `node script.mjs $FILES` and the `grep -lZ | grep -z | xargs -0` retry fed node one giant `ENAMETOOLONG` path, costing two failed tool calls before the fix.

**How to apply (zsh):**
- Iterate a command's line output safely: `cmd | while IFS= read -r f; do use "$f"; done` (simplest, always works).
- Or build an explicit array: `files=("${(@f)$(cmd)}"); tool "${files[@]}"`.
- Or use real NUL separators end to end, but verify them: BSD `grep -lZ | grep -z ...` can re-emit newlines, so `xargs -0` then receives one token. Confirm the separator survives the whole pipeline before trusting it.
- Never rely on `cmd $unquoted_var` to split into multiple args. That is a bashism; the environment shell here is zsh.

Companion: `lesson_retries_compound_cost.md` (the first failure already diagnosed the cause; switch mechanism rather than re-running a variant of the same broken approach).
