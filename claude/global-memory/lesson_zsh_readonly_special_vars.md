# zsh read-only special variables break scripts silently

`status`, `path`, `options`, and other zsh special variables cannot be assigned in shell scripts run through the zsh-initialized Bash tool. `status=$(...)` fails with "read-only variable: status" and kills the script (a Monitor poll loop died this way on 2026-07-03 while watching a CI run).

**How to apply:** in any inline shell script or Monitor command, never use `status`, `path`, or `options` as variable names; prefer `run_status`, `file_path`, etc. Related: `lesson_zsh_no_word_splitting.md`.
