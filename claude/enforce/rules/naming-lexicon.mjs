/**
 * Custom ESLint rule making R-316 and the decidable half of R-317 deterministic.
 *
 * "Is this a good name" is undecidable, so this rule never asks it. It asks set
 * membership against a checked-in registry (enforce/lexicon.json, extended per
 * repo through the naming key in .enforce.json), which is a pure function of
 * (AST, config) and therefore reproducible on every machine and every run.
 *
 * What it decides:
 *   R-316  a named function is <verb><Noun>: the leading word is in the verb
 *          lexicon or is a boolean prefix, a noun follows it, the verb is not a
 *          banned synonym of a canonical verb, and a function annotated
 *          `: boolean` leads with is/has/can/should
 *   R-316  a layer-bound verb appears only under the directory that gives it
 *          meaning (`insert`/`upsert`/`drop` in repositories/database), and the
 *          read verb is the one that layer fixes: `fetch` under clients/api
 *          (remote), `load` under repositories/database/config/prompts (at
 *          rest), `get` everywhere else. Four interchangeable read verbs is a
 *          four-way drift surface; binding each to a layer makes "remote" vs
 *          "in memory" decidable from the path instead of from intent. `list`
 *          stays free: it encodes cardinality, not transport.
 *   R-316  with a glossary configured, the head noun is a declared domain term,
 *          which is what stops `generatePublicMemo` drifting from `...Note`
 *   R-317  a variable bound to an array literal or a .map()/.filter() result is
 *          named in the plural
 *   R-317  a single-word variable is not a bare adjective (`scoredJob`, never
 *          `scored`)
 *
 * What it deliberately does NOT decide: whether the lexicon itself carves the
 * domain well, whether a name is meaningful, or R-318/R-322 (one responsibility),
 * which are undecidable and stay advisory rather than being faked with a proxy.
 *
 * PascalCase identifiers are skipped: React components, classes, and type
 * constructors are nouns by convention, not verb phrases.
 */

const PASCAL_CASE_PATTERN = /^[A-Z]/;
const SCREAMING_SNAKE_PATTERN = /^[A-Z0-9_]+$/;
const COLLECTION_METHOD_NAMES = new Set(["filter", "map", "toSorted", "toReversed"]);

