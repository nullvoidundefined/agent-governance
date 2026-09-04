/**
 * Custom ESLint rule enforcing R-320: every source file opens with a
 * file-level header comment saying what it does and why.
 *
 * R-320 sat on the llm-judge tier, which is non-deterministic by construction,
 * with `hooks/new-file-header-reminder.sh` as a non-blocking PostToolUse nudge
 * beside it. Nothing decided it. "Does this file open with a comment" is a pure
 * AST question, so it belongs here (2026-09-04 audit follow-up).
 *
 * Deliberately agrees with that hook rather than being stricter: the hook
 * accepts a leading `//` or a leading block, so this does too. Two enforcers of
 * one rule that disagree are worse than one enforcer, because the author cannot
 * satisfy both and stops believing either.
 *
 * What it does NOT decide: whether the header says anything useful. A header
 * reading "this file" passes here and is exactly what the judge tier is for.
 *
 * Exemptions match the norm line: `.d.ts`, pure re-export barrels, and
 * single-constant modules. Tests, fixtures, stories, configs, and migrations
 * are excluded by path in eslint.config.mjs, mirroring the hook's own skip list.
 */

const TYPE_DECLARATION_PATTERN = /\.d\.tsx?$/;

/** True when every statement is a re-export or an import (a barrel). */
function isPureReExportBarrel(body) {
  return body.every(
    (statement) =>
      statement.type === "ExportAllDeclaration" ||
      statement.type === "ImportDeclaration" ||
      (statement.type === "ExportNamedDeclaration" && statement.source != null),
  );
}

/** True when the file declares exactly one constant and nothing else. */
function isSingleConstantModule(body) {
  if (body.length !== 1) return false;
  const [only] = body;
  const declaration = only.type === "ExportNamedDeclaration" ? only.declaration : only;
  return declaration?.type === "VariableDeclaration" && declaration.declarations.length === 1;
}

export default {
  meta: {
    type: "suggestion",
    docs: { description: "file-level header comment on every source file (R-320)" },
    schema: [],
  },
  create(context) {
    const filename = context.filename ?? context.getFilename();
    if (TYPE_DECLARATION_PATTERN.test(filename)) return {};

    return {
      "Program:exit"(node) {
        const body = node.body;
        if (body.length === 0) return;
        if (isPureReExportBarrel(body)) return;
        if (isSingleConstantModule(body)) return;

        const firstStatementStart = body[0].range[0];
        const comments = context.sourceCode.getAllComments();
        const hasHeader = comments.some((comment) => comment.range[1] <= firstStatementStart);
        if (hasHeader) return;

        context.report({
          node: body[0],
          message:
            "No file-level header (R-320): open the file with a comment saying what it does and why.",
        });
      },
    };
  },
};
