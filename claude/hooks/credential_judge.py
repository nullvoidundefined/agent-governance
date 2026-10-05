#!/usr/bin/env python3
"""Judge for credential-read-guard.sh. Reads one PreToolUse hook event on stdin
and prints a deny decision as JSON, or nothing for allow. Rules
(docs/specs/2026-10-05-credential-reads.md):

  C-1  a Bash command that names a credential path as an operand or input
       redirect is denied, whatever the program
  C-2  metadata-only programs (ls, stat, test, [, [[, file, du, git
       check-ignore/ls-files/status, find without an action) pass
  C-3  look-alikes (.env.example, *.pub, known_hosts, my.env.ts) pass
  C-4  dumping the environment (env or printenv alone, export -p, declare -p,
       declare -x, typeset -p, set alone, /proc/<pid>/environ) is denied
  C-5  printenv NAME, and echo, printf or a here-string expanding a
       credential variable, are denied
  C-6  passing a credential variable to any other program passes
  C-7  a Read of a credential path, or a Grep whose path is one, is denied

With --list-env-names it prints instead the credential variable names present
in its own environment, one per line (credential-env-warning.sh, C-8).

Stateless: reads the event, writes nothing, and never prints a value; a reason
names a path's credential entry or a variable's name only. Any exception exits
non-zero, which the wrapper turns into a deny."""
import fnmatch
import importlib.util
import json
import os
import re
import sys

HOOK_NAME = "credential-read-guard"
PARSER_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shell-command-segments.py")


