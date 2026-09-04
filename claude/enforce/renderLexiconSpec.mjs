/**
 * Renders the R-316 verb-lexicon bullets in rulebook/reference.md from
 * enforce/lexicon.json, so the prose and the registry cannot disagree.
 *
 * They already had. The registry banned 22 synonyms while the hand-written
 * bullet listed 6, and an earlier draft of the registry banned `fetch`, `drop`
 * and `remove` that the same bullet explicitly approved (2026-09-04 config
 * audit, filed as a P3). "Edit both together" is a recall instruction, which is
 * exactly the class of rule this repo is trying to stop relying on.
 *
 *   node enforce/renderLexiconSpec.mjs            print the canonical block
 *   node enforce/renderLexiconSpec.mjs --write    rewrite reference.md in place
 *   node enforce/renderLexiconSpec.mjs --check    exit 1 if reference.md differs
 *
 * The block lives between the two markers below. Everything outside them stays
 * hand-written: the policy and its rationale are prose worth reading, only the
 * enumerated sets are generated.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const BEGIN_MARKER = "    <!-- lexicon:begin -->";
const END_MARKER = "    <!-- lexicon:end -->";
const INDENT = "    ";

const lexiconPath = fileURLToPath(new URL("./lexicon.json", import.meta.url));
const referencePath = fileURLToPath(new URL("../rulebook/reference.md", import.meta.url));

/**
 * Rejects a registry that contradicts itself. Found while writing the sync
 * fixture: banning `fetch` while `verbGroups.read` and `scopeVerbs` still bound
 * it to clients/ produced prose that listed the same verb as both the layer's
 * read verb and a banned synonym, and nothing complained. A registry that is
 * the single source of truth has to be internally coherent first.
 */
function validateLexicon(lexicon) {
  const approved = new Set(lexicon.verbs ?? []);
  const banned = new Set(Object.keys(lexicon.bannedVerbs ?? {}));
  const problems = [];

  for (const verb of approved) {
    if (banned.has(verb)) problems.push(`"${verb}" is both approved and banned`);
  }
  for (const [group, verbs] of Object.entries(lexicon.verbGroups ?? {})) {
    for (const verb of verbs) {
      if (!approved.has(verb)) problems.push(`verbGroups.${group} names "${verb}", which is not an approved verb`);
    }
  }
  for (const verb of Object.keys(lexicon.verbScopes ?? {})) {
    if (!approved.has(verb)) problems.push(`verbScopes names "${verb}", which is not an approved verb`);
  }
  for (const [group, verb] of Object.entries(lexicon.defaultVerbs ?? {})) {
    if (!approved.has(verb)) problems.push(`defaultVerbs.${group} is "${verb}", which is not an approved verb`);
    if (!(lexicon.verbGroups?.[group] ?? []).includes(verb)) {
      problems.push(`defaultVerbs.${group} is "${verb}", which is not a member of verbGroups.${group}`);
    }
  }
  for (const [directory, groups] of Object.entries(lexicon.scopeVerbs ?? {})) {
    for (const [group, verb] of Object.entries(groups)) {
      if (!approved.has(verb)) problems.push(`scopeVerbs.${directory}.${group} is "${verb}", which is not an approved verb`);
      if (!(lexicon.verbGroups?.[group] ?? []).includes(verb)) {
        problems.push(`scopeVerbs.${directory}.${group} is "${verb}", which is not a member of verbGroups.${group}`);
      }
    }
  }
  for (const [verb, scope] of Object.entries(lexicon.verbScopes ?? {})) {
    if (!approved.has(scope.fallback)) {
      problems.push(`verbScopes.${verb}.fallback is "${scope.fallback}", which is not an approved verb`);
    }
  }
  return problems;
}

/** `a`, `b` and `c` */
function formatList(values) {
  const quoted = [...values].sort().map((value) => `\`${value}\``);
  if (quoted.length <= 1) return quoted.join("");
  return `${quoted.slice(0, -1).join(", ")} and ${quoted.at(-1)}`;
}

/** Directories a scope table binds a given group verb to. */
function directoriesFor(scopeVerbs, group, verb) {
  return Object.entries(scopeVerbs)
    .filter(([, groups]) => groups[group] === verb)
    .map(([directory]) => `${directory}/`)
    .sort();
}

