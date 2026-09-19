#!/usr/bin/env python3
"""Companion to destructive-command-guard.sh: reads one Bash command on stdin
and prints its simple commands the way bash splits and unquotes them, one per
line, with words separated by \\x1f and redirect operators prefixed with \\x1e
so a quoted ">" never reads as a redirect.

Quotes, backslash escapes, $'...' strings, backslash-newline continuations, and
unquoted comments are resolved as bash resolves them. An fd number glued to a
redirect (2>) is dropped, leaving the bare operator. A heredoc body is skipped, except
when the line that opens it names a shell (bash <<EOF), in which case the body
is parsed as more commands. A command substitution's inner text becomes its own
segment.

Each segment is then normalized to what actually runs: leading VAR=value
assignments are kept first, compound-command keywords ({, !, if, then, do) and
wrappers (env, sudo, command, exec, nohup, time, nice, timeout, xargs) are
dropped along with their own options, and the program name is reduced to its
basename, with any capitalization of git printed as `git` (macOS resolves
commands case-insensitively). The words piped into xargs become arguments of
the program it runs. The command string given to `sh -c` (any shell) or to
`eval` is parsed as more segments. A function definition `name() {` is
printed as the segment `function name`, the form `function name {` already
has. Text bash would reject partway (an unclosed quote on a later line) is
parsed up to that point, because bash runs the complete lines before it. Any
other failure exits non-zero, which the guard treats as a deny."""
import os
import sys

WORD_SEPARATOR = "\x1f"
OPERATOR_MARK = "\x1e"
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
KEYWORDS = {"{", "}", "!", "if", "then", "do", "else", "elif", "while", "until"}
WRAPPER_VALUE_OPTIONS = {
    "env": {"-u", "-S", "-C", "-P", "--unset", "--split-string", "--chdir"},
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-T", "-U", "--user", "--group"},
    "command": set(),
    "exec": {"-a"},
    "nohup": set(),
    "time": set(),
    "nice": {"-n", "--adjustment"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-I", "-L", "-n", "-P", "-s", "-E", "-d", "-a", "--max-args", "--max-procs",
              "--delimiter", "--arg-file", "--replace"},
}
WRAPPER_POSITIONALS = {"timeout": 1}
SEPARATOR_OPERATORS = ("&&", "||", "|&", ";;", ";", "&", "|", "(", ")")
REDIRECT_OPERATORS = ("&>>", "&>", "<<<", "<<-", ">>", ">|", ">&", "<<", "<&", "<>", ">", "<")


