#!/usr/bin/env node
// apply-profile.mjs: the one harness-profile filter (IAN-518). Given a profile
// name from claude/enforce/harness-profiles.json and a claude/ source set, it
// returns the filtered set: CLAUDE.md without the listed rule lines,
// settings.json without the listed hook registrations, and the listed files,
// SKILL.md files, and agent files left out. Every consumer uses it: the
// Cursor and Codex exporters (cursor.mjs, codex.mjs --profile) and sync.sh
// (through the --in-place CLI below). No profile, or "full", is the identity.
// An unknown profile, or a listed id that no longer exists in claude/, is a
// ProfileError, so the list cannot drift silently from the tree it filters.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const FULL_PROFILE = "full";
export const PROFILES_RELATIVE_PATH = "enforce/harness-profiles.json";
const PROFILE_KINDS = ["rules", "hooks", "skills", "agents", "files"];
const RULE_LINE = /^(R-\d{3})( \[[a-z]+\])?:/;

// PROTECTED: what no profile may ever remove, kept apart from the profile
// file so that widening a profile cannot also widen what it is allowed to
// touch (PR #175 review). Hooks are every ENFORCE and STRUCTURAL hook row of
// docs/harness-audit.md (each can deny, ask, or block) plus harness-sync,
// which delivers them all (R-003); each is protected both as a registration
// and as its hooks/<name>.sh file. Rules are the ENFORCE and STRUCTURAL rule
// ids of the same audit. Agents are the six STRUCTURAL roles. Paths cover
// the files gates read: enforce/ (role-policy.json, tdd.sh, the manifest),
// every skill script and data file beside a SKILL.md, and the judge's
// rulebook/reference.md.
export const PROTECTED_HOOKS = new Set([
  "harness-sync",
  "codex-billing-guard", "commit-message-guard", "conflict-markers",
  "constant-change-guard", "content-gate", "dependency-add-guard", "destructive-command-guard",
  "destructive-db-guard", "fix-commit-requires-test", "git-workflow-guard", "global-repo-push-guard",
  "linear-todo-label-gate", "mcp-action-guard", "migration-defaults-guard", "no-em-dash",
  "pr-ticket-ref-gate", "protected-path-guard", "push-eslint-gate",
  "push-ruff-gate", "push-semgrep-gate",
  "secret-scan", "settings-change-guard", "structure-gate",
  "verification-gate",
]);
export const PROTECTED_RULES = new Set([
  "R-003", "R-101", "R-102", "R-103", "R-105", "R-106", "R-107", "R-108", "R-109",
  "R-203", "R-207", "R-212", "R-214",
  "R-302", "R-303", "R-306", "R-315", "R-316", "R-317", "R-320", "R-325", "R-330", "R-331", "R-334",
  "R-342", "R-343", "R-344", "R-361", "R-362", "R-363", "R-364", "R-365",
  "R-401", "R-403", "R-405", "R-410", "R-411", "R-412",
  "R-505", "R-507", "R-509", "R-512", "R-513", "R-514", "R-517",
  "R-605", "R-607", "R-608",
]);
const PROTECTED_AGENTS = new Set(["test-author", "implementer", "slice-critic", "spec-conformance-review", "pr-reviewer", "security-reviewer"]);
// The two STRUCTURAL prompt contracts the review gates check against, and
// the spec template spec-glossary-check reads (PR #175 review round 2).
const PROTECTED_EXACT_PATHS = new Set([
  "CLAUDE.md", "settings.json", "rulebook/reference.md",
  "prompts/security-review-prompt.md", "prompts/codex-pr-review-prompt.md", "prompts/spec-template.md",
]);
// REMOVABLE_HOOK_SCRIPTS: the only hooks/ files a profile may omit, the
// scripts of the hooks docs/harness-audit.md classes COACHING or
// ORCHESTRATION (harness-sync excepted). Every other file under hooks/, a
// sourced helper, a Python or Node scanner, pre-push.sample, a hook test, is
// protected, so the rule cannot be bypassed by a helper an enforcing hook
// needs (PR #175 review round 2).
const REMOVABLE_HOOK_SCRIPTS = new Set([
  "audit-signal-check", "build-cheatsheets", "dockerfile-reminder",
  "draft-pr-on-first-push", "enforcement-guard-check", "flat-directory-reminder", "handoff-check",
  "hook-integrity-check", "hookspath-drift-check", "model-switch-guard", "new-file-header-reminder",
  "observability-reminder", "parallel-session-check", "post-compact-rules", "pr-monitor-reminder",
  "redact-output", "redaction-guard-check", "session-end", "session-start",
  "spec-glossary-check", "task-commit-reminder", "task-state-tracker",
]);

