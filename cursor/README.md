# cursor-global-rules

The Cursor configuration generated from [claude-global-rules](https://github.com/nullvoidundefined/claude-global-rules) by `cursor/build.mjs`. This directory is `~/.cursor`, which Cursor reads; it sits beside `~/.claude`, the single source every file here is rendered from.

Do not edit these files: change the source in `~/.claude` and rebuild. To update after a pull of `~/.claude`:

```
node ~/.claude/cursor/build.mjs --write
cd ~/.cursor && git add -A && git commit -m "chore: rebuild from claude-global-rules" && git push
```

`node ~/.claude/cursor/build.mjs --check` reports when this directory is behind the source. `.claude-port.json` records what the build wrote; the `.gitignore` tracks only those files, so Cursor's own state in this directory never reaches the repository. `PORT-STATUS.md` lists every Claude Code hook and how it runs here; the fidelity notes and caveats are in the source repository's `cursor/README.md`.