class Tokenizer:
    """Turns command text into a flat list of (kind, value) tokens, where kind
    is "word", "redirect", or "separator"."""

    def __init__(self, text):
        self.text = text
        self.position = 0
        self.tokens = []
        self.word = []
        self.in_word = False
        self.word_quoted = False
        self.pending_heredocs = []
        self.line_names_shell = False
        self.expect_heredoc_delimiter = None

    def run(self):
        """Returns the tokens. Text bash would reject (an unclosed quote or
        backtick) ends the scan early rather than failing it: bash runs every
        complete line before the one it cannot parse, so those tokens count."""
        try:
            while self.position < len(self.text):
                self.step(self.text[self.position])
        except ValueError:
            self.word, self.in_word = [], False
        self.end_word()
        return self.tokens

    def step(self, char):
        if char == "\\":
            self.read_escape()
        elif char == "'":
            self.append_quoted(self.read_until("'"))
        elif char == "$" and self.peek(1) == "'":
            self.position += 1
            self.append_quoted(decode_ansi_c(self.read_until("'", escapes=True)))
        elif char == "$" and self.peek(1) == "(":
            self.read_command_substitution()
        elif char == "`":
            self.read_backtick_substitution()
        elif char == '"':
            self.append_quoted(self.read_double_quoted())
        elif char in " \t\r":
            self.end_word()
            self.position += 1
        elif char == "#" and not self.in_word:
            self.skip_comment()
        elif char == "\n":
            self.end_line()
        elif char in "<>" or (char == "&" and self.peek(1) == ">"):
            self.read_redirect()
        elif char in ";&|()":
            self.read_separator()
        else:
            self.word.append(char)
            self.in_word = True
            self.position += 1

    def peek(self, offset):
        """Returns the character offset places ahead, or an empty string."""
        index = self.position + offset
        return self.text[index] if index < len(self.text) else ""

    def read_escape(self):
        following = self.peek(1)
        if following != "\n" and following:
            self.word.append(following)
            self.in_word = True
            self.word_quoted = True
        self.position += 2

    def read_until(self, closing, escapes=False):
        start = self.position + 1
        index = start
        while index < len(self.text) and self.text[index] != closing:
            index += 2 if escapes and self.text[index] == "\\" else 1
        if index >= len(self.text):
            raise ValueError("unclosed quote")
        self.position = index + 1
        return self.text[start:index]

    def read_double_quoted(self):
        index = self.position + 1
        content = []
        while index < len(self.text) and self.text[index] != '"':
            char = self.text[index]
            if char == "\\" and index + 1 < len(self.text) and self.text[index + 1] in '$`"\\\n':
                if self.text[index + 1] != "\n":
                    content.append(self.text[index + 1])
                index += 2
            else:
                content.append(char)
                index += 1
        if index >= len(self.text):
            raise ValueError("unclosed quote")
        self.position = index + 1
        return "".join(content)

    def read_command_substitution(self):
        depth = 0
        index = self.position + 1
        while index < len(self.text):
            depth += {"(": 1, ")": -1}.get(self.text[index], 0)
            if depth == 0:
                break
            index += 1
        inner = self.text[self.position + 2:index]
        self.tokens.append(("substitution", inner))
        self.word.append(self.text[self.position:index + 1])
        self.in_word = True
        self.position = index + 1

    def read_backtick_substitution(self):
        closing = self.text.find("`", self.position + 1)
        if closing < 0:
            raise ValueError("unclosed backtick")
        inner = self.text[self.position + 1:closing]
        self.tokens.append(("substitution", inner))
        self.word.append(self.text[self.position:closing + 1])
        self.in_word = True
        self.position = closing + 1

    def append_quoted(self, content):
        self.word.append(content)
        self.in_word = True
        self.word_quoted = True

    def skip_comment(self):
        while self.position < len(self.text) and self.text[self.position] != "\n":
            self.position += 1

    def read_redirect(self):
        if self.in_word and not self.word_quoted and "".join(self.word).isdigit():
            self.word, self.in_word = [], False
        self.end_word()
        operator = next(op for op in REDIRECT_OPERATORS if self.text.startswith(op, self.position))
        self.position += len(operator)
        self.tokens.append(("redirect", operator))
        if operator in ("<<", "<<-"):
            self.expect_heredoc_delimiter = operator

    def read_separator(self):
        self.end_word()
        operator = next(op for op in SEPARATOR_OPERATORS if self.text.startswith(op, self.position))
        self.position += len(operator)
        self.tokens.append(("separator", operator))

    def end_word(self):
        if not self.in_word:
            return
        value = "".join(self.word)
        self.tokens.append(("word", value))
        if self.expect_heredoc_delimiter:
            self.pending_heredocs.append((value, self.expect_heredoc_delimiter == "<<-"))
            self.expect_heredoc_delimiter = None
        elif os.path.basename(value) in SHELLS:
            self.line_names_shell = True
        self.word, self.in_word, self.word_quoted = [], False, False

    def end_line(self):
        self.end_word()
        self.tokens.append(("separator", "\n"))
        self.position += 1
        for delimiter, strips_tabs in self.pending_heredocs:
            body = self.read_heredoc_body(delimiter, strips_tabs)
            if self.line_names_shell:
                self.tokens.append(("substitution", body))
        self.pending_heredocs = []
        self.line_names_shell = False

    def read_heredoc_body(self, delimiter, strips_tabs):
        lines = []
        while self.position < len(self.text):
            end = self.text.find("\n", self.position)
            end = len(self.text) if end < 0 else end
            line = self.text[self.position:end]
            self.position = end + 1
            if (line.lstrip("\t") if strips_tabs else line) == delimiter:
                break
            lines.append(line)
        return "\n".join(lines)


