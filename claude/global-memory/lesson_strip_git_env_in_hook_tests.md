---
name: lesson-strip-git-env-in-hook-tests
description: Any test that spawns git in a temp repo must strip GIT_* from the child env; under a git hook, GIT_DIR leaks and the "throwaway" commands hit the real repo
metadata:
  type: feedback
---

A test that builds a throwaway git repo (`git init`, `git config`, commits, `update-ref`) must spawn every git child with all `GIT_*` variables removed from its environment. Git exports `GIT_DIR`, `GIT_INDEX_FILE` and friends to hook processes, and pre-push and pre-commit hooks commonly run test suites. A child git that inherits `GIT_DIR` ignores its `cwd` and operates on the real repository.

**Why:** on 2026-09-26 in doppelscript, a new test for IAN-431 ran inside the pre-push hook. Its `git init` and `git config` calls rewrote the shared repo config (`core.bare=true`, `core.hooksPath=/dev/null`, `user.name=Test`), which broke every worktree for every parallel session. Running the test from a normal shell passed and did no harm, so neither local runs nor a fresh-context review caught it. The auto-mode classifier then refused the agent's attempt to repair `.git/config`, so the owner had to fix it by hand.

**How to apply:**
- In any test helper that spawns `git`, pass an `env` with every key starting `GIT_` dropped (keep `PATH` and `HOME`).
- Add a regression test that sets `GIT_DIR` to a second temporary repo with a distinct config value (such as `user.name Outer`), runs the setup, and asserts that repo's config is byte-identical. With identical values the leak goes unnoticed; this is why a first version of the test passed while stripping was disabled.
- Also scrub the environment when spawning a script that itself runs git, unless the script is meant to act on the surrounding repo.
- If git suddenly reports "this operation must be run in a work tree" everywhere, check `core.bare` in the shared repo config before anything else.
