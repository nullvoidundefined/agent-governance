#!/usr/bin/env node
/**
 * clean-code-scan.mjs -- best-effort detector for over-long function bodies.
 *
 * Backs R-227 (functions read as composition, not procedure). Given a source
 * file path, prints a one-line summary of functions whose body exceeds the
 * line ceiling so the PostToolUse hook can surface a non-blocking reminder.
 * The analysis is heuristic by design: brace-depth for the C family,
 * indentation for Python, with strings and comments blanked first so their
 * contents never skew brace counting. It deliberately errs toward silence
 * (prints nothing on any parse trouble) because R-227 is a smell, not a hard
 * fail -- a false positive that blocked work would contradict the rule.
 */
import { readFileSync } from 'node:fs';

const BODY_LINE_CEILING = 25;
const C_FAMILY = new Set(['cjs', 'js', 'jsx', 'mjs', 'ts', 'tsx']);
const CONTROL_KEYWORDS = new Set([
    'await',
    'catch',
    'do',
    'else',
    'for',
    'function',
    'if',
    'return',
    'switch',
    'typeof',
    'while',
    'with',
    'yield',
]);
const MAX_REPORTED = 8;
const REGEX_PRECEDERS = new Set([
    '!',
    '%',
    '&',
    '(',
    '*',
    '+',
    ',',
    '-',
    ':',
    ';',
    '<',
    '=',
    '>',
    '?',
    '[',
    '^',
    '{',
    '|',
    '}',
    '~',
]);

const [, , filePath] = process.argv;
if (filePath) main(filePath);

function main(path) {
    const source = readSource(path);
    if (source === null) return;

    const offenders = scanOffenders(source, extensionOf(path));
    if (offenders.length === 0) return;

    process.stdout.write(formatSummary(path, offenders));
}

function scanOffenders(source, ext) {
    if (C_FAMILY.has(ext)) return scanBraceLanguage(source);
    if (ext === 'py') return scanPython(source);
    return [];
}

function formatSummary(path, offenders) {
    const shown = offenders.slice(0, MAX_REPORTED);
    const parts = shown.map((offender) => `${offender.name} (~${offender.lines} lines)`);
    return `${basenameOf(path)}: ${parts.join(', ')}`;
}

function scanBraceLanguage(source) {
    const lines = stripNonCode(source).split('\n');
    const offenders = [];
    for (let index = 0; index < lines.length; index++) {
        const name = functionNameAt(lines, index);
        if (name === null) continue;
        const bodyLines = measureBraceBody(lines, index);
        if (bodyLines > BODY_LINE_CEILING) offenders.push({ lines: bodyLines, name });
    }
    return offenders;
}

