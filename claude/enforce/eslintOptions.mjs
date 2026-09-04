/**
 * Builds the ESLint Node-API options shared by lint.mjs (single-file gate) and
 * ratchet.mjs (full-tree baseline). Both must activate the identical rule set,
 * or the ratchet would count violations the push gate never reports and the
 * baseline would be meaningless.
 *
 * Two rules are opt-in per repo, because both need vocabulary only the repo
 * can supply:
 *   R-303  import zones, from .enforce.json importZones
 *   R-316  the naming lexicon, from .enforce.json naming
 * A repo with neither key gets the same behavior it had before either existed.
 *
 * R-325 is on by default: a 2+ property read is the same defect in every
 * codebase and needs no project vocabulary. The push gate scopes it to added
 * lines (lint.mjs --added-only) and ratchet.mjs grandfathers existing debt.
 *
 * R-320 is opt-in (.enforce.json fileHeaders), which is a correction rather
 * than a preference. Shipped default-on first, and the fixture suite failed in
 * five places: every minimal fixture written to test some OTHER rule suddenly
 * needed a header. That is the honest signal that "every module carries a
 * header" is a project convention with a large adoption cost, not a universal
 * defect, and its exemption list varies by codebase. Editing thirty fixtures to
 * satisfy a rule those tests are not about would have hidden that.
 */
import { createNodeResolver, importX } from "eslint-plugin-import-x";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import destructureObjectReads from "./rules/destructure-object-reads.mjs";
import fileHeaderComment from "./rules/file-header-comment.mjs";
import namingLexicon from "./rules/naming-lexicon.mjs";

const configPath = fileURLToPath(new URL("./eslint.config.mjs", import.meta.url));
const lexiconPath = fileURLToPath(new URL("./lexicon.json", import.meta.url));

/** Reads .enforce.json from a repo root; absent or malformed yields {}. */
function readEnforceConfig(repoRoot) {
  try {
    return JSON.parse(readFileSync(`${repoRoot}/.enforce.json`, "utf8"));
  } catch {
    return {};
  }
}

/** Resolves the R-303 import zones to absolute paths, or [] when not declared. */
function collectImportZones(enforceConfig, repoRoot) {
  if (!Array.isArray(enforceConfig.importZones) || enforceConfig.importZones.length === 0) {
    return [];
  }
  return enforceConfig.importZones.map((zone) => ({
    from: resolve(repoRoot, zone.from),
    message: zone.message,
    target: resolve(repoRoot, zone.target),
  }));
}

/**
 * Merges the shipped lexicon with the repo's naming key, or returns null when
 * the repo has not opted in. A repo list REPLACES the shipped list for that
 * field; `extend` adds to it instead, so a project can add three domain verbs
 * without restating fifty.
 */
function buildNamingOptions(enforceConfig) {
  const naming = enforceConfig.naming;
  if (!naming || naming.enabled === false) return null;

  const shipped = JSON.parse(readFileSync(lexiconPath, "utf8"));
  const extend = naming.extend ?? {};
  const merged = {};
  for (const field of ["verbs", "booleanPrefixes", "bareAdjectives", "irregularPlurals"]) {
    const base = naming[field] ?? shipped[field] ?? [];
    merged[field] = [...new Set([...base, ...(extend[field] ?? [])])].sort();
  }
  // Map-valued fields, including the layer scoping that disambiguates the read
  // synonyms. Each merges key by key, so a repo can retarget one verb without
  // restating the table.
  for (const field of ["bannedVerbs", "defaultVerbs", "scopeVerbs", "verbGroups", "verbScopes"]) {
    merged[field] = { ...(naming[field] ?? shipped[field] ?? {}), ...(extend[field] ?? {}) };
  }
  // The glossary is never shipped: it is the project's own domain vocabulary
  // (R-330). Absent means head-noun checking is skipped, not that it passes.
  merged.glossary = [...new Set([...(naming.glossary ?? []), ...(extend.glossary ?? [])])].sort();
  return merged;
}

/** ESLint options for a repo root, with the opt-in rules wired when declared. */
export function buildEslintOptions(repoRoot) {
  const enforceConfig = readEnforceConfig(repoRoot);
  const overrideConfig = [];

  const importZones = collectImportZones(enforceConfig, repoRoot);
  if (importZones.length > 0) {
    overrideConfig.push({
      files: ["**/*.ts", "**/*.tsx"],
      plugins: { "import-x": importX },
      rules: { "import-x/no-restricted-paths": ["error", { zones: importZones }] },
      settings: { "import-x/resolver-next": [createNodeResolver({ extensions: [".js", ".ts", ".tsx"] })] },
    });
  }

  const namingOptions = buildNamingOptions(enforceConfig);
  if (namingOptions) {
    overrideConfig.push({
      files: ["**/*.ts", "**/*.tsx"],
      ignores: [
        "**/__tests__/**",
        "**/__fixtures__/**",
        "**/__mocks__/**",
        "**/tests/**",
        "**/e2e/**",
        "**/*.test.ts",
        "**/*.test.tsx",
        "**/*.d.ts",
      ],
      // Namespace "lexicon", not "local": eslint.config.mjs already defines
      // "local" for one-export-per-file, and flat config refuses to redefine a
      // plugin namespace.
      plugins: { lexicon: { rules: { naming: namingLexicon } } },
      rules: { "lexicon/naming": ["error", namingOptions] },
    });
  }

  // Path skips mirror hooks/new-file-header-reminder.sh, so the two enforcers of
  // R-320 never disagree about which files are in scope.
  const CONVENTION_IGNORES = [
    "**/__tests__/**",
    "**/__fixtures__/**",
    "**/__mocks__/**",
    "**/tests/**",
    "**/e2e/**",
    "**/migrations/**",
    "**/*.test.ts",
    "**/*.test.tsx",
    "**/*.spec.ts",
    "**/*.spec.tsx",
    "**/*.stories.ts",
    "**/*.stories.tsx",
    "**/*.config.ts",
    "**/*.d.ts",
  ];
  const conventionPlugin = {
    convention: {
      rules: {
        "destructure-object-reads": destructureObjectReads,
        "file-header-comment": fileHeaderComment,
      },
    },
  };

  overrideConfig.push({
    files: ["**/*.ts", "**/*.tsx"],
    ignores: CONVENTION_IGNORES,
    plugins: conventionPlugin,
    rules: { "convention/destructure-object-reads": "error" },
  });

  if (enforceConfig.fileHeaders === true) {
    overrideConfig.push({
      files: ["**/*.ts", "**/*.tsx"],
      ignores: CONVENTION_IGNORES,
      rules: { "convention/file-header-comment": "error" },
    });
  }

  const options = { cwd: "/", overrideConfigFile: configPath };
  if (overrideConfig.length > 0) options.overrideConfig = overrideConfig;
  return options;
}
