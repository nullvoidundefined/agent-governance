// render-cursor-hooks.mjs: derives cursor/hooks.json (the adapter wiring
// Cursor runs hooks through) and cursor/PORT-STATUS.md (the human-readable
// audit of every settings.json hook registration) from claude/settings.json
// and the cursor port map, so neither file drifts from what settings.json
// actually registers. Unlike codex's one-Claude-event-to-one-Codex-event
// map, the cursor port map is many-to-many (cursor-shapes-study section 4):
// one (event, matcher) settings.json row can fan into several Cursor
// events (secret-scan, no-em-dash), and several settings.json rows can
// feed the same Cursor event (afterFileEdit aggregates a PreToolUse
// Write|Edit registration and a PostToolUse Write|Edit registration).
// adapter_internal_events (beforeReadFile) never carry hook names: the
// adapter mirrors settings.json's permissions.deny Read rules itself, with
// no settings.json hook registration behind that event at all.
import { renderGeneratedHeaderFor } from "./exporter-core.mjs";
import { hookNameFromCommand, hasWholeHookVeto, unportedReasonFor } from "./parse-sources.mjs";

const BUILDER_NAME = "translate/cursor.mjs";
const ADAPTER_COMMAND = "~/.cursor/hooks/claude-hook-adapter.sh";
const DEFAULT_TIMEOUT = 30;

// CURSOR_EVENT_ORDER: the canonical Cursor-native event vocabulary, in the
// order the real cursor/hooks.json declares it (cursor-shapes-study
// section 4, verified against cursor/hooks.json directly). Iterating
// settingsHooks' own key order (PreToolUse, PostToolUse, SessionStart, ...)
// and emitting each Cursor event on first appearance instead produces a
// different order (beforeShellExecution, afterFileEdit, preToolUse,
// beforeMCPExecution, afterShellExecution, sessionStart, sessionEnd, stop)
// that does not match the real file, so the top-level hooks.json key order
// is this fixed vocabulary list, independent of settings.json's own
// declaration order. Any Cursor event the port map names that is not in
// this list still gets an entry (appended after, sorted) rather than being
// silently dropped; it just cannot claim the canonical position.
const CURSOR_EVENT_ORDER = [
  "sessionStart",
  "beforeShellExecution",
  "afterShellExecution",
  "beforeMCPExecution",
  "preToolUse",
  "afterFileEdit",
  "beforeReadFile",
  "stop",
  "sessionEnd",
];

// CURSOR_EVENT_TIMEOUTS: the per-event timeout (seconds) the real
// cursor/hooks.json uses, hand-tuned per event kind (beforeShellExecution
// runs the push-time linters, so it gets the longest budget short of stop;
// stop runs the full verification gate; beforeReadFile only mirrors a
// permissions.deny table, so it gets the shortest). Not derivable from
// settings.json (a single Cursor event aggregates registrations that had
// different original timeouts), so this is fixed reference data, not
// rendered content; an event not in this table (should never happen, since
// every entry emitted comes from CURSOR_EVENT_ORDER or an unexpected value
// appended after it) falls back to DEFAULT_TIMEOUT.
const CURSOR_EVENT_TIMEOUTS = {
  sessionStart: 30,
  beforeShellExecution: 180,
  afterShellExecution: 30,
  beforeMCPExecution: 30,
  preToolUse: 30,
  afterFileEdit: 60,
  beforeReadFile: 10,
  stop: 660,
  sessionEnd: 60,
};