// isProtectedPath(rel): true for a path no profile may omit.
function isProtectedPath(rel) {
  if (PROTECTED_EXACT_PATHS.has(rel) || rel.startsWith("enforce/")) return true;
  if (/^skills\/[^/]+\/.+/.test(rel) && !/^skills\/[^/]+\/SKILL\.md$/.test(rel)) return true;
  if (rel.startsWith("hooks/")) {
    const hookScript = /^hooks\/([^/]+)\.sh$/.exec(rel);
    return !(hookScript && REMOVABLE_HOOK_SCRIPTS.has(hookScript[1]));
  }
  const agentFile = /^agents\/([^/]+)\.md$/.exec(rel);
  return Boolean(agentFile && PROTECTED_AGENTS.has(agentFile[1]));
}

// requireNothingProtected(profileName, profile): throws naming the first
// listed item, in any category, that the protected set covers.
function requireNothingProtected(profileName, profile) {
  const refuse = (kind, id) => { throw new ProfileError(`profile ${profileName} lists ${kind} ${id}, which is protected and can never be removed by a profile`); };
  for (const id of profile.rules) if (PROTECTED_RULES.has(id)) refuse("rule", id);
  for (const name of profile.hooks) if (PROTECTED_HOOKS.has(name)) refuse("hook", name);
  for (const name of profile.agents) if (PROTECTED_AGENTS.has(name)) refuse("agent", name);
  for (const rel of profile.files) if (isProtectedPath(rel)) refuse("file", rel);
}

// ProfileError: an unknown profile, a malformed profile file, or a listed id
// the source tree no longer holds.
export class ProfileError extends Error {}

// loadHarnessProfiles(file): the parsed profile file, shape-checked so every
// later step can read each kind as an array.
export function loadHarnessProfiles(file) {
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (err) { throw new ProfileError(`${file}: missing or unparseable (${err.message})`); }
  if (!parsed || typeof parsed.profiles !== "object") throw new ProfileError(`${file}: no profiles object`);
  for (const [name, profile] of Object.entries(parsed.profiles)) {
    for (const kind of PROFILE_KINDS) {
      if (!Array.isArray(profile[kind])) throw new ProfileError(`${file}: profile ${name} has no ${kind} array`);
    }
  }
  return parsed;
}

// loadSourceSet(claudeDir) -> Map<relPath, entry>: every file and symlink
// under claudeDir, keyed by its forward-slash path relative to it. A regular
// file is { content: Buffer, mode }; a symlink is { symlink: target }.
export function loadSourceSet(claudeDir) {
  const files = new Map();
  const walk = (relDir) => {
    for (const entry of fs.readdirSync(path.join(claudeDir, relDir), { withFileTypes: true })) {
      const rel = relDir ? `${relDir}/${entry.name}` : entry.name;
      const full = path.join(claudeDir, rel);
      if (entry.isSymbolicLink()) files.set(rel, { symlink: fs.readlinkSync(full) });
      else if (entry.isDirectory()) walk(rel);
      else if (entry.isFile()) files.set(rel, { content: fs.readFileSync(full), mode: fs.statSync(full).mode & 0o777 });
    }
  };
  walk("");
  return files;
}

// resolveProfile(profileName, profiles) -> profile object, or null for the
// identity (no name, or "full").
function resolveProfile(profileName, profiles) {
  if (profileName === undefined || profileName === null || profileName === "" || profileName === FULL_PROFILE) return null;
  const profile = profiles.profiles[profileName];
  if (!Object.prototype.hasOwnProperty.call(profiles.profiles, profileName) || !profile) {
    const known = [FULL_PROFILE, ...Object.keys(profiles.profiles)].join(", ");
    throw new ProfileError(`unknown harness profile "${profileName}" (known: ${known})`);
  }
  return profile;
}

// hookNameOf(command): the registered script's basename without .sh.
function hookNameOf(command) {
  const base = command.split("/").pop().split(" ")[0];
  return base.endsWith(".sh") ? base.slice(0, -3) : base;
}

