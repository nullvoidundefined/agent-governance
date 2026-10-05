#!/usr/bin/env python3
"""Judge for credential-read-guard.sh. Reads one PreToolUse hook event on stdin
and prints a deny decision as JSON, or nothing for allow. Rules
(docs/specs/2026-10-05-credential-reads.md):

  C-1  a Bash command that names a credential path as an operand or input
       redirect is denied, whatever the program, and so is a redirect with
       no program ($(< .env), C-11)
  C-2  metadata-only programs (ls, stat, test, [, [[, file, du, git
       check-ignore/ls-files/status, find without an action) pass
  C-3  look-alikes (.env.example, *.pub, known_hosts, my.env.ts) pass
  C-4  dumping the environment (env or printenv alone, export -p, declare -p,
       declare -x, typeset -p, set alone, /proc/<pid>/environ) is denied
  C-5  printenv NAME, and echo, printf or a here-string expanding a
       credential variable, are denied, unless the output goes to a file or
       into a pipe to a program that does not print its input (C-13)
  C-6  passing a credential variable to any other program passes
  C-7  a Read of a credential path, or a Grep whose path is one, is denied
  C-12 use-only operands pass: ssh/scp/sftp -i KEY, chmod, chown, touch,
       rm, mv, cp's destination, docker/podman --env-file FILE

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

CREDENTIAL_VARIABLE_PATTERNS = ("TOKEN", "*_TOKEN", "*TOKEN_*", "*SECRET", "*_SECRET*", "*_KEY", "*_KEY_ID",
                                "*PASSWORD*",
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
FILE_OUTPUT_REDIRECTS = OUTPUT_REDIRECTS - {OPERATOR_MARK + ">&"}
# An fd other than 1 glued to an output redirect (2> f), which the parser drops.
OTHER_FD_REDIRECT = re.compile(r"(?<![\w$])(?:[02-9]|[0-9]{2,})>")
HERESTRING = OPERATOR_MARK + "<<<"
# Programs that print what they read on stdin (C-13): a credential piped or
# fed into one reaches the transcript.
ECHOING_CONSUMERS = PRINTERS | {"cat", "tee", "less", "more", "head", "tail", "xxd", "base64", "od", "hexdump",
                                "sed", "awk", "tr", "cut", "grep", "rev", "strings", "sort", "uniq"}
USE_ONLY_PROGRAMS = {"chmod", "chown", "touch", "rm", "mv"}
IDENTITY_FILE_PROGRAMS = {"ssh", "scp", "sftp"}
ENV_FILE_PROGRAMS = {"docker", "podman"}
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


def used_positions(program, rest):
    """Returns the positions in rest of operands a use-only form hands to its
    program without printing the file (C-12): the key of ssh, scp or sftp -i,
    every operand of chmod, chown, touch, rm and mv, cp's destination (when
    it has no -t), and the file of docker or podman --env-file."""
    positions = [index for index in range(1, len(rest)) if not rest[index].startswith(OPERATOR_MARK)
                 and not rest[index - 1].startswith(OPERATOR_MARK)]
    if program in USE_ONLY_PROGRAMS:
        return set(positions)
    used = set()
    for number, position in enumerate(positions):
        word, before = rest[position], rest[positions[number - 1]] if number else ""
        if program in IDENTITY_FILE_PROGRAMS and before == "-i":
            used.add(position)
        if program in ENV_FILE_PROGRAMS and (before == "--env-file" or word.startswith("--env-file=")):
            used.add(position)
    if program == "cp":
        operands = [p for p in positions if not rest[p].startswith("-")]
        targets_directory = any(rest[p] == "-t" or rest[p].startswith("--target-directory") for p in positions)
        if operands and not targets_directory:
            used.add(operands[-1])
    return used


def operand_words(program, rest, start=1):
    """Returns (word, is_code) for each word from rest[start] on that can name
    a file the command reads: arguments and input redirect targets.
    Output redirect targets are writes (secret-scan R-103 owns them); echo and
    printf arguments are text, not files; use-only operands are not reads."""
    words, index = [], start
    is_code = bool(INTERPRETERS.match(program))
    used = used_positions(program, rest)
    while index < len(rest):
        word = rest[index]
        if word.startswith(OPERATOR_MARK):
            if word not in OUTPUT_REDIRECTS and index + 1 < len(rest) and word != HERESTRING:
                words.append((rest[index + 1], False))
            index += 2
            continue
        if program not in PRINTERS and index not in used:
            words.append((word, is_code or "$(" in word or "`" in word))
        index += 1
    return words


def output_leaves_terminal(segment, redirects_other_fd):
    """True when the segment's standard output goes to a file (> f, >> f,
    &> f) or into a pipe to a program that does not print its input (C-13).
    The parser drops an fd number (2> f reads as > f), so while the command
    holds one, an output redirect does not count."""
    target = None
    for index, word in enumerate(segment[:-1]):
        if word in OUTPUT_REDIRECTS:
            target = (word, segment[index + 1])
    if target:
        operator, path = target
        return (operator in FILE_OUTPUT_REDIRECTS and not redirects_other_fd
                and (path == "/dev/null" or not path.startswith(("/dev/", "/proc/"))))
    consumer = PARSER.plain_words(getattr(segment, "piped_to", None) or [])
    program_index = PARSER.find_program_index(consumer)
    if program_index >= len(consumer):
        return False
    program = consumer[program_index]
    return not (program in ECHOING_CONSUMERS or program in PARSER.SHELLS or INTERPRETERS.match(program))


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


def is_environment_dump_launcher(segment):
    """True when env ran with no command (env, env -u X, env FOO=1), which
    prints the environment; the parser drops env as a wrapper, so this reads
    the raw words."""
    plain = PARSER.plain_words(segment)
    if PARSER.find_program_index(plain) < len(plain):
        return False
    raw = getattr(segment, "raw", None) or []
    return any(PARSER.program_name(word) == "env" for word in PARSER.plain_words(raw)
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


def judge_segment(segment, context, derived, redirects_other_fd):
    """Returns (rule, what) for the first finding in one simple command, or None."""
    if is_environment_dump_launcher(segment):
        return "C-4", "`env` with no command prints every environment variable and its value"
    program_index = PARSER.find_program_index(segment)
    rest = segment[program_index:]
    if not rest:
        return None
    if rest[0].startswith(OPERATOR_MARK):
        # A redirect with no program ($(< .env), < .env) still reads (C-11).
        for word, is_code in operand_words("", rest, start=0):
            for part in candidate_paths(word, is_code):
                label = context.credential_label(part)
                if label:
                    return "C-1", "an input redirect reads the credential path %s" % label
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
    output_hidden = output_leaves_terminal(segment, redirects_other_fd)
    if program in PRINTERS and not output_hidden:
        for word in args:
            names = referenced_credentials(word, derived)
            if names:
                return "C-5", "`%s` prints the value of the credential variable %s" % (program, names[0])
    herestring_shown = not output_hidden and (program in ECHOING_CONSUMERS or program in PARSER.SHELLS
                                              or INTERPRETERS.match(program))
    for index, word in enumerate(rest[:-1]):
        if word == HERESTRING and herestring_shown:
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


def judge_bash(text, context):
    derived = set()
    redirects_other_fd = bool(OTHER_FD_REDIRECT.search(text))
    for segment in PARSER.split_segments(text):
        finding = judge_segment(segment, context, derived, redirects_other_fd)
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