def decode_ansi_c(body):
    """Decodes the escapes of a $'...' string the way bash expands them."""
    return body.encode("latin-1", "backslashreplace").decode("unicode_escape")


def is_assignment(word):
    """True when the word is a NAME=value shell assignment."""
    name, equals, _ = word.partition("=")
    return bool(equals) and name.replace("_", "a").isalnum() and not name[0].isdigit()


def program_name(word):
    """Returns the basename of a program word, with any capitalization of git as git."""
    name = os.path.basename(word)
    return "git" if name.lower() == "git" else name


def skip_wrapper_options(words, index, wrapper):
    """Returns the index of the first word after a wrapper's own options and
    positional arguments (timeout's duration)."""
    while index < len(words) and words[index].startswith("-") and words[index] != "--":
        index += 2 if words[index] in WRAPPER_VALUE_OPTIONS[wrapper] else 1
    if index < len(words) and words[index] == "--":
        index += 1
    return index + WRAPPER_POSITIONALS.get(wrapper, 0)


def normalize_segment(words, piped_words):
    """Returns assignments, then the program and its arguments, with keywords
    and wrappers removed and redirects in front of the program moved behind it."""
    assignments, redirects, index, runs_xargs = [], [], 0, False
    while index < len(words):
        word = words[index]
        if word.startswith(OPERATOR_MARK):
            redirects.extend(words[index:index + 2])
            index += 2
        elif is_assignment(word):
            assignments.append(word)
            index += 1
        elif word in KEYWORDS:
            index += 1
        elif program_name(word) in WRAPPER_VALUE_OPTIONS:
            runs_xargs = runs_xargs or program_name(word) == "xargs"
            index = skip_wrapper_options(words, index + 1, program_name(word))
        else:
            break
    command = words[index:]
    if command:
        command[0] = program_name(command[0])
    if runs_xargs:
        command += piped_words
    return assignments + command + redirects


def find_command_string(words):
    """Returns the text a shell runs with -c, or eval runs, or None."""
    program_index = next((i for i, word in enumerate(words) if not is_assignment(word)), len(words))
    if program_index >= len(words):
        return None
    arguments = words[program_index + 1:]
    if words[program_index] == "eval":
        return " ".join(arguments)
    if words[program_index] not in SHELLS:
        return None
    reads_string = False
    for word in arguments:
        if word.startswith("-") and not word.startswith("--"):
            reads_string = reads_string or "c" in word
        elif reads_string:
            return word
        else:
            return None
    return None


def expand_segment(segment):
    """Returns the segment, followed by the segments of any command string it
    hands to a shell or to eval."""
    command_string = find_command_string(segment)
    return [segment] + (split_segments(command_string) if command_string else [])


def plain_words(words):
    """Returns the words that are neither redirect operators nor their targets."""
    return [word for index, word in enumerate(words)
            if not word.startswith(OPERATOR_MARK)
            and not (index and words[index - 1].startswith(OPERATOR_MARK))]


def is_function_definition(tokens, index, current):
    """True when the token at index opens the `()` of `name()`."""
    return (tokens[index] == ("separator", "(") and len(current) == 1
            and index + 1 < len(tokens) and tokens[index + 1] == ("separator", ")"))


def split_segments(text):
    """Returns the command's segments as normalized lists of printable words."""
    segments, current, previous = [], [], []
    separator_before = None
    tokens = Tokenizer(text).run() + [("separator", None)]
    for index, (kind, value) in enumerate(tokens):
        if is_function_definition(tokens, index, current):
            segments.append(["function", current[0]])
            current = []
        elif kind == "separator":
            if current:
                piped = plain_words(previous[1:]) if separator_before in ("|", "|&") else []
                segments.extend(expand_segment(normalize_segment(current, piped)))
                previous = current
            current, separator_before = [], value
        elif kind == "substitution":
            segments.extend(split_segments(value))
        elif kind == "redirect":
            current.append(OPERATOR_MARK + value)
        else:
            current.append(value.replace("\n", " "))
    return segments


def main():
    """Prints the segments of the command read from stdin."""
    segments = split_segments(sys.stdin.read())
    for segment in segments:
        sys.stdout.write(WORD_SEPARATOR.join(segment) + "\n")


if __name__ == "__main__":
    main()