// textOf(sourceSet, rel): a regular file's text, or a ProfileError when the
// profile must rewrite a file the set does not hold.
function textOf(sourceSet, rel) {
  const entry = sourceSet.get(rel);
  if (!entry || entry.content === undefined) throw new ProfileError(`${rel}: missing from the source set`);
  return entry.content.toString("utf8");
}

// filterClaudeMd(text, ruleIds) -> text without each listed rule's line;
// throws when an id does not start exactly one line.
function filterClaudeMd(text, ruleIds) {
  const lines = text.split("\n");
  const listed = new Set(ruleIds);
  for (const id of ruleIds) {
    const count = lines.filter((line) => RULE_LINE.exec(line)?.[1] === id).length;
    if (count !== 1) throw new ProfileError(`rule ${id}: expected one CLAUDE.md line starting with it, found ${count}`);
  }
  return lines.filter((line) => !listed.has(RULE_LINE.exec(line)?.[1])).join("\n");
}

// filterSettings(text, hookNames) -> settings.json text with every listed
// hook's registration removed from every event; a group left with no hook,
// and an event left with no group, are dropped. Throws when a listed hook is
// not registered (a protected hook never reaches here; see
// requireNothingProtected).
function filterSettings(text, hookNames) {
  const settings = JSON.parse(text);
  const registered = new Set();
  for (const groups of Object.values(settings.hooks ?? {})) {
    for (const group of groups) for (const hook of group.hooks ?? []) registered.add(hookNameOf(hook.command));
  }
  for (const name of hookNames) {
    if (!registered.has(name)) throw new ProfileError(`hook ${name}: not registered in settings.json`);
  }
  const dropped = new Set(hookNames);
  const hooks = {};
  for (const [event, groups] of Object.entries(settings.hooks ?? {})) {
    const kept = groups
      .map((group) => ({ ...group, hooks: (group.hooks ?? []).filter((hook) => !dropped.has(hookNameOf(hook.command))) }))
      .filter((group) => group.hooks.length > 0);
    if (kept.length > 0) hooks[event] = kept;
  }
  return `${JSON.stringify({ ...settings, hooks }, null, 2)}\n`;
}

// omittedPathsOf(profile, sourceSet) -> Set of rel paths the profile leaves
// out; throws naming the first listed skill, agent, or file the set lacks.
function omittedPathsOf(profile, sourceSet) {
  const omitted = new Set();
  const require = (kind, id, rel) => {
    if (!sourceSet.has(rel)) throw new ProfileError(`${kind} ${id}: ${rel} does not exist in claude/`);
    omitted.add(rel);
  };
  for (const name of profile.skills) require("skill", name, `skills/${name}/SKILL.md`);
  for (const name of profile.agents) require("agent", name, `agents/${name}.md`);
  for (const rel of profile.files) require("file", rel, rel);
  return omitted;
}

// applyProfile(profileName, sourceSet, profiles) -> { files, omitted }: the
// filtered source set (a new Map sharing every untouched entry) and the set
// of rel paths it left out. The identity returns sourceSet itself.
export function applyProfile(profileName, sourceSet, profiles) {
  const profile = resolveProfile(profileName, profiles);
  if (!profile) return { files: sourceSet, omitted: new Set() };
  requireNothingProtected(profileName, profile);
  const claudeMd = filterClaudeMd(textOf(sourceSet, "CLAUDE.md"), profile.rules);
  const settings = filterSettings(textOf(sourceSet, "settings.json"), profile.hooks);
  const omitted = omittedPathsOf(profile, sourceSet);
  const files = new Map();
  for (const [rel, entry] of sourceSet) {
    if (omitted.has(rel)) continue;
    if (rel === "CLAUDE.md") files.set(rel, { ...entry, content: Buffer.from(claudeMd) });
    else if (rel === "settings.json") files.set(rel, { ...entry, content: Buffer.from(settings) });
    else files.set(rel, entry);
  }
  return { files, omitted };
}

