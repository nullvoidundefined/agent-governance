#!/usr/bin/env python3
"""Companion to destructive-command-guard.sh: reads one Bash command on stdin
and prints its simple commands the way bash splits and unquotes them, one per
line, with words separated by \\x1f and redirect operators prefixed with \\x1e
so a quoted ">" never reads as a redirect.

Quotes, backslash escapes, $'...' strings, backslash-newline continuations, and
unquoted comments are resolved as bash resolves them. An fd number glued to a
redirect (2>) is folded into the operator. A heredoc body is skipped, except
when the line that opens it names a shell (bash <<EOF), in which case the body
is parsed as more commands. A command substitution's inner text becomes its own
segment. A command bash itself would reject (an unclosed quote) prints nothing,
because it never runs."""
import os
import sys

WORD_SEPARATOR = "\x1f"
OPERATOR_MARK = "\x1e"
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
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
        while self.position < len(self.text):
            self.step(self.text[self.position])
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
    return body.encode("latin-1", "backslashreplace").decode("unicode_escape")


def split_segments(text):
    """Returns the command's segments as lists of printable words."""
    segments, current = [], []
    for kind, value in Tokenizer(text).run():
        if kind == "separator":
            segments.append(current)
            current = []
        elif kind == "substitution":
            segments.extend(split_segments(value))
        elif kind == "redirect":
            current.append(OPERATOR_MARK + value)
        else:
            current.append(value.replace("\n", " "))
    segments.append(current)
    return [segment for segment in segments if segment]


def main():
    try:
        segments = split_segments(sys.stdin.read())
    except (ValueError, StopIteration):
        return
    for segment in segments:
        print(WORD_SEPARATOR.join(segment))


if __name__ == "__main__":
    main()
