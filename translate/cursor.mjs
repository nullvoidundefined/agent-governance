#!/usr/bin/env node
// cursor.mjs: cursor/'s port generator. --write regenerates in place;
// --check exits 1 when the tree is behind. Both modes share the same
// source-loading, validation, and render pass. renderPlannedTree covers
// every class of generated content: the Class B stack rules and the Class D
// structure-conventions skill rule, the three Class A always-on rules, the
// Class C rulebook fan-out, the agents_to_subagents agents/commands plus
// the full skills/ copy, hooks.json plus PORT-STATUS.md's many-to-many
// fan-out, the derived .gitignore, and the B-9-classed manifest with its
// own --check parity checks.
import path from "node:path";
import fs from "node:fs";
import {
  SourceError,
  splitFrontmatter,
  loadTextFile,
  loadSettingsHooks,
  loadCursorPortMap,
  hookNameFromCommand,
  hasWholeHookVeto,
  unportedReasonFor,
} from "./parse-sources.mjs";
import { renderStackRule, renderSkillRule } from "./render-cursor-stack-rules.mjs";
import { renderGlobalRules, renderSessionTypes, renderMemoryIndex, renderRulebookFiles } from "./render-cursor-rules.mjs";
import { renderCursorAgent, renderCursorCommand, matchesAgentSubagentList } from "./render-cursor-agents.mjs";
import { renderCursorSkillCopy } from "./render-cursor-skills.mjs";
import { renderCursorHooksConfig, renderCursorPortStatus } from "./render-cursor-hooks.mjs";
import { renderCursorGitignore } from "./render-cursor-gitignore.mjs";
import {
  writePlannedTree as writePlannedTreeCore,
  checkPlannedTree as checkPlannedTreeCore,
  claimPlannedPath,
  buildManifest,
  listFilesWithExtension,
  listSkillDirs,
  makeSkillSourceLoader,
  renderSkillSupportFileFor,
  makeMarkdownSourceLoader,
  runExporterCli,
} from "./exporter-core.mjs";

const TARGET_SUBDIR = "cursor";
const BUILDER_NAME = "translate/cursor.mjs";
const USAGE = "usage: node translate/cursor.mjs --write|--check [--root <repo-dir>]";

// listStackFiles(dir): every CLAUDE-*.md stack convention file under dir,
// sorted. CLAUDE.md itself is loaded separately (it is the always-on rule
// file, not a glob-attached stack track); CLOUD-DEPLOYMENT.md is loaded
// separately too since it does not carry the CLAUDE- prefix (the study's
// Class B "no-paths outlier"). Cursor-specific (codex has no equivalent
// stack-rule class), so it stays local rather than moving to exporter-core.
function listStackFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((name) => name.startsWith("CLAUDE-") && name.endsWith(".md"))
    .sort()
    .map((name) => path.join(dir, name));
}

// loadMarkdownSource(file): cursor's claude/agents/*.md and
// claude/skills/*/SKILL.md loader, built from the shared factory
// (exporter-core.mjs, review I-3a) closing over this file's own
// splitFrontmatter/loadTextFile imports.
const loadMarkdownSource = makeMarkdownSourceLoader(loadTextFile, splitFrontmatter);

// loadSkillSource(skillDir): the skill's SKILL.md plus its bundled support
// files (scripts, reference material), from the shared factory
// (exporter-core.mjs); support files port byte for byte with their modes.
const loadSkillSource = makeSkillSourceLoader(loadTextFile, splitFrontmatter);

// loadSources(rootDir): loads and validates every translator input this
// exporter needs, in both --write and --check: settings hooks, the cursor
// port map, the full rule corpus (CLAUDE.md, session-types.md, the global
// memory index, every CLAUDE-*.md stack file, CLOUD-DEPLOYMENT.md, and the
// four rulebook files), every agent, and every skill. Stack and rulebook
// files are loaded as raw text only; splitting their frontmatter into a
// structured paths: list (CLAUDE-*.md) or slicing reference.md into its
// eight top-level sections (Class C) is a render concern, handled by the
// renderers this function's caller passes the result to, not a loading
// concern. Every failure surfaces as a SourceError naming the offending
// file.
function loadSources(rootDir) {
  const settingsHooks = loadSettingsHooks(path.join(rootDir, "claude/settings.json"));
  const portMap = loadCursorPortMap(path.join(rootDir, "translate/cursor-port-map.json"));
  const claudeMdText = loadTextFile(path.join(rootDir, "claude/CLAUDE.md"));
  const sessionTypesText = loadTextFile(path.join(rootDir, "claude/rules/session-types.md"));
  const globalMemoryIndexText = loadTextFile(path.join(rootDir, "claude/global-memory/INDEX.md"));
  const stackFiles = listStackFiles(path.join(rootDir, "claude"))
    .map((file) => ({ file, text: loadTextFile(file) }));
  const cloudDeploymentText = loadTextFile(path.join(rootDir, "claude/CLOUD-DEPLOYMENT.md"));
  const rulebookAgentsText = loadTextFile(path.join(rootDir, "claude/rulebook/agents.md"));
  const rulebookAuditsText = loadTextFile(path.join(rootDir, "claude/rulebook/audits.md"));
  const rulebookCostText = loadTextFile(path.join(rootDir, "claude/rulebook/cost.md"));
  const rulebookReferenceText = loadTextFile(path.join(rootDir, "claude/rulebook/reference.md"));
  const agents = listFilesWithExtension(path.join(rootDir, "claude/agents"), ".md").map(loadMarkdownSource);
  const skills = listSkillDirs(path.join(rootDir, "claude/skills")).map(loadSkillSource);
  return {
    settingsHooks,
    portMap,
    claudeMdText,
    sessionTypesText,
    globalMemoryIndexText,
    stackFiles,
    cloudDeploymentText,
    rulebookAgentsText,
    rulebookAuditsText,
    rulebookCostText,
    rulebookReferenceText,
    agents,
    skills,
  };
}

