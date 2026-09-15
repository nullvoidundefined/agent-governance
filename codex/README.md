# openai-global-rules

The Codex configuration generated from [claude-global-rules](https://github.com/nullvoidundefined/claude-global-rules) by `openai/build.mjs`. This directory is `~/.codex`, which Codex reads; it sits beside `~/.claude`, the single source every file here is rendered from.

Do not edit these files: change the source in `~/.claude` and rebuild. To update after a pull of `~/.claude`:

```
node ~/.claude/openai/build.mjs --write
cd ~/.codex && git add -A && git commit -m "chore: rebuild from claude-global-rules" && git push
```

`node ~/.claude/openai/build.mjs --check` reports when this directory is behind the source. `.claude-port.json` records what the build wrote; the `.gitignore` tracks only those files, so Codex's own state in this directory never reaches the repository. `PORT-STATUS.md` lists every Claude Code hook and how it runs here; the fidelity notes and caveats are in the source repository's `openai/README.md`.