/** The reads bullet: default verb, then each layer-bound alternative. */
function renderReads(lexicon) {
  const readVerbs = lexicon.verbGroups?.read ?? [];
  const fallback = lexicon.defaultVerbs?.read;
  const bound = readVerbs
    .filter((verb) => verb !== fallback)
    .map((verb) => `\`${verb}\` under ${formatList(directoriesFor(lexicon.scopeVerbs ?? {}, "read", verb))}`)
    .sort();
  return `${INDENT}- Reads: \`${fallback}\` by default; ${bound.join("; ")}. Using another layer's read verb is a violation, not a preference. \`list\` stays unrestricted: it encodes cardinality, not transport.`;
}

/** The reserved-verb bullet: verbs legal only inside named trees. */
function renderScoped(lexicon) {
  const entries = Object.entries(lexicon.verbScopes ?? {})
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([verb, scope]) => {
      const directories = formatList(scope.directories.map((directory) => `${directory}/`));
      return `\`${verb}\` only under ${directories} (use \`${scope.fallback}\` elsewhere)`;
    });
  return `${INDENT}- Reserved to a tree: ${entries.join("; ")}.`;
}

/** The banned bullet, grouped by canonical replacement to stay readable. */
function renderBanned(lexicon) {
  const byReplacement = new Map();
  for (const [banned, replacement] of Object.entries(lexicon.bannedVerbs ?? {})) {
    if (!byReplacement.has(replacement)) byReplacement.set(replacement, []);
    byReplacement.get(replacement).push(banned);
  }
  const groups = [...byReplacement.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([replacement, banned]) => {
      const target = lexicon.verbs.includes(replacement) ? `use \`${replacement}\`` : replacement;
      return `${formatList(banned)} (${target})`;
    });
  return `${INDENT}- Banned as bare synonyms: ${groups.join("; ")}.`;
}

/** The whole generated block, markers included. */
function renderBlock(lexicon) {
  return [
    BEGIN_MARKER,
    `${INDENT}<!-- Generated from enforce/lexicon.json by renderLexiconSpec.mjs. Do not hand-edit: change the registry and run --write. -->`,
    renderReads(lexicon),
    renderScoped(lexicon),
    renderBanned(lexicon),
    `${INDENT}- Approved verbs (${lexicon.verbs.length} in total) and boolean prefixes ${formatList(lexicon.booleanPrefixes)} live in the registry; this list is its rendering, not a second copy.`,
    END_MARKER,
  ].join("\n");
}

/** The block currently sitting in reference.md, or null when absent. */
function extractBlock(referenceText) {
  const start = referenceText.indexOf(BEGIN_MARKER);
  const end = referenceText.indexOf(END_MARKER);
  if (start === -1 || end === -1) return null;
  return referenceText.slice(start, end + END_MARKER.length);
}

const lexicon = JSON.parse(readFileSync(lexiconPath, "utf8"));

const lexiconProblems = validateLexicon(lexicon);
if (lexiconProblems.length > 0) {
  console.error("renderLexiconSpec: enforce/lexicon.json contradicts itself:");
  for (const problem of lexiconProblems) console.error(`  - ${problem}`);
  process.exit(1);
}

const expected = renderBlock(lexicon);
const mode = process.argv[2] ?? "--print";

if (mode === "--print") {
  process.stdout.write(`${expected}\n`);
  process.exit(0);
}

const referenceText = readFileSync(referencePath, "utf8");
const actual = extractBlock(referenceText);

if (actual === null) {
  console.error(`renderLexiconSpec: markers not found in ${referencePath}. Expected ${BEGIN_MARKER.trim()} and ${END_MARKER.trim()}.`);
  process.exit(1);
}

if (mode === "--write") {
  if (actual === expected) {
    console.log("renderLexiconSpec: reference.md already matches the registry.");
    process.exit(0);
  }
  writeFileSync(referencePath, referenceText.replace(actual, expected));
  console.log("renderLexiconSpec: rewrote the R-316 lexicon block from lexicon.json. Commit both.");
  process.exit(0);
}

if (mode === "--check") {
  if (actual === expected) process.exit(0);
  console.error("renderLexiconSpec: rulebook/reference.md disagrees with enforce/lexicon.json (R-316).\n");
  console.error("--- reference.md has ---");
  console.error(actual);
  console.error("\n--- the registry renders ---");
  console.error(expected);
  console.error("\nRun: node enforce/renderLexiconSpec.mjs --write");
  process.exit(1);
}

console.error(`renderLexiconSpec: unknown mode ${mode}; expected --print, --write or --check.`);
process.exit(1);