// buildManifestClassifications(planned, handAuthored) -> { path: class }:
// "generated" for every planned path, and each hand-authored path's own
// B-9 class from the port map's hand_authored object. Object.entries
// preserves the port map's own key order, so this dict's later keys (and
// the manifest's derived hand_authored array, built from it) stay in that
// same declared order rather than alphabetizing.
function buildManifestClassifications(planned, handAuthored) {
  const classifications = {};
  for (const file of planned) classifications[file.path] = "generated";
  for (const [handAuthoredPath, handAuthoredClass] of Object.entries(handAuthored)) {
    classifications[handAuthoredPath] = handAuthoredClass;
  }
  return classifications;
}

// renderPlannedTree(sources) -> [{ path, content }]: the full planned
// cursor/ output, paths cursor-relative (the caller prefixes cursor/).
// Covers Class B (every CLAUDE-*.md stack file plus the CLOUD-DEPLOYMENT.md
// no-paths outlier), Class D (the structure-conventions skill's rule),
// Class A (000-global-rules.mdc, 001-session-types.mdc,
// 002-global-memory-index.mdc), the Class C rulebook fan-out, the
// agents_to_subagents agents/commands plus the full skills/ copy,
// hooks.json plus PORT-STATUS.md's many-to-many fan-out, the derived
// .gitignore, and last the B-9-classed manifest, which hashes every other
// planned file and so is computed only once everything else is known. A
// missing or renamed structure-conventions skill is a SourceError, matching
// every other required source in this module (review round 1): silently
// omitting rules/structure-conventions.mdc would let --check stay green
// while a generated rule quietly dropped out of the tree.
function renderPlannedTree(sources) {
  const planned = sources.stackFiles.map((stackFile) => renderStackRule(stackFile, sources.portMap));
  planned.push(renderStackRule({ file: "CLOUD-DEPLOYMENT.md", text: sources.cloudDeploymentText }, sources.portMap));
  const structureConventionsSkill = sources.skills.find((skill) => skill.frontmatter.name === "structure-conventions");
  if (!structureConventionsSkill) {
    throw new SourceError("claude/skills/structure-conventions/SKILL.md", "missing or renamed (structure-conventions rule has no source)");
  }
  planned.push(renderSkillRule(structureConventionsSkill));
  planned.push(renderGlobalRules(sources.claudeMdText, sources.settingsHooks, sources.portMap));
  planned.push(renderSessionTypes(sources.sessionTypesText, sources.portMap));
  planned.push(renderMemoryIndex(sources.globalMemoryIndexText, sources.portMap));
  const rulebookTexts = [
    { file: "rulebook/agents.md", text: sources.rulebookAgentsText },
    { file: "rulebook/audits.md", text: sources.rulebookAuditsText },
    { file: "rulebook/cost.md", text: sources.rulebookCostText },
  ];
  planned.push(...renderRulebookFiles(rulebookTexts, sources.rulebookReferenceText, sources.portMap));
  planned.push(renderCursorHooksConfig(sources.settingsHooks, sources.portMap));
  planned.push(renderCursorPortStatus(sources.settingsHooks, sources.portMap));
  // Every path planned above is fixed by this exporter's own rule-class
  // layout (Class A/B/C/D each own a distinct naming scheme) and cannot
  // collide with another rule. agents_to_subagents agents/commands and the
  // full skills/ copy are the first renders whose target path is derived
  // from claude/ source content this exporter does not control, so this is
  // where two sources can race to own one path. One Set spans the whole
  // planned tree built so far (not one Set per file type), so an agent,
  // command, or skill-copy path colliding with a rule path, or with each
  // other, is caught the same way exporter-core's claimPlannedPath already
  // proves out for codex.mjs (review round 1).
  const seenPaths = new Set(planned.map((file) => file.path));
  for (const agent of sources.agents) {
    if (!matchesAgentSubagentList(agent.frontmatter.name, sources.portMap.agents_to_subagents)) continue;
    planned.push(claimPlannedPath(seenPaths, agent.file, renderCursorAgent(agent)));
    planned.push(claimPlannedPath(seenPaths, agent.file, renderCursorCommand(agent)));
  }
  for (const skill of sources.skills) {
    planned.push(claimPlannedPath(seenPaths, skill.file, renderCursorSkillCopy(skill)));
    for (const supportFile of skill.supportFiles) {
      planned.push(claimPlannedPath(seenPaths, skill.file, renderSkillSupportFileFor(skill, supportFile)));
    }
  }
  // The gitignore derives its allowlist from every path planned so far (plus
  // the manifest's own known path, seeded inside the renderer itself, since
  // the manifest is built after this and is never a member of `planned`);
  // it is itself generated (study section 6 ruling), so it is pushed here
  // rather than added to the port map's hand-authored set.
  planned.push(renderCursorGitignore(planned, Object.keys(sources.portMap.hand_authored)));
  // The manifest hashes every other planned file (now including the
  // gitignore), so it is computed last, over exactly this list; it never
  // hashes itself.
  planned.push(buildManifest(BUILDER_NAME, planned, buildManifestClassifications(planned, sources.portMap.hand_authored)));
  return planned;
}