/** Splits an identifier into lowercase words, keeping acronyms whole. */
function splitIdentifier(name) {
  const words = name.replace(/^_+/, "").match(/[A-Z]{2,}(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+/g);
  return words ? words.map((word) => word.toLowerCase()) : [];
}

/** True when the declared return type is literally `boolean`. */
function hasBooleanReturnAnnotation(node) {
  return node?.returnType?.typeAnnotation?.type === "TSBooleanKeyword";
}

/** True when the initializer is an array literal or an array-producing call. */
function producesCollection(init) {
  if (!init) return false;
  if (init.type === "ArrayExpression") return true;
  if (init.type === "AwaitExpression") return producesCollection(init.argument);
  return (
    init.type === "CallExpression" &&
    init.callee.type === "MemberExpression" &&
    init.callee.property.type === "Identifier" &&
    COLLECTION_METHOD_NAMES.has(init.callee.property.name)
  );
}

/** Path segments of a file, so layer membership is an exact-segment test. */
function pathSegments(filename) {
  return filename.split(/[\\/]/).filter((segment) => segment !== "");
}

/** The innermost directory along the path that declares scoped verbs. */
function innermostScope(filename, scopeVerbs) {
  const segments = pathSegments(filename);
  for (let index = segments.length - 1; index >= 0; index -= 1) {
    if (Object.hasOwn(scopeVerbs, segments[index])) return scopeVerbs[segments[index]];
  }
  return null;
}

/** The function-like node behind a declarator, or null when it is not one. */
function functionBehindDeclarator(declarator) {
  const init = declarator.init;
  if (!init) return null;
  const unwrapped = init.type === "TSAsExpression" ? init.expression : init;
  const isFunction =
    unwrapped.type === "ArrowFunctionExpression" || unwrapped.type === "FunctionExpression";
  return isFunction ? unwrapped : null;
}

export default {
  meta: {
    type: "problem",
    docs: { description: "names drawn from the checked-in lexicon (R-316, R-317)" },
    schema: [
      {
        type: "object",
        properties: {
          bannedVerbs: { type: "object", additionalProperties: { type: "string" } },
          bareAdjectives: { type: "array", items: { type: "string" } },
          booleanPrefixes: { type: "array", items: { type: "string" } },
          defaultVerbs: { type: "object", additionalProperties: { type: "string" } },
          glossary: { type: "array", items: { type: "string" } },
          irregularPlurals: { type: "array", items: { type: "string" } },
          scopeVerbs: { type: "object", additionalProperties: { type: "object" } },
          verbGroups: { type: "object", additionalProperties: { type: "array" } },
          verbScopes: { type: "object", additionalProperties: { type: "object" } },
          verbs: { type: "array", items: { type: "string" } },
        },
        additionalProperties: false,
      },
    ],
  },
  create(context) {
    const options = context.options[0] ?? {};
    const verbs = new Set(options.verbs ?? []);
    const booleanPrefixes = new Set(options.booleanPrefixes ?? ["can", "has", "is", "should"]);
    const bannedVerbs = options.bannedVerbs ?? {};
    const bareAdjectives = new Set(options.bareAdjectives ?? []);
    const irregularPlurals = new Set(options.irregularPlurals ?? []);
    const glossary = new Set(options.glossary ?? []);
    const verbScopes = options.verbScopes ?? {};
    const verbGroups = options.verbGroups ?? {};
    const defaultVerbs = options.defaultVerbs ?? {};
    const scopeVerbs = options.scopeVerbs ?? {};
    const filename = context.filename ?? context.getFilename();

    /** Applies every R-316 decision to one named function. */
    function checkFunctionName(node, nameNode, functionNode) {
      const name = nameNode.name;
      if (PASCAL_CASE_PATTERN.test(name)) return;
      const words = splitIdentifier(name);
      if (words.length === 0) return;
      const [leadingWord] = words;

      if (Object.hasOwn(bannedVerbs, leadingWord)) {
        context.report({
          node: nameNode,
          message: `Verb "${leadingWord}" is not in the lexicon (R-316): use "${bannedVerbs[leadingWord]}".`,
        });
        return;
      }

      const isBooleanName = booleanPrefixes.has(leadingWord);
      if (!isBooleanName && !verbs.has(leadingWord)) {
        context.report({
          node: nameNode,
          message: `Verb "${leadingWord}" is not in the lexicon (R-316): add it to lexicon.json or rename to an approved verb.`,
        });
        return;
      }

      if (words.length < 2) {
        context.report({
          node: nameNode,
          message: `"${name}" is a bare verb (R-316): the noun is mandatory.`,
        });
        return;
      }

      if (hasBooleanReturnAnnotation(functionNode) && !isBooleanName) {
        context.report({
          node: nameNode,
          message: `"${name}" returns boolean (R-316): lead with ${[...booleanPrefixes].sort().join("/")}.`,
        });
        return;
      }

      const scope = verbScopes[leadingWord];
      if (scope && !pathSegments(filename).some((segment) => scope.directories.includes(segment))) {
        context.report({
          node: nameNode,
          message: `Verb "${leadingWord}" belongs to ${scope.directories.join("/")} (R-316): use "${scope.fallback}" here.`,
        });
        return;
      }

      const declaredScope = innermostScope(filename, scopeVerbs);
      for (const [groupName, groupVerbs] of Object.entries(verbGroups)) {
        if (!groupVerbs.includes(leadingWord)) continue;
        const requiredVerb = declaredScope?.[groupName] ?? defaultVerbs[groupName];
        if (requiredVerb && leadingWord !== requiredVerb) {
          context.report({
            node: nameNode,
            message: `The ${groupName} verb here is "${requiredVerb}", not "${leadingWord}" (R-316): synonyms are bound to the layer that gives them meaning.`,
          });
          return;
        }
      }

      const headNoun = words.at(-1);
      if (glossary.size > 0 && !glossary.has(headNoun)) {
        context.report({
          node: nameNode,
          message: `Noun "${headNoun}" is not in the domain glossary (R-316, R-330): use a declared term or add it to the glossary.`,
        });
      }
    }

    /** Applies the two decidable R-317 checks to one variable declarator. */
    function checkVariableName(declarator) {
      if (declarator.id.type !== "Identifier") return;
      const name = declarator.id.name;
      if (SCREAMING_SNAKE_PATTERN.test(name) || PASCAL_CASE_PATTERN.test(name)) return;
      const words = splitIdentifier(name);
      if (words.length === 0) return;

      if (words.length === 1 && bareAdjectives.has(words[0])) {
        context.report({
          node: declarator.id,
          message: `"${name}" is a bare adjective (R-317): name the thing, not the state applied to it.`,
        });
        return;
      }

      const headNoun = words.at(-1);
      const isPlural = headNoun.endsWith("s") || irregularPlurals.has(headNoun);
      if (producesCollection(declarator.init) && !isPlural) {
        context.report({
          node: declarator.id,
          message: `"${name}" holds a collection (R-317): use a plural noun.`,
        });
      }
    }

    return {
      FunctionDeclaration(node) {
        if (node.id) checkFunctionName(node, node.id, node);
      },
      TSDeclareFunction(node) {
        if (node.id) checkFunctionName(node, node.id, node);
      },
      VariableDeclarator(node) {
        const functionNode = functionBehindDeclarator(node);
        if (functionNode) {
          if (node.id.type === "Identifier") checkFunctionName(node, node.id, functionNode);
          return;
        }
        checkVariableName(node);
      },
    };
  },
};
