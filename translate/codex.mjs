#!/usr/bin/env node
// codex.mjs: renders codex/'s generated files from their claude/ sources.
// --write regenerates in place; --check exits 1 when the tree is behind.
// Spec: claude/docs/superpowers/specs/2026-09-17-codex-translator-design.md
import path from "node:path";
import {
  splitFrontmatter,
  loadTextFile,
  loadSettingsHooks,
  loadPortMap,
  hookNameFromCommand,
  hasUnportedReason,
} from "./parse-sources.mjs";
import { renderAgentToml, renderAgentSkill, matchesAgentSkillList } from "./render-codex-agents.mjs";
import { renderSkillCopy, renderSkillSupportFile } from "./render-codex-skills.mjs";
import { renderRulesDoc } from "./render-codex-rules.mjs";
import { renderHooksConfig, renderPortStatus } from "./render-codex-hooks.mjs";
import { renderGitignore } from "./render-codex-gitignore.mjs";
import { buildManifest } from "./build-manifest.mjs";
import {
  writePlannedTree as writePlannedTreeCore,
  checkPlannedTree as checkPlannedTreeCore,
  claimPlannedPath,
  MANIFEST_PATH,
  listFilesWithExtension,
  listSkillDirs,
  makeMarkdownSourceLoader,
  makeSkillSourceLoader,
  runExporterCli,
} from "./exporter-core.mjs";

const TARGET_SUBDIR = "codex";
const USAGE = "usage: node translate/codex.mjs --write|--check [--root <repo-dir>]";

// loadMarkdownSource(file): codex's claude/agents/*.md loader, built from
// the shared factory (exporter-core.mjs) closing over this file's own
// splitFrontmatter/loadTextFile imports.
const loadMarkdownSource = makeMarkdownSourceLoader(loadTextFile, splitFrontmatter);

// loadSkillSource(skillDir): the skill's SKILL.md plus its bundled support
// files, from the shared factory (exporter-core.mjs).
const loadSkillSource = makeSkillSourceLoader(loadTextFile, splitFrontmatter);

// Loads and validates every translator input under the given root: settings
// hooks, the port map, the rule corpus, every agent, and every skill. Every
// failure surfaces as a SourceError naming the offending file.
function loadSources(rootDir) {
  const settingsHooks = loadSettingsHooks(path.join(rootDir, "claude/settings.json"));
  const portMap = loadPortMap(path.join(rootDir, "translate/codex-port-map.json"));
  const claudeMdText = loadTextFile(path.join(rootDir, "claude/CLAUDE.md"));
  const sessionTypesText = loadTextFile(path.join(rootDir, "claude/rules/session-types.md"));
  const agents = listFilesWithExtension(path.join(rootDir, "claude/agents"), ".md").map(loadMarkdownSource);
  const skills = listSkillDirs(path.join(rootDir, "claude/skills")).map(loadSkillSource);
  return { settingsHooks, portMap, claudeMdText, sessionTypesText, agents, skills };
}

// Builds the full planned codex/ output as { path, content } pairs, paths
// codex-relative (the caller prefixes codex/). Agents render before skills,
// each list already alphabetical (listFilesWithExtension/listSkillFiles
// sort), so output is deterministic. Two source files racing to own one
// codex/ path is a source defect, not a silent overwrite, so every path
// whose target is derived from claude/ source content (rather than fixed by
// this exporter's own file layout) goes through exporter-core's
// claimPlannedPath, which throws a SourceError naming the offending source
// the moment a second source claims a path the first already owns: two
// agents sharing a frontmatter name would both plan agents/<name>.toml, and
// a skill.md whose name collides with an agent-derived skill would do the
// same under skills/<name>/SKILL.md. One Set spans the whole planned tree
// (not one Set per file type), seeded with the three fixed-path renders
// below, so an agent or skill colliding with one of those is caught the
// same way (review round 1).
function renderPlannedTree(sources) {
  const planned = [
    renderRulesDoc(sources.claudeMdText, sources.sessionTypesText, sources.settingsHooks, sources.portMap),
    renderHooksConfig(sources.settingsHooks, sources.portMap),
    renderPortStatus(sources.settingsHooks, sources.portMap),
  ];
  const seenPaths = new Set(planned.map((file) => file.path));
  for (const agent of sources.agents) {
    planned.push(claimPlannedPath(seenPaths, agent.file, renderAgentToml(agent)));
    if (matchesAgentSkillList(agent.frontmatter.name, sources.portMap.agents_to_skills)) {
      planned.push(claimPlannedPath(seenPaths, agent.file, renderAgentSkill(agent)));
    }
  }
  for (const skill of sources.skills) {
    planned.push(claimPlannedPath(seenPaths, skill.file, renderSkillCopy(skill)));
    for (const supportFile of skill.supportFiles) {
      planned.push(claimPlannedPath(seenPaths, skill.file, renderSkillSupportFile(skill, supportFile)));
    }
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

// writePlannedTree(rootDir, planned, portMap): codex's writer. Target-
// agnostic machinery (all-in-memory-then-write, mkdir -p, orphan removal,
// summary line) lives in exporter-core; this delegates with codex's target
// subdir and hand-authored list.
function writePlannedTree(rootDir, planned, portMap) {
  writePlannedTreeCore(rootDir, TARGET_SUBDIR, planned, portMap.hand_authored);
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
        // hasOwnProperty, not `in`: `in` walks the prototype chain, so a hook
        // literally named "constructor" or "toString" would read as already
        // classified and vanish from the closure check (audit P3-1). The
        // unported_reasons half of that question is hasUnportedReason, shared
        // with parse-sources.mjs, where the same hole outlived this fix.
        if (Object.prototype.hasOwnProperty.call(overrides, name)
          || hasUnportedReason(name, portMap)) continue;
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
// codex's checker. Target-agnostic machinery (stale/missing-hand-authored/
// orphaned lines, reading only, never writing) lives in exporter-core; this
// delegates for that, then layers codex's own hook-classification checks
// (unclassified and retired hook names) on top, folding their failures into
// the same hasFailure (a retired-hook warning alone never fails).
function checkPlannedTree(rootDir, planned, sources) {
  const core = checkPlannedTreeCore(rootDir, TARGET_SUBDIR, planned, sources.portMap.hand_authored);
  const lines = [...core.lines];
  let hasFailure = core.hasFailure;
  for (const name of findUnclassifiedHookNames(sources.settingsHooks, sources.portMap)) {
    lines.push(`unclassified hook: ${name}`);
    hasFailure = true;
  }
  for (const name of findRetiredHookNames(sources.settingsHooks, sources.portMap)) {
    lines.push(`warning: port map names retired hook ${name}`);
  }
  return { lines, hasFailure };
}

// The shared runExporterCli epilogue (exporter-core.mjs, review I-3a) drives
// this exporter's own loadSources/renderPlannedTree/checkPlannedTree
// directly; writePlannedTree is wrapped since this module's own signature
// takes portMap rather than the full sources object runExporterCli passes.
runExporterCli(process.argv.slice(2), {
  builderName: "codex.mjs",
  usage: USAGE,
  loadSources,
  renderPlannedTree,
  writePlannedTree: (rootDir, planned, sources) => writePlannedTree(rootDir, planned, sources.portMap),
  checkPlannedTree,
});