// writePlannedTree(rootDir, planned, portMap): cursor's writer. Target-
// agnostic machinery (all-in-memory-then-write, mkdir -p, orphan removal,
// summary line) lives in exporter-core; this delegates with cursor's
// target subdir and the port map's hand-authored paths (the cursor port
// map's hand_authored is a path -> class object, unlike codex's flat
// array, so its keys are what exporter-core's list-shaped parameter needs).
function writePlannedTree(rootDir, planned, portMap) {
  writePlannedTreeCore(rootDir, TARGET_SUBDIR, planned, Object.keys(portMap.hand_authored));
}

// isRegistrationClassified(name, event, portMap): true when this specific
// (hook, event) registration is accounted for even though its event has no
// row in portMap.events at all: either a whole-hook veto (hasWholeHookVeto,
// a plain-string unported_reasons entry, which by definition covers every
// event that hook is ever registered under) or a per-event reason naming
// this exact event (unportedReasonFor, the object-valued entry shape).
// Checked per registration, not per hook name (review round 1): a hook
// whose unported_reasons entry is an object scoped to one event (e.g.
// verification-gate's SubagentStop reason) must not exempt that SAME
// hook's OTHER registrations from this closure check just because its name
// happens to appear in unported_reasons for an unrelated event; the
// reviewer's probe was exactly this, a verification-gate registration
// under a novel PreCompact event passing silently because the old check
// gated on bare `name in unported_reasons`.
function isRegistrationClassified(name, event, portMap) {
  if (hasWholeHookVeto(name, portMap)) return true;
  return unportedReasonFor(name, event, portMap) !== undefined;
}

// findUnclassifiedHookNames(settingsHooks, portMap): one "name (event)"
// entry per settings.json registration whose event has no row in the
// cursor port map's events object at all, not even an explicit empty
// fan-out, and that isRegistrationClassified does not otherwise account
// for (mirrors codex.mjs's own classification-closure check; cursor's map
// carries no hook_overrides, so portMap.events membership by event name,
// or the per-registration reason check above, are the only ways a
// registration counts as classified). An event the map does list, whose
// specific matcher just falls through to no fan-out (e.g. task-commit-
// reminder's PostToolUse/TaskUpdate registration, where portMap.events.
// PostToolUse exists but names neither "TaskUpdate" nor "*"), is not a gap
// this exists to catch: render-cursor-hooks.mjs already falls back to a
// generic "no Cursor equivalent" message for it, or an unported_reasons
// entry can carry a more specific one.
function findUnclassifiedHookNames(settingsHooks, portMap) {
  const entries = new Set();
  for (const [event, groups] of Object.entries(settingsHooks)) {
    if (Object.prototype.hasOwnProperty.call(portMap.events, event)) continue;
    for (const group of groups) {
      for (const hook of group.hooks ?? []) {
        const name = hookNameFromCommand(hook.command);
        if (isRegistrationClassified(name, event, portMap)) continue;
        entries.add(`${name} (${event})`);
      }
    }
  }
  return [...entries].sort();
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
// cursor's checker. Target-agnostic machinery (stale/missing-hand-authored/
// orphaned lines, reading only, never writing) lives in exporter-core; this
// delegates for that, then layers cursor's own hook-classification checks
// (unclassified and retired hook names) on top, folding their failures into
// the same hasFailure (a retired-hook warning alone never fails).
function checkPlannedTree(rootDir, planned, sources) {
  const core = checkPlannedTreeCore(rootDir, TARGET_SUBDIR, planned, Object.keys(sources.portMap.hand_authored));
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
  builderName: "cursor.mjs",
  usage: USAGE,
  loadSources,
  renderPlannedTree,
  writePlannedTree: (rootDir, planned, sources) => writePlannedTree(rootDir, planned, sources.portMap),
  checkPlannedTree,
});
