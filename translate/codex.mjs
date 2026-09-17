#!/usr/bin/env node
// codex.mjs: renders codex/'s generated files from their claude/ sources.
// --write regenerates in place; --check exits 1 when the tree is behind.
// Spec: claude/docs/superpowers/specs/2026-09-17-codex-translator-design.md
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";
import {
  SourceError,
  splitFrontmatter,
  loadTextFile,
  loadSettingsHooks,
  loadPortMap,
  hookNameFromCommand,
} from "./parse-sources.mjs";
import { renderAgentToml, renderAgentSkill, matchesAgentSkillList } from "./render-codex-agents.mjs";
import { renderSkillCopy } from "./render-codex-skills.mjs";
import { renderRulesDoc } from "./render-codex-rules.mjs";
import { renderHooksConfig, renderPortStatus } from "./render-codex-hooks.mjs";
import { renderGitignore } from "./render-codex-gitignore.mjs";
import { buildManifest, MANIFEST_PATH } from "./build-manifest.mjs";

function parseCliMode(argv) {
  const flags = argv.filter((a) => a.startsWith("--"));
  const known = new Set(["--write", "--check", "--root"]);
  const modes = flags.filter((f) => f === "--write" || f === "--check");
  const unknown = flags.find((f) => !known.has(f));
  if (unknown || modes.length !== 1) return null;
  const rootIndex = argv.indexOf("--root");
  if (rootIndex === -1) {
    return { mode: modes[0].slice(2), rootDir: path.resolve(fileURLToPath(import.meta.url), "../..") };
  }
  // A bare --root (no following value, or the next token is itself a flag)
  // is a usage error, not a crash: without this guard rootDir is undefined
  // and every later path.join(undefined, ...) throws a TypeError.
  const rootValue = argv[rootIndex + 1];
  if (rootValue === undefined || rootValue.startsWith("--")) return null;
  return { mode: modes[0].slice(2), rootDir: rootValue };
}

function listFilesWithExtension(dir, extension) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((name) => name.endsWith(extension)).sort().map((name) => path.join(dir, name));
}

// listFilesRecursive(dir) -> sorted paths relative to dir, forward-slash
// free (path.join keeps the platform separator, matched by callers that
// also build their planned paths with path.join): every regular file under
// dir, walked depth-first, dir itself omitted from each path.
function listFilesRecursive(dir) {
  if (!fs.existsSync(dir)) return [];
  const found = [];
  const walk = (subDir) => {
    for (const entry of fs.readdirSync(path.join(dir, subDir), { withFileTypes: true })) {
      const relPath = subDir ? path.join(subDir, entry.name) : entry.name;
      if (entry.isDirectory()) walk(relPath);
      else found.push(relPath);
    }
  };
  walk("");
  return found.sort();
}

// findOrphanFiles(rootDir, planned, portMap) -> sorted codex-relative paths:
// every file on disk under <rootDir>/codex/ that renderPlannedTree did not
// plan and the port map does not list as hand_authored. Generated output
// whose claude/ source was deleted (an agent or skill file removed) leaves
// exactly this kind of file behind; codex.mjs owns generated content
// wholesale, so an orphan is always a defect, never intentional.
function findOrphanFiles(rootDir, planned, portMap) {
  const plannedPaths = new Set(planned.map((file) => file.path));
  const handAuthoredPaths = new Set(portMap.hand_authored);
  return listFilesRecursive(path.join(rootDir, "codex"))
    .filter((relPath) => !plannedPaths.has(relPath) && !handAuthoredPaths.has(relPath));
}

function listSkillFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(dir, entry.name, "SKILL.md"))
    .sort();
}

function loadMarkdownSource(file) {
  return { file, ...splitFrontmatter(loadTextFile(file), file) };
}

// Loads and validates every translator input under the given root: settings
// hooks, the port map, the rule corpus, every agent, and every skill. Every
// failure surfaces as a SourceError naming the offending file.
function loadSources(rootDir) {
  const settingsHooks = loadSettingsHooks(path.join(rootDir, "claude/settings.json"));
  const portMap = loadPortMap(path.join(rootDir, "translate/codex-port-map.json"));
  const claudeMdText = loadTextFile(path.join(rootDir, "claude/CLAUDE.md"));
  const sessionTypesText = loadTextFile(path.join(rootDir, "claude/rules/session-types.md"));
  const agents = listFilesWithExtension(path.join(rootDir, "claude/agents"), ".md").map(loadMarkdownSource);
  const skills = listSkillFiles(path.join(rootDir, "claude/skills")).map(loadMarkdownSource);
  return { settingsHooks, portMap, claudeMdText, sessionTypesText, agents, skills };
}

