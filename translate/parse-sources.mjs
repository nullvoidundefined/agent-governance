// parse-sources.mjs: reads and validates the translators' inputs; every
// failure is a SourceError naming the file, so codex.mjs and cursor.mjs can
// each exit 2 with it.
import fs from "node:fs";
import { renderGeneratedHeaderFor, SourceError } from "./exporter-core.mjs";

// SourceError now lives in exporter-core.mjs (this module's own
// claimPlannedPath needs to throw it too); re-exported here so every
// existing `import { SourceError } from "./parse-sources.mjs"` call site
// (codex.mjs, cursor.mjs, render-cursor-rules.mjs) stays valid unchanged.
export { SourceError };

export function splitFrontmatter(text, file) {
  const match = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  if (!match) throw new SourceError(file, "no frontmatter block");
  const fields = {};
  for (const line of match[1].split("\n")) {
    const kv = /^([A-Za-z-]+):\s*(.*)$/.exec(line);
    if (kv) fields[kv[1]] = kv[2];
  }
  if (!fields.name) throw new SourceError(file, "frontmatter has no name");
  return { frontmatter: fields, rawFrontmatter: match[1], body: text.slice(match[0].length) };
}

export function loadTextFile(file) {
  try { return fs.readFileSync(file, "utf8"); }
  catch { throw new SourceError(file, "missing or unreadable"); }
}

export function loadJsonFile(file) {
  let text;
  try { text = fs.readFileSync(file, "utf8"); }
  catch { throw new SourceError(file, "missing or unreadable"); }
  try { return JSON.parse(text); }
  catch (err) { throw new SourceError(file, `unparseable JSON (${err.message})`); }
}

export function loadSettingsHooks(file) {
  const settings = loadJsonFile(file);
  if (!settings.hooks) throw new SourceError(file, "no hooks object");
  return settings.hooks;
}

export function loadPortMap(file) {
  const map = loadJsonFile(file);
  for (const key of ["events", "unported_reasons", "agents_to_skills", "hand_authored"])
    if (!(key in map)) throw new SourceError(file, `port map missing ${key}`);
  if (!("port_status_appendix" in map)) map.port_status_appendix = "";
  return map;
}

// loadCursorPortMap(file): reads and validates the cursor port map's own
// schema, a distinct shape from codex's loadPortMap above (agents_to_
// subagents rather than agents_to_skills, an adapter_internal_events list
// for adapter-side-only events like beforeReadFile, and four hand-lifted
// prose fields the codex map has no equivalent of). Every key the exporter
// or a later renderer reads must be present, so a malformed or incomplete
// map fails fast here naming the file, rather than surfacing as undefined
// deep inside a render.
export function loadCursorPortMap(file) {
  const map = loadJsonFile(file);
  for (const key of [
    "hand_authored",
    "agents_to_subagents",
    "events",
    "adapter_internal_events",
    "unported_reasons",
    "rule_descriptions",
    "cursor_preamble",
    "index_trailing_paragraph",
    "port_status_appendix",
  ])
    if (!(key in map)) throw new SourceError(file, `port map missing ${key}`);
  return map;
}

// renderGeneratedHeader(source): the one GENERATED-header line every rendered
// codex/ file carries, naming the claude/ source it came from. Thin wrapper
// over exporter-core's builder-parameterized renderGeneratedHeaderFor, codex
// builder baked in, so call sites that have not moved to the parameterized
// form directly (render-codex-hooks.mjs, render-codex-rules.mjs) stay valid.
export function renderGeneratedHeader(source) {
  return renderGeneratedHeaderFor("translate/codex.mjs", source);
}

// hookNameFromCommand(command): the hook name is the basename of the
// registered command's script without its .sh extension, e.g.
// "~/.claude/hooks/alpha-guard.sh" -> "alpha-guard". Exported: both
// exporters' hooks.json renderers need the same name derivation as this
// file's own port checks.
export function hookNameFromCommand(command) {
  const base = command.split("/").pop();
  return base.endsWith(".sh") ? base.slice(0, -3) : base;
}

// hasUnportedReason(hookName, portMap): true when the port map's own
// unported_reasons object carries an entry for this hook. hasOwnProperty, not
// `in`: `in` walks the prototype chain, so a hook literally named "constructor"
// or "toString" read as carrying a reason it never had and dropped out of the
// generated Codex hooks (audit P3-1 fixed this in codex.mjs's closure check and
// left it standing here, reported on PR #8). Every classification path asks
// this one function so the two answers cannot diverge again.
export function hasUnportedReason(hookName, portMap) {
  return Object.prototype.hasOwnProperty.call(portMap.unported_reasons, hookName);
}

