// only-blocks.mjs: keeps the parts of a rules/ document meant for one target.
// A block opens with `<!-- only: a,b -->` on its own line and closes with
// `<!-- /only -->`; both tag lines are dropped. Untagged text is kept for
// every target. Tags are matched on whole lines only, with no code-fence
// awareness: a tag inside a fence is still a tag.
import { SourceError } from "./exporter-core.mjs";

const TARGETS = new Set(["claude", "codex", "cursor"]);
const OPEN = /^<!-- only: ([a-z, ]+) -->\r?$/;
const CLOSE = /^<!-- \/only -->\r?$/;

// selectForTarget(text, target, file) -> text with every block not naming
// target removed and every tag line dropped. Text without tags is returned
// unchanged. Throws a SourceError naming file and line for an unclosed,
// nested, or stray block and for an unknown target name.
export function selectForTarget(text, target, file) {
  if (!text.includes("<!-- only:") && !text.includes("<!-- /only")) return text;
  const lines = text.split(/(?<=\n)/);
  let out = "";
  let open = null;
  lines.forEach((line, index) => {
    const lineNumber = index + 1;
    const bare = line.replace(/\n$/, "");
    const opened = OPEN.exec(bare);
    if (opened) {
      if (open) throw new SourceError(file, `line ${lineNumber}: nested only: block (outer block opened on line ${open.line})`);
      const names = opened[1].split(",").map((name) => name.trim()).filter(Boolean);
      for (const name of names) {
        if (!TARGETS.has(name)) throw new SourceError(file, `line ${lineNumber}: unknown target ${name}`);
      }
      open = { line: lineNumber, keep: names.includes(target) };
      return;
    }
    if (CLOSE.test(bare)) {
      if (!open) throw new SourceError(file, `line ${lineNumber}: /only with no open block`);
      open = null;
      return;
    }
    if (!open || open.keep) out += line;
  });
  if (open) throw new SourceError(file, `line ${open.line}: only: block is never closed`);
  return out;
}