// Builds the full planned codex/ output as { path, content } pairs, paths
// codex-relative (the caller prefixes codex/). Agents render before skills,
// each list already alphabetical (listFilesWithExtension/listSkillFiles
// sort), so output is deterministic. Two source files racing to own one
// codex/ path is a source defect, not a silent overwrite, so it is a
// SourceError: two agents sharing a frontmatter name would both plan
// agents/<name>.toml, and a skill.md whose name collides with an
// agent-derived skill path would do the same under skills/<name>/SKILL.md.
function renderPlannedTree(sources) {
  const planned = [
    renderRulesDoc(sources.claudeMdText, sources.sessionTypesText, sources.settingsHooks, sources.portMap),
    renderHooksConfig(sources.settingsHooks, sources.portMap),
    renderPortStatus(sources.settingsHooks, sources.portMap),
  ];
  const agentTomlPaths = new Set();
  const skillPaths = new Set();
  for (const agent of sources.agents) {
    const tomlFile = renderAgentToml(agent);
    if (agentTomlPaths.has(tomlFile.path)) {
      throw new SourceError(agent.file, `agent name collides with another agent at ${tomlFile.path}`);
    }
    agentTomlPaths.add(tomlFile.path);
    planned.push(tomlFile);
    if (matchesAgentSkillList(agent.frontmatter.name, sources.portMap.agents_to_skills)) {
      const rendered = renderAgentSkill(agent);
      planned.push(rendered);
      skillPaths.add(rendered.path);
    }
  }
  for (const skill of sources.skills) {
    const rendered = renderSkillCopy(skill);
    if (skillPaths.has(rendered.path)) {
      throw new SourceError(skill.file, `skill name collides with an agent-derived skill at ${rendered.path}`);
    }
    planned.push(rendered);
    skillPaths.add(rendered.path);
  }
  // The allowlist names every path git must track, so it is rendered once
  // every other path is known, plus the manifest's own path (planned below,
  // after this file, because the manifest hashes it).
  planned.push(renderGitignore([...planned.map((file) => file.path), MANIFEST_PATH], sources.portMap));
  // The manifest hashes every other planned file, so it is computed last,
  // over exactly this list; it never hashes itself.
  planned.push(buildManifest(planned, sources.portMap));
  return planned;
}

// removeEmptyDirectories(dir): deletes every directory under dir that holds
// no files, deepest first, leaving dir itself in place. Unlinking an orphan
// is only half of removing it: deleting a skill on the claude/ side orphans
// codex/skills/<name>/SKILL.md, and the emptied directory it leaves behind is
// invisible to git (which stores no empty directories) and to --check (which
// compares files), so it would survive every later run unnoticed.
function removeEmptyDirectories(dir) {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) removeEmptyDirectories(path.join(dir, entry.name));
  }
  if (fs.readdirSync(dir).length === 0) fs.rmdirSync(dir);
}

// Writes every planned file under <rootDir>/codex/. Renders the full tree
// before writing the first file, so a render failure never leaves a partial
// write on disk. Afterward it deletes every orphan and every directory the
// deletions emptied (R-306/single-owner: this script owns generated content
// wholesale, so a stale leftover from a deleted claude/ source is never left
// for a human to notice by hand).
function writePlannedTree(rootDir, planned, portMap) {
  for (const file of planned) {
    const fullPath = path.join(rootDir, "codex", file.path);
    fs.mkdirSync(path.dirname(fullPath), { recursive: true });
    fs.writeFileSync(fullPath, file.content);
  }
  const orphans = findOrphanFiles(rootDir, planned, portMap);
  for (const orphan of orphans) fs.unlinkSync(path.join(rootDir, "codex", orphan));
  for (const entry of fs.readdirSync(path.join(rootDir, "codex"), { withFileTypes: true })) {
    if (entry.isDirectory()) removeEmptyDirectories(path.join(rootDir, "codex", entry.name));
  }
  const removedClause = orphans.length > 0 ? `, removed ${orphans.length} orphans` : "";
  console.log(`wrote ${planned.length} files${removedClause}`);
}