// isRegistrationPorted(hookName, event, portMap): true when this specific
// Claude Code event's registration of hookName would carry into Codex: the
// hook has no unported reason, and this event maps to a real Codex event.
// Registration-scoped, unlike isHookPorted's whole-hook "ported somewhere"
// answer, so a hook registered under both a ported and an unported event
// gets the right answer for each (the PORT-STATUS.md renderer needs one row
// per registration, not one row per hook).
export function isRegistrationPorted(hookName, event, portMap) {
  if (hasUnportedReason(hookName, portMap)) return false;
  return portMap.events[event] != null;
}

// isHookPorted(hookName, settingsHooks, portMap): a hook is ported when at
// least one of its settings.json registrations sits under an event whose
// port-map events entry is non-null, and the hook is not listed in
// portMap.unported_reasons. Codex-specific (cursor's per-matcher fan-out
// needs isHookPortedForCursor below instead): shared by codex's AGENTS.md
// tag rewriter and its hooks.json renderer.
export function isHookPorted(hookName, settingsHooks, portMap) {
  for (const [event, groups] of Object.entries(settingsHooks)) {
    for (const group of groups) {
      for (const hook of group.hooks ?? []) {
        if (hookNameFromCommand(hook.command) === hookName && isRegistrationPorted(hookName, event, portMap)) return true;
      }
    }
  }
  return false;
}

// isRegistrationPortedForCursor(event, matcher, portMap): true when this
// specific (event, matcher) registration fans out to at least one Cursor
// event, per the cursor port map's per-matcher events shape (distinct from
// codex's flat per-event map, which isRegistrationPorted above reads).
// Lookup order: the literal matcher key in portMap.events[event] when that
// key is actually present (own-property, not inherited), so an empty-string
// matcher ("") is a real distinct row from a matcher the map never
// mentions; only when no literal key exists does the row's "*" wildcard
// entry apply; when neither exists there is no fan-out at all. A row whose
// value is present but empty (e.g. ConfigChange's "*": []) counts as no
// fan-out too, not as "matched but silent".
export function isRegistrationPortedForCursor(event, matcher, portMap) {
  const eventMap = portMap.events[event];
  if (!eventMap) return false;
  const cursorEvents = Object.prototype.hasOwnProperty.call(eventMap, matcher) ? eventMap[matcher] : eventMap["*"];
  return Array.isArray(cursorEvents) && cursorEvents.length > 0;
}

// hasWholeHookVeto(hookName, portMap): true when hookName's unported_reasons
// entry is a plain string, meaning every registration of this hook is
// treated as not-porting no matter what its own event/matcher row in
// portMap.events would otherwise suggest. This is needed for a hook like
// post-compact-rules, whose only registration (SessionStart, matcher
// "compact") would otherwise read as porting through that event's broader
// "*" wildcard fallback, even though compaction genuinely has no Cursor
// equivalent. An object-valued entry (verification-gate: Stop ports,
// SubagentStop does not) carries no veto here; portMap.events' own
// per-event/matcher rows already draw the line correctly for those hooks,
// and vetoing the whole hook would wrongly mark the porting registration as
// unported too (a hook-level reason overriding a real per-event port).
export function hasWholeHookVeto(hookName, portMap) {
  return typeof portMap.unported_reasons[hookName] === "string";
}

// unportedReasonFor(hookName, event, portMap) -> string|undefined: the
// human-readable reason to show for one specific unported registration. A
// string-valued unported_reasons entry (the whole-hook veto case above)
// applies to every event that hook is registered under; an object-valued
// entry applies only to the event key(s) it names, so a hook like
// verification-gate can carry a SubagentStop-specific reason while its Stop
// registration, already ported, never reaches this lookup at all (callers
// only consult it once a registration's Cursor fan-out is already empty).
export function unportedReasonFor(hookName, event, portMap) {
  const entry = portMap.unported_reasons[hookName];
  if (typeof entry === "string") return entry;
  if (entry && typeof entry === "object") return entry[event];
  return undefined;
}

// isHookPortedForCursor(hookName, settingsHooks, portMap): a hook is ported
// for Cursor when at least one of its settings.json registrations yields a
// non-empty Cursor event list (isRegistrationPortedForCursor) and that
// registration's event carries no whole-hook veto (hasWholeHookVeto).
// Portedness is per-hook, not per-registration: a hook registered under
// both a porting and a non-porting event/matcher (the verification-gate
// Stop/SubagentStop shape) still counts as ported once any one registration
// ports, mirroring isHookPorted's whole-hook "ported somewhere" answer
// above the cursor-specific per-matcher lookup.
export function isHookPortedForCursor(hookName, settingsHooks, portMap) {
  if (hasWholeHookVeto(hookName, portMap)) return false;
  for (const [event, groups] of Object.entries(settingsHooks)) {
    for (const group of groups) {
      for (const hook of group.hooks ?? []) {
        if (hookNameFromCommand(hook.command) !== hookName) continue;
        if (isRegistrationPortedForCursor(event, group.matcher ?? "", portMap)) return true;
      }
    }
  }
  return false;
}