function functionNameAt(lines, index) {
    const line = lines[index];
    const declaration = line.match(/\bfunction\b\s*\*?\s*([\w$]+)?\s*\(/);
    if (declaration) return declaration[1] ?? 'anonymous';

    const arrow = line.match(/(?:\bconst\b|\blet\b|\bvar\b)?\s*([\w$]+)\s*[:=]\s*(?:async\s*)?\([^()]*\)\s*(?::[^=]*?)?=>\s*\{/);
    if (arrow) return arrow[1];

    const method = line.match(/^\s*(?:export\s+)?(?:public\s+|private\s+|protected\s+|static\s+|async\s+|readonly\s+|get\s+|set\s+|override\s+)*([\w$]+)\s*\([^()]*\)\s*(?::\s*[^{}=;]+?)?\{\s*$/);
    if (method && !CONTROL_KEYWORDS.has(method[1])) return method[1];

    return null;
}

function measureBraceBody(lines, startIndex) {
    const open = findOpenBrace(lines, startIndex);
    if (!open) return 0;

    let depth = 0;
    let bodyLines = 0;
    for (let index = open.line; index < lines.length; index++) {
        const from = index === open.line ? open.col : 0;
        const text = lines[index];
        for (let cursor = from; cursor < text.length; cursor++) {
            if (text[cursor] === '{') depth++;
            else if (text[cursor] === '}' && --depth === 0) return bodyLines;
        }
        if (index > open.line && text.trim() !== '') bodyLines++;
    }
    return bodyLines;
}

function findOpenBrace(lines, startIndex) {
    const lookahead = Math.min(lines.length, startIndex + 10);
    for (let index = startIndex; index < lookahead; index++) {
        const col = lines[index].indexOf('{');
        if (col !== -1) return { col, line: index };
    }
    return null;
}

function scanPython(source) {
    const lines = source.split('\n');
    const offenders = [];
    for (let index = 0; index < lines.length; index++) {
        const match = lines[index].match(/^(\s*)(?:async\s+)?def\s+(\w+)\s*\(/);
        if (!match) continue;
        const bodyLines = measurePythonBody(lines, index, match[1].length);
        if (bodyLines > BODY_LINE_CEILING) offenders.push({ lines: bodyLines, name: match[2] });
    }
    return offenders;
}

function measurePythonBody(lines, startIndex, defIndent) {
    let bodyLines = 0;
    for (let index = startIndex + 1; index < lines.length; index++) {
        const trimmed = lines[index].trim();
        if (trimmed === '' || trimmed.startsWith('#')) continue;
        if (indentWidth(lines[index]) <= defIndent) break;
        bodyLines++;
    }
    return bodyLines;
}

/**
 * Return source with string literals, comments, and regex literals replaced by
 * spaces, newlines preserved so line numbers stay aligned. Brace counting then
 * operates only on real code, so a `{` inside a string, a comment, or a regex
 * quantifier (e.g. /\d{2}/) can never open a phantom function body. Regex vs
 * division is disambiguated by the last significant code character -- the
 * standard lexer heuristic, accurate enough for a smell detector.
 */
function stripNonCode(source) {
    const scan = { classDepth: 0, last: '', out: '', state: 'code' };
    for (let index = 0; index < source.length; index++) {
        index = stepChar(scan, source, index);
    }
    return scan.out;
}

function stepChar(scan, source, index) {
    const char = source[index];
    const pair = char + (source[index + 1] ?? '');
    if (scan.state === 'code') return stepCode(scan, char, pair, index);
    if (scan.state === 'line') return stepLineComment(scan, char, index);
    if (scan.state === 'block') return stepBlockComment(scan, char, pair, index);
    if (scan.state === 'regex') return stepRegex(scan, char, index);
    return stepString(scan, char, index);
}

function stepCode(scan, char, pair, index) {
    const opened = openNonCode(pair, char, scan.last);
    if (opened) {
        scan.state = opened.state;
        scan.classDepth = 0;
        scan.out += opened.fill;
        return index + opened.skip;
    }
    scan.out += char;
    if (!isSpace(char)) scan.last = char;
    return index;
}

function openNonCode(pair, char, last) {
    if (pair === '//') return { fill: '  ', skip: 1, state: 'line' };
    if (pair === '/*') return { fill: '  ', skip: 1, state: 'block' };
    if (char === "'") return { fill: ' ', skip: 0, state: 'single' };
    if (char === '"') return { fill: ' ', skip: 0, state: 'double' };
    if (char === '`') return { fill: ' ', skip: 0, state: 'template' };
    if (char === '/' && startsRegex(last)) return { fill: ' ', skip: 0, state: 'regex' };
    return null;
}

function stepLineComment(scan, char, index) {
    if (char === '\n') {
        scan.state = 'code';
        scan.out += '\n';
    } else {
        scan.out += ' ';
    }
    return index;
}

function stepBlockComment(scan, char, pair, index) {
    if (pair === '*/') {
        scan.state = 'code';
        scan.out += '  ';
        return index + 1;
    }
    scan.out += blankFor(char);
    return index;
}

function stepRegex(scan, char, index) {
    if (char === '\\') {
        scan.out += '  ';
        return index + 1;
    }
    if (char === '[') scan.classDepth++;
    else if (char === ']' && scan.classDepth > 0) scan.classDepth--;
    else if (char === '/' && scan.classDepth === 0) return closeNonCode(scan, index);
    scan.out += blankFor(char);
    return index;
}

function stepString(scan, char, index) {
    if (char === '\\') {
        scan.out += '  ';
        return index + 1;
    }
    if (char === quoteFor(scan.state)) return closeNonCode(scan, index);
    scan.out += blankFor(char);
    return index;
}

function closeNonCode(scan, index) {
    scan.state = 'code';
    scan.last = 'x';
    scan.out += ' ';
    return index;
}

function startsRegex(last) {
    return last === '' || REGEX_PRECEDERS.has(last);
}

function quoteFor(state) {
    if (state === 'single') return "'";
    if (state === 'double') return '"';
    return '`';
}

function blankFor(char) {
    return char === '\n' ? '\n' : ' ';
}

function isSpace(char) {
    return char === ' ' || char === '\t' || char === '\n' || char === '\r';
}

function readSource(path) {
    try {
        return readFileSync(path, 'utf8');
    } catch {
        return null;
    }
}

function extensionOf(path) {
    return path.split('.').pop()?.toLowerCase() ?? '';
}

function basenameOf(path) {
    return path.split('/').pop() ?? path;
}

function indentWidth(line) {
    return line.length - line.trimStart().length;
}