// cursorEventsForRegistration(hookName, event, matcher, portMap): the
// Cursor events one settings.json (event, matcher) registration of
// hookName fans into, or [] when it fans nowhere. Layers two checks: the
// whole-hook veto gate (hasWholeHookVeto: a hook whose unported_reasons
// entry is a plain string never ports under any registration, whatever its
// events row might otherwise suggest: post-compact-rules' SessionStart/
// compact registration would read as porting to sessionStart through the
// row's "*" wildcard fallback if this gate were skipped, since compaction
// genuinely has no ported behavior), then the per-matcher events lookup
// itself: the literal matcher key when portMap.events[event] actually owns
// it (so an empty-string matcher is a real distinct row, not "unset"), else
// that event's "*" wildcard row, else no fan-out at all. A hook whose
// unported_reasons entry is an object instead (verification-gate) carries
// no veto here; its per-event/matcher row in portMap.events already draws
// the Stop-ports/SubagentStop-does-not line correctly on its own. Same
// lookup rule parse-sources.mjs's isRegistrationPortedForCursor documents,
// reimplemented here (rather than called) because this needs the actual
// event list, not a boolean, with the veto gate layered on top the way
// codex's isRegistrationPorted layers it over its own flat map.
function cursorEventsForRegistration(hookName, event, matcher, portMap) {
  if (hasWholeHookVeto(hookName, portMap)) return [];
  const eventMap = portMap.events[event];
  if (!eventMap) return [];
  const cursorEvents = Object.prototype.hasOwnProperty.call(eventMap, matcher) ? eventMap[matcher] : eventMap["*"];
  return Array.isArray(cursorEvents) ? cursorEvents : [];
}

// buildRegistrationRows(settingsHooks, portMap): one row per settings.json
// hook registration, in registration order (source event order, then
// matcher-group order, then within-group hook order), carrying everything
// both renderers below need: the hook name, the originating Claude Code
// event and matcher, and the full list of Cursor events this registration
// fans into (possibly several, possibly none).
function buildRegistrationRows(settingsHooks, portMap) {
  const rows = [];
  for (const [event, groups] of Object.entries(settingsHooks)) {
    for (const group of groups) {
      const matcher = group.matcher ?? "";
      for (const hook of group.hooks ?? []) {
        const hookName = hookNameFromCommand(hook.command);
        const cursorEvents = cursorEventsForRegistration(hookName, event, matcher, portMap);
        rows.push({ hookName, event, matcher, cursorEvents, ported: cursorEvents.length > 0 });
      }
    }
  }
  return rows;
}

// buildHookEntry(cursorEvent, names): one hooks.json array entry for a
// single Cursor event: the adapter invocation naming the event and every
// hook that fans into it (zero names for an adapter-internal event), plus
// that event's fixed timeout.
function buildHookEntry(cursorEvent, names) {
  const command = [ADAPTER_COMMAND, cursorEvent, ...names].join(" ");
  const timeout = CURSOR_EVENT_TIMEOUTS[cursorEvent] ?? DEFAULT_TIMEOUT;
  return [{ command, timeout }];
}

// renderCursorHooksConfig(settingsHooks, portMap) -> { path: "hooks.json",
// content }: one adapter entry per Cursor event that either has at least
// one ported registration fanning into it, or is listed in
// adapter_internal_events. Hook names within one entry aggregate every
// registration whose (event, matcher) row includes that Cursor event, in
// settings registration order (buildRegistrationRows' own order); an
// adapter-internal event always gets zero names, even if some future port
// map entry accidentally fanned a hook into it. Event order is
// CURSOR_EVENT_ORDER's fixed vocabulary, not settings.json's own key
// order (see that constant's comment); an event outside the vocabulary
// still gets an entry, appended afterward and sorted, rather than being
// dropped.
export function renderCursorHooksConfig(settingsHooks, portMap) {
  const rows = buildRegistrationRows(settingsHooks, portMap);
  const namesByCursorEvent = new Map();
  for (const row of rows) {
    for (const cursorEvent of row.cursorEvents) {
      if (!namesByCursorEvent.has(cursorEvent)) namesByCursorEvent.set(cursorEvent, []);
      namesByCursorEvent.get(cursorEvent).push(row.hookName);
    }
  }
  const adapterInternalEvents = new Set(portMap.adapter_internal_events);
  const neededEvents = new Set([...namesByCursorEvent.keys(), ...adapterInternalEvents]);
  const orderedEvents = [
    ...CURSOR_EVENT_ORDER.filter((event) => neededEvents.has(event)),
    ...[...neededEvents].filter((event) => !CURSOR_EVENT_ORDER.includes(event)).sort(),
  ];
  const hooks = {};
  for (const cursorEvent of orderedEvents) {
    const names = adapterInternalEvents.has(cursorEvent) ? [] : (namesByCursorEvent.get(cursorEvent) ?? []);
    hooks[cursorEvent] = buildHookEntry(cursorEvent, names);
  }
  const content = `${JSON.stringify({ version: 1, hooks }, null, 2)}\n`;
  return { path: "hooks.json", content };
}