def load_parser():
    """Imports shell-command-segments.py, whose file name is not a module name."""
    spec = importlib.util.spec_from_file_location("shell_command_segments", PARSER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PARSER = load_parser()
OPERATOR_MARK = PARSER.OPERATOR_MARK

# --- Credential paths -------------------------------------------------------

HOME_DIRECTORIES = (".aws", ".ssh", ".gnupg", ".kube", ".azure", ".config/gcloud", ".config/doctl",
                    ".wrangler", ".config/.wrangler", ".cloudflared", ".fly")
HOME_FILES = (".docker/config.json", ".config/gh/hosts.yml", ".netrc", ".pgpass", ".my.cnf", ".npmrc",
              ".pypirc", ".terraform.d/credentials.tfrc.json")
SSH_PUBLIC_NAMES = ("known_hosts",)
ENV_FILE_EXEMPTIONS = (".env.example", ".env.sample", ".env.template", ".env.dist")
ANYWHERE_NAMES = (".envrc", ".npmrc")
CREDENTIAL_SUFFIXES = (".tfvars", ".tfstate", ".tfstate.backup", ".pem", ".key", ".p12", ".pfx")
KEY_FILE_PREFIXES = ("id_rsa", "id_ed25519")
PROC_ENVIRON = re.compile(r"^/proc/[^/]+(?:/task/[^/]+)?/environ$")
# Names a glob word is tried against: a pattern that could expand to one of
# them is treated as naming it.
GLOB_PROBE_NAMES = (".env", ".env.local", ".envrc", ".npmrc", "id_rsa", "id_ed25519")
GLOB_CHARACTERS = re.compile(r"[*?\[]")
MAX_BRACE_EXPANSIONS = 64


def is_credential_name(name):
    """True when a file name alone makes a path a credential path."""
    if name.endswith(".pub"):
        return False
    if name == ".env" or name.startswith(".env."):
        return name not in ENV_FILE_EXEMPTIONS
    if name in ANYWHERE_NAMES:
        return True
    return (any(name.endswith(s) and len(name) > len(s) for s in CREDENTIAL_SUFFIXES)
            or name.startswith(KEY_FILE_PREFIXES))


def home_entry(path, homes):
    """Returns the ~/ entry (directory or file) a path is or lies under, or None."""
    for home in homes:
        if not path.startswith(home + "/"):
            continue
        relative = path[len(home) + 1:]
        for directory in HOME_DIRECTORIES:
            if relative == directory or relative.startswith(directory + "/"):
                if directory == ".ssh" and relative != ".ssh":
                    name = os.path.basename(relative)
                    if name.endswith(".pub") or name in SSH_PUBLIC_NAMES:
                        return None
                return "~/" + directory + "/"
        if relative in HOME_FILES:
            return "~/" + relative
    return None


class PathContext:
    """What a path word is resolved against: the home directories (as written
    and physical), the working directory, and the session's known variables."""

    def __init__(self, cwd, home):
        self.cwd = os.path.abspath(cwd or os.getcwd())
        self.home = home
        self.homes = sorted({os.path.normpath(h) for h in (home, os.path.realpath(home)) if h}
                            - {"/", "."})
        self.variables = {}

    def expand(self, word):
        """Returns the word with ~, $HOME, $PWD and known session variables expanded."""
        if self.home and (word == "~" or word.startswith("~/")):
            word = self.home + word[1:]
        known = dict(self.variables, HOME=self.home, PWD=self.cwd)

        def substitute(match):
            name = match.group(1) or match.group(2)
            return known.get(name, match.group(0))
        return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", substitute, word)

    def absolute(self, path):
        return os.path.normpath(os.path.join(self.cwd, path))

    def credential_label(self, word):
        """Returns how a reason names the credential path a word is, or None.
        The label is an entry name, never the word, so it cannot carry a value."""
        for expanded in expand_braces(self.expand(word)):
            if not expanded:
                continue
            label = (self.glob_label(expanded) if GLOB_CHARACTERS.search(expanded)
                     else self.path_label(expanded))
            if label:
                return label
        return None

    def path_label(self, path):
        absolute = self.absolute(path)
        for candidate in dict.fromkeys((absolute, os.path.realpath(absolute))):
            if PROC_ENVIRON.match(candidate):
                return "/proc/<pid>/environ"
            entry = home_entry(candidate, self.homes)
            if entry:
                return entry
            name = os.path.basename(candidate)
            if is_credential_name(name):
                return name
        return None

    def glob_label(self, pattern):
        """Returns a label when the glob pattern could expand to a credential
        path: it ends in a credential suffix (*.pem), or it matches a ~/ entry,
        /proc/self/environ, or, when its name has a literal prefix (.env*,
        id_*), a credential file name in its directory."""
        absolute = self.absolute(pattern)
        pattern_name = os.path.basename(absolute)
        suffix = next((s for s in CREDENTIAL_SUFFIXES if pattern_name.endswith(s)), None)
        if suffix:
            return "*" + suffix
        probes = ["/proc/self/environ"]
        for home in self.homes:
            probes += [home + "/" + d for d in HOME_DIRECTORIES] + [home + "/" + d + "/credentials"
                                                                   for d in HOME_DIRECTORIES]
            probes += [home + "/" + f for f in HOME_FILES]
        if not GLOB_CHARACTERS.match(pattern_name):
            probes += [os.path.join(os.path.dirname(absolute), name) for name in GLOB_PROBE_NAMES]
        for probe in probes:
            if glob_matches(probe, absolute):
                return self.path_label(probe)
        return None


def glob_matches(path, pattern):
    """True when bash would expand pattern to path: component by component,
    with a leading dot matched only by a pattern component that starts with one."""
    path_parts, pattern_parts = path.split("/"), pattern.split("/")
    if len(path_parts) != len(pattern_parts):
        return False
    for part, glob in zip(path_parts, pattern_parts):
        if part.startswith(".") and not glob.startswith("."):
            return False
        if not fnmatch.fnmatchcase(part, glob):
            return False
    return True


def expand_braces(word):
    """Returns the words bash brace expansion makes of word ({a,b} groups,
    nested ones included), capped at MAX_BRACE_EXPANSIONS; a word with no
    comma group is returned alone."""
    results, pending = [], [word]
    while pending and len(results) < MAX_BRACE_EXPANSIONS:
        current = pending.pop(0)
        group = find_brace_group(current)
        if group is None:
            results.append(current)
            continue
        start, end, options = group
        pending.extend(current[:start] + option + current[end + 1:] for option in options)
    return results + pending[:max(0, MAX_BRACE_EXPANSIONS - len(results))]


def find_brace_group(word):
    """Returns (start, end, options) of the first {a,b} group in word that is
    not a ${...} expansion, or None."""
    for start, char in enumerate(word):
        if char != "{" or (start and word[start - 1] == "$"):
            continue
        depth, options, piece_start = 0, [], start + 1
        for index in range(start, len(word)):
            if word[index] == "{":
                depth += 1
            elif word[index] == "}":
                depth -= 1
                if depth == 0:
                    options.append(word[piece_start:index])
                    if len(options) > 1:
                        return start, index, options
                    break
            elif word[index] == "," and depth == 1:
                options.append(word[piece_start:index])
                piece_start = index + 1
    return None


# --- Credential variable names ------------------------------------------------

CREDENTIAL_VARIABLE_PATTERNS = ("*_TOKEN", "*TOKEN_*", "*_SECRET*", "*_KEY", "*_KEY_ID", "*PASSWORD*",
                                "*PASSWD*", "*_DSN", "DATABASE_URL", "*_DATABASE_URL", "*_DB_URL",
                                "CLOUDFLARE_*", "AWS_*", "GH_TOKEN", "GITHUB_TOKEN")
AWS_NON_CREDENTIALS = {"AWS_REGION", "AWS_DEFAULT_REGION", "AWS_PROFILE"}
VARIABLE_REFERENCE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")


def is_credential_variable(name):
    upper = name.upper()
    if upper in AWS_NON_CREDENTIALS:
        return False
    return any(fnmatch.fnmatchcase(upper, pattern) for pattern in CREDENTIAL_VARIABLE_PATTERNS)


def referenced_credentials(word, derived):
    """Returns the credential variable names a word expands, including names
    the session assigned from a credential (t=$GH_TOKEN)."""
    return [name for name in VARIABLE_REFERENCE.findall(word)
            if is_credential_variable(name) or name in derived]


# --- Bash rules ---------------------------------------------------------------

METADATA_PROGRAMS = {"ls", "stat", "test", "[", "[[", "file", "du"}
GIT_METADATA_COMMANDS = {"check-ignore", "ls-files", "status"}
GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
FIND_ACTIONS = {"-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"}
PRINTERS = {"echo", "printf"}
DECLARATION_DUMPERS = {"export", "declare", "typeset", "readonly"}
INTERPRETERS = re.compile(r"^(python[0-9.]*|node|nodejs|deno|bun|ruby|perl|php|[gmn]?awk|lua|Rscript)$")
OUTPUT_REDIRECTS = {OPERATOR_MARK + op for op in (">", ">>", ">|", "&>", "&>>", ">&")}
HERESTRING = OPERATOR_MARK + "<<<"
CODE_STRING_LITERAL = re.compile(r"'([^']*)'|\"([^\"]*)\"")
CODE_TOKEN_SPLIT = re.compile(r"[\s'\"()\[\],;:=<>|&`+]+")
OPERAND_SPLIT = re.compile(r"[=:,]")
DIRECTORY_CHANGERS = {"cd", "pushd"}


def git_subcommand(args):
    index = 0
    while index < len(args) and args[index].startswith("-"):
        index += 2 if args[index] in GIT_VALUE_OPTIONS else 1
    return args[index] if index < len(args) else ""


def is_metadata_only(program, args):
    if program in METADATA_PROGRAMS:
        return True
    if program == "git":
        return git_subcommand(args) in GIT_METADATA_COMMANDS
    if program == "find":
        return not any(arg in FIND_ACTIONS for arg in args)
    return False


def operand_words(program, rest):
    """Returns (word, is_code) for each word that can name a file the command
    reads: arguments and input redirect targets.
    Output redirect targets are writes (secret-scan R-103 owns them); echo and
    printf arguments are text, not files."""
    words, index = [], 1
    is_code = bool(INTERPRETERS.match(program))
    while index < len(rest):
        word = rest[index]
        if word.startswith(OPERATOR_MARK):
            if word not in OUTPUT_REDIRECTS and index + 1 < len(rest) and word != HERESTRING:
                words.append((rest[index + 1], False))
            index += 2
            continue
        if program not in PRINTERS:
            words.append((word, is_code or "$(" in word or "`" in word))
        index += 1
    return words


def candidate_paths(word, is_code):
    """Returns the strings in a word that may be paths: the word itself, each
    part around = : and , (--file=.env, host:~/.ssh/id_rsa), and for code
    words (python -c, node -e) every string literal and every token holding
    a slash. Bare code tokens are not paths (cfg.key is an attribute)."""
    if word.startswith("-") and "=" not in word:
        return []
    parts = [word] + OPERAND_SPLIT.split(word)
    if is_code:
        parts += [single or double for single, double in CODE_STRING_LITERAL.findall(word)]
        parts += [token for token in CODE_TOKEN_SPLIT.split(word) if "/" in token]
    return [part for part in dict.fromkeys(parts) if part]


def is_environment_dump_launcher(segment, raw):
    """True when env ran with no command (env, env -u X, env FOO=1), which
    prints the environment; the parser drops env as a wrapper, so this reads
    the raw words."""
    plain = PARSER.plain_words(segment)
    if PARSER.find_program_index(plain) < len(plain):
        return False
    return any(PARSER.program_name(word) == "env" for word in PARSER.plain_words(raw or [])
               if not PARSER.is_assignment(word))


def declaration_finding(program, args, derived):
    """Returns (rule, what) when export, declare, typeset or readonly prints
    variables: with no names, or with -p naming a credential."""
    flags = "".join(arg[1:] for arg in args if arg.startswith("-") and len(arg) > 1)
    names = [arg.split("=", 1)[0] for arg in args if not arg.startswith(("-", "+"))]
    if not names:
        if program in ("declare", "typeset") and flags and set(flags) <= set("fF"):
            return None
        return "C-4", "`%s%s` prints every variable and its value" % (program, " -" + flags if flags else "")
    if "p" in flags:
        for name in names:
            if is_credential_variable(name) or name in derived:
                return "C-5", "`%s -p` prints the value of the credential variable %s" % (program, name)
    return None


def judge_segment(segment, raw, context, derived):
    """Returns (rule, what) for the first finding in one simple command, or None."""
    if is_environment_dump_launcher(segment, raw):
        return "C-4", "`env` with no command prints every environment variable and its value"
    program_index = PARSER.find_program_index(segment)
    rest = segment[program_index:]
    if not rest or rest[0].startswith(OPERATOR_MARK):
        return None
    program, args = rest[0], PARSER.plain_words(rest[1:])
    if program == "printenv":
        names = [arg for arg in args if not arg.startswith("-")]
        if not names:
            return "C-4", "`printenv` with no name prints every environment variable and its value"
        for name in names:
            if is_credential_variable(name) or name in derived:
                return "C-5", "`printenv %s` prints the value of a credential variable" % name
    if program == "set" and not args:
        return "C-4", "`set` with no arguments prints every variable and its value"
    if program in DECLARATION_DUMPERS:
        finding = declaration_finding(program, args, derived)
        if finding:
            return finding
    if program in PRINTERS:
        for word in args:
            names = referenced_credentials(word, derived)
            if names:
                return "C-5", "`%s` prints the value of the credential variable %s" % (program, names[0])
    for index, word in enumerate(rest[:-1]):
        if word == HERESTRING:
            names = referenced_credentials(rest[index + 1], derived)
            if names:
                return "C-5", "a here-string feeds the value of the credential variable %s to `%s`" % (
                    names[0], program)
    if is_metadata_only(program, args):
        return None
    for word, is_code in operand_words(program, rest):
        for part in candidate_paths(word, is_code):
            label = context.credential_label(part)
            if label:
                return "C-1", "`%s` names the credential path %s" % (program, label)
    return None


def record_session_state(segment, context, derived):
    """Tracks assignments (FILE=.env; cat $FILE) and directory changes (cd
    ~/.aws && cat credentials) so later segments resolve the way they run."""
    program_index = PARSER.find_program_index(segment)
    rest = PARSER.plain_words(segment[program_index:])
    if not rest:
        assignments = segment[:program_index]
    elif rest[0] in DECLARATION_DUMPERS or rest[0] == "local":
        assignments = [arg for arg in rest[1:] if PARSER.is_assignment(arg)]
    else:
        assignments = []
    for assignment in assignments:
        name, value = assignment.split("=", 1)
        context.variables[name] = context.expand(value)
        if referenced_credentials(value, derived):
            derived.add(name)
    if rest and rest[0] in DIRECTORY_CHANGERS:
        targets = [arg for arg in rest[1:] if not arg.startswith("-")]
        target = context.expand(targets[0]) if targets else context.home
        if target:
            context.cwd = context.absolute(target)


def split_segments_with_raw(text):
    """Returns (segment, raw words) pairs: the parser's normalized segments,
    each with the words it was normalized from, so a dropped wrapper (env)
    is still visible."""
    raw_by_segment = {}
    original = PARSER.normalize_segment

    def recording_normalize(words, piped_words):
        normalized = original(words, piped_words)
        raw_by_segment[id(normalized)] = list(words)
        return normalized

    PARSER.normalize_segment = recording_normalize
    try:
        segments = PARSER.split_segments(text)
    finally:
        PARSER.normalize_segment = original
    return [(segment, raw_by_segment.get(id(segment))) for segment in segments]


def judge_bash(text, context):
    derived = set()
    for segment, raw in split_segments_with_raw(text):
        finding = judge_segment(segment, raw, context, derived)
        if finding:
            return finding
        record_session_state(segment, context, derived)
    return None


# --- Read and Grep (C-7) ------------------------------------------------------

def judge_tool_read(tool_name, tool_input, context):
    key = "file_path" if tool_name == "Read" else "path"
    path = tool_input.get(key) or ""
    if not isinstance(path, str) or not path:
        return None
    label = context.path_label(context.expand(path))
    if label:
        return "C-7", "the %s tool call targets the credential path %s" % (tool_name, label)
    return None


# --- Output -------------------------------------------------------------------

def deny_reason(rule, what):
    return ("%s BLOCKED this call (%s): %s. An agent never brings a credential's value into its context. "
            "Programs may still use a credential (psql \"$DATABASE_URL\"); if a person needs to see the value, "
            "a human runs the command by hand in a terminal." % (HOOK_NAME, rule, what))


def decide(event, home):
    tool_name = event.get("tool_name")
    tool_input = event.get("tool_input") or {}
    context = PathContext(event.get("cwd") or "", home)
    if tool_name in (None, "Bash"):
        text = tool_input.get("command") or ""
        return judge_bash(text, context) if text.strip() else None
    if tool_name in ("Read", "Grep"):
        return judge_tool_read(tool_name, tool_input, context)
    return None


def list_environment_names(environ):
    return sorted(name for name in environ if is_credential_variable(name))


def main():
    if sys.argv[1:] == ["--list-env-names"]:
        for name in list_environment_names(os.environ):
            sys.stdout.write(name + "\n")
        return
    event = json.loads(sys.stdin.read() or "{}")
    finding = decide(event, os.environ.get("HOME", ""))
    if not finding:
        return
    sys.stdout.write(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": deny_reason(*finding),
    }}) + "\n")


if __name__ == "__main__":
    main()