// writeSourceSet(files, dir): materializes a source set under dir.
export function writeSourceSet(files, dir) {
  for (const [rel, entry] of files) {
    const full = path.join(dir, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    if (entry.symlink !== undefined) fs.symlinkSync(entry.symlink, full);
    else {
      fs.writeFileSync(full, entry.content);
      fs.chmodSync(full, entry.mode);
    }
  }
}

// stageProfiledClaudeDir(rootDir, profileName) -> { claudeDir, omitted }:
// the exporters' entry point. The identity returns <rootDir>/claude itself,
// untouched, so an unprofiled run reads exactly what it always read; a real
// profile writes the filtered set to a temporary directory removed at exit.
export function stageProfiledClaudeDir(rootDir, profileName) {
  const claudeDir = path.join(rootDir, "claude");
  if (profileName === undefined || profileName === null || profileName === FULL_PROFILE) return { claudeDir, omitted: new Set() };
  const profiles = loadHarnessProfiles(path.join(claudeDir, PROFILES_RELATIVE_PATH));
  const { files, omitted } = applyProfile(profileName, loadSourceSet(claudeDir), profiles);
  const stagingRoot = fs.mkdtempSync(path.join(os.tmpdir(), "harness-profile-"));
  process.on("exit", () => fs.rmSync(stagingRoot, { recursive: true, force: true }));
  const stagedClaudeDir = path.join(stagingRoot, "claude");
  writeSourceSet(files, stagedClaudeDir);
  return { claudeDir: stagedClaudeDir, omitted };
}

// pruneEmptiedDirectories(root, removedFile): removes each directory above a
// removed file, up to root, that the removal left empty.
function pruneEmptiedDirectories(root, removedFile) {
  let dir = path.dirname(removedFile);
  while (dir.startsWith(`${root}${path.sep}`) && fs.readdirSync(dir).length === 0) {
    fs.rmdirSync(dir);
    dir = path.dirname(dir);
  }
}

// applyProfileInPlace(claudeDir, profileName, profilesFile): sync.sh's step.
// Filters a staged claude/ copy on disk: rewrites CLAUDE.md and settings.json
// and unlinks every omitted path. Validates fully before the first write.
export function applyProfileInPlace(claudeDir, profileName, profilesFile) {
  const profiles = loadHarnessProfiles(profilesFile);
  const sourceSet = loadSourceSet(claudeDir);
  const { files, omitted } = applyProfile(profileName, sourceSet, profiles);
  if (files === sourceSet) return;
  for (const rel of ["CLAUDE.md", "settings.json"]) fs.writeFileSync(path.join(claudeDir, rel), files.get(rel).content);
  for (const rel of omitted) {
    fs.unlinkSync(path.join(claudeDir, rel));
    pruneEmptiedDirectories(claudeDir, path.join(claudeDir, rel));
  }
}

// validateAllProfiles(rootDir) -> names: applies every profile to
// <rootDir>/claude, throwing on the first one that no longer fits the tree.
export function validateAllProfiles(rootDir) {
  const claudeDir = path.join(rootDir, "claude");
  const profiles = loadHarnessProfiles(path.join(claudeDir, PROFILES_RELATIVE_PATH));
  const sourceSet = loadSourceSet(claudeDir);
  const names = Object.keys(profiles.profiles);
  for (const name of names) applyProfile(name, sourceSet, profiles);
  return names;
}

// parseProfileCli(argv) -> { mode, profile, target, rootDir, profilesFile } or { error }.
function parseProfileCli(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--validate") { options.mode = "validate"; continue; }
    if (!["--profile", "--in-place", "--root", "--profiles"].includes(token)) return { error: `unrecognized argument "${token}"` };
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) return { error: `${token} needs a value` };
    options[token.slice(2)] = value;
    index += 1;
  }
  if (options.mode === "validate") return { mode: "validate", rootDir: options.root ?? path.resolve(fileURLToPath(import.meta.url), "../..") };
  if (!options.profile || !options["in-place"]) return { error: "pass --profile <name> --in-place <claude-dir>, or --validate [--root <repo-dir>]" };
  const target = options["in-place"];
  return { mode: "in-place", profile: options.profile, target, profilesFile: options.profiles ?? path.join(target, PROFILES_RELATIVE_PATH) };
}

// runProfileCli(argv): exit 0 on success, 2 on a usage or profile error.
function runProfileCli(argv) {
  const cli = parseProfileCli(argv);
  if (cli.error) {
    console.error(`apply-profile.mjs: ${cli.error}`);
    process.exit(2);
  }
  try {
    if (cli.mode === "validate") console.log(`profiles valid: ${validateAllProfiles(cli.rootDir).join(", ")}`);
    else applyProfileInPlace(cli.target, cli.profile, cli.profilesFile);
  } catch (err) {
    if (!(err instanceof ProfileError)) throw err;
    console.error(`apply-profile.mjs: ${err.message}`);
    process.exit(2);
  }
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) runProfileCli(process.argv.slice(2));