// formatClaudeCodeEvent(event, matcher): the "Claude Code event" column,
// e.g. "PreToolUse (Bash)" when the registration carries a matcher, else
// just the bare event name.
function formatClaudeCodeEvent(event, matcher) {
  return matcher ? `${event} (${matcher})` : event;
}

// formatUnderCursor(hookName, cursorEvents, event, portMap): the "Under
// Cursor" column for one registration row. A ported row names every
// Cursor event it fans to (not just one, unlike codex's single-target
// column); an unported row carries the hook's reason from the port map
// (unportedReasonFor: a whole-hook string, or the event-scoped text from an
// object-valued entry such as verification-gate's SubagentStop row),
// falling back to a generic "no Cursor equivalent" message naming the
// Claude Code event that has none.
function formatUnderCursor(hookName, cursorEvents, event, portMap) {
  if (cursorEvents.length > 0) {
    return `ported: ${cursorEvents.map((cursorEvent) => `\`${cursorEvent}\``).join(", ")}`;
  }
  const reason = unportedReasonFor(hookName, event, portMap) ?? `the ${event} event has no Cursor equivalent.`;
  return `not ported: ${reason}`;
}

// renderPortStatusTable(rows, portMap): the Markdown table body, one row
// per registration, in the order buildRegistrationRows produced them.
function renderPortStatusTable(rows, portMap) {
  return [
    "| Hook | Claude Code event | Under Cursor |",
    "|---|---|---|",
    ...rows.map((row) =>
      `| \`${row.hookName}\` | ${formatClaudeCodeEvent(row.event, row.matcher)} | ${formatUnderCursor(row.hookName, row.cursorEvents, row.event, portMap)} |`,
    ),
  ].join("\n");
}

// renderCursorPortStatus(settingsHooks, portMap) -> {
// path: "PORT-STATUS.md", content }: one table row per settings.json
// registration, plus a summary line whose counts are computed from the
// same rows and the same event set hooks.json renders, never hand-typed.
// The Cursor-event count is the size of the union of every ported row's
// fan-out events and adapter_internal_events, i.e. exactly the set of
// top-level keys renderCursorHooksConfig emits, so the two files can never
// disagree about how many Cursor events the port reaches. A non-empty
// portMap.port_status_appendix (the hand-authored Permission-rules prose
// the generator cannot derive) appends verbatim after the table.
export function renderCursorPortStatus(settingsHooks, portMap) {
  const rows = buildRegistrationRows(settingsHooks, portMap);
  const portedRows = rows.filter((row) => row.ported);
  const cursorEventSet = new Set(portMap.adapter_internal_events);
  for (const row of portedRows) for (const cursorEvent of row.cursorEvents) cursorEventSet.add(cursorEvent);
  const summaryLine = `${portedRows.length} of ${rows.length} hook registrations port, across ${cursorEventSet.size} Cursor events.`;
  const appendix = portMap.port_status_appendix ? `\n\n${portMap.port_status_appendix}` : "";
  const header = renderGeneratedHeaderFor(BUILDER_NAME, "settings.json");
  const content = `${header}\n\n# Cursor port status\n\n${summaryLine}\n\n${renderPortStatusTable(rows, portMap)}${appendix}\n`;
  return { path: "PORT-STATUS.md", content };
}