// findUnclassifiedHookNames(settingsHooks, portMap): hook names carrying at
// least one registration whose event has no entry in the port map's events
// object at all, not even an explicit null, and that no hook_overrides or
// unported_reasons entry classifies anyway. Deliberately narrower than "does
// not port": an event explicitly mapped to null (e.g. ConfigChange) is a
// known, decided-against Codex event and needs no closure-gap warning here,
// since render-codex-hooks.mjs already falls back to a generic "no Codex
// equivalent" message for it; only an event the port map never mentions at
// all is the gap --check exists to catch.
function findUnclassifiedHookNames(settingsHooks, portMap) {
  const overrides = portMap.hook_overrides ?? {};
  const names = new Set();
  for (const [event, groups] of Object.entries(settingsHooks)) {
    if (Object.prototype.hasOwnProperty.call(portMap.events, event)) continue;
    for (const group of groups) {
      for (const hook of group.hooks ?? []) {
        const name = hookNameFromCommand(hook.command);
        if (name in overrides || name in portMap.unported_reasons) continue;
        names.add(name);
      }
    }
  }
  return [...names].sort();
}

// findRetiredHookNames(settingsHooks, portMap): unported_reasons keys naming
// no hook settings.json still registers. A warning, not a failure: a stale
// map entry does not make the rendered tree wrong, only the map's
// bookkeeping out of date.
function findRetiredHookNames(settingsHooks, portMap) {
  const registered = new Set();
  for (const groups of Object.values(settingsHooks)) {
    for (const group of groups) {
      for (const hook of group.hooks ?? []) registered.add(hookNameFromCommand(hook.command));
    }
  }
  return Object.keys(portMap.unported_reasons).filter((name) => !registered.has(name)).sort();
}

// checkPlannedTree(rootDir, planned, sources) -> { lines, hasFailure }:
// compares the rendered tree against disk and the port map's declarations
// against settings.json, reading only, never writing. `lines` carries every
// stale/unclassified/missing-hand-authored/orphaned/warning message, in that
// order; `hasFailure` is true when any stale, unclassified, missing
// hand-authored, or orphaned line fired (a retired-hook warning alone never
// fails).
function checkPlannedTree(rootDir, planned, sources) {
  const lines = [];
  let hasFailure = false;
  for (const file of planned) {
    const fullPath = path.join(rootDir, "codex", file.path);
    let onDisk = null;
    try { onDisk = fs.readFileSync(fullPath); } catch { onDisk = null; }
    if (onDisk === null || !onDisk.equals(Buffer.from(file.content))) {
      lines.push(`stale: ${file.path}`);
      hasFailure = true;
    }
  }
  for (const name of findUnclassifiedHookNames(sources.settingsHooks, sources.portMap)) {
    lines.push(`unclassified hook: ${name}`);
    hasFailure = true;
  }
  for (const entry of sources.portMap.hand_authored) {
    if (!fs.existsSync(path.join(rootDir, "codex", entry))) {
      lines.push(`missing hand-authored file: ${entry}`);
      hasFailure = true;
    }
  }
  for (const orphan of findOrphanFiles(rootDir, planned, sources.portMap)) {
    lines.push(`orphaned: ${orphan}`);
    hasFailure = true;
  }
  for (const name of findRetiredHookNames(sources.settingsHooks, sources.portMap)) {
    lines.push(`warning: port map names retired hook ${name}`);
  }
  return { lines, hasFailure };
}

const cli = parseCliMode(process.argv.slice(2));
if (!cli) {
  console.error("usage: node translate/codex.mjs --write|--check [--root <repo-dir>]");
  process.exit(2);
}

let sources;
let planned;
try {
  sources = loadSources(cli.rootDir);
  planned = renderPlannedTree(sources);
} catch (err) {
  if (!(err instanceof SourceError)) throw err;
  console.error(err.message);
  process.exit(2);
}

if (cli.mode === "write") {
  writePlannedTree(cli.rootDir, planned, sources.portMap);
  process.exit(0);
}

const { lines, hasFailure } = checkPlannedTree(cli.rootDir, planned, sources);
for (const line of lines) console.log(line);
process.exit(hasFailure ? 1 : 0);
