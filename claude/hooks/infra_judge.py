#!/usr/bin/env python3
"""Judge for infra-mutation-guard.sh. Reads one PreToolUse hook event on stdin
and prints a PreToolUse decision (deny or ask) as JSON, or nothing for allow.

It decides per simple command, using the segments shell-command-segments.py
produces, so quoting, `bash -c`, eval, env prefixes and wrappers resolve the
way destructive-ops-guard.sh sees them, and a word that is only an argument
(echo aws s3 rm) is never a call. Rules (docs/specs/2026-10-04-harness-hardening.md):

  B-1, B-2  aws, gcloud, az, doctl: read verbs pass, every other verb is denied
  B-3       DNS record and zone changes are denied
  B-4       non-GET curl, wget, httpie, xh calls to provider API hosts are denied
  B-5, B-6  terraform, tofu and pulumi state-changing commands are denied
  B-7, B-8  kubectl and helm mutations: local context passes, production
            context is denied, any other context (or none) asks
  B-9, B-10 PaaS destroy-class commands and production deploys are denied
  B-11, B-12 production classification, shared by every rule (is_production)
  B-13      destructive SQL against a production target is denied
  B-14      ORM data-loss commands ask, deny against production
  B-15      UPDATE ... SET with no WHERE asks, deny against production
  B-16      DELETE FROM with no WHERE asks (destructive-db-guard.sh allows a
            bounded DELETE against a local target)
  B-17      migrations against production are denied
  B-18      a command word that is a command substitution, or a variable whose
            value is unknown or splits into words, asks; so does a program
            this guard does not unwrap whose arguments run an in-scope CLI
  B-21..B-23 cli53, dnscontrol push and nsupdate DNS changes are denied
  B-24..B-27 gsutil, bq (including a writing bq query), s3cmd writes and
            azd up/down/deploy/provision are denied
  B-28      terragrunt is judged like terraform, through run-all and run --all
  B-29, B-30 cdk, sam, serverless deploys and removals, and eksctl
            mutations, are denied
  B-31      oc is judged like kubectl
  B-32      .enforce.json provider_hosts adds hosts to B-4; malformed fails closed

Stateless: reads the event and the repo's .enforce.json, writes nothing. Any
exception exits non-zero, which the wrapper turns into a deny."""
import copy
import importlib.util
import json
import os
import re
import sys

HOOK_NAME = "infra-mutation-guard"
PARSER_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shell-command-segments.py")
SUBSTITUTION_MARK = "\x00"


def load_parser():
    """Imports shell-command-segments.py, whose file name is not a module name."""
    spec = importlib.util.spec_from_file_location("shell_command_segments", PARSER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PARSER = load_parser()
OPERATOR_MARK = PARSER.OPERATOR_MARK


class EnforceConfigError(Exception):
    """The repo's .enforce.json exists but its environments or provider_hosts
    cannot be read."""


# --- Production classification (B-11, B-12) -------------------------------

PRODUCTION_WORDS = {"prod", "production", "live"}
PRODUCTION_ENV_VARS = ("RAILS_ENV", "NODE_ENV", "APP_ENV", "ENVIRONMENT", "STAGE", "MIX_ENV",
                       "DJANGO_SETTINGS_MODULE")
NAMED_TARGET_ENV_VARS = ("AWS_PROFILE", "TF_WORKSPACE", "PGHOST", "PGHOSTADDR", "MYSQL_HOST", "PGSERVICE")
CONNINFO_TARGET = re.compile(r"(?:^|\s)(?:host|hostaddr|service)\s*=\s*([^\s'\"]+)", re.I)
# A postgres URI names its target in the query too: postgresql:///app?host=db.
URI_QUERY_TARGET = re.compile(r"[?&](?:host|hostaddr|service)=([^&#\s'\"]+)", re.I)
DJANGO_PROGRAMS = ("manage.py", "django-admin", "django")
ENVIRONMENT_OPTIONS = ("-e", "--env", "--environment")
NAMED_TARGET_OPTIONS = ("--context", "--kube-context", "--profile", "-h", "--host")
URL_HOST = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://([^/\s?#]*)")


class Environments:
    """The repo's .enforce.json environments lists and provider_hosts list,
    read together on first use."""

    def __init__(self, cwd):
        self.cwd = cwd
        self.lists = None

    def patterns(self, name):
        if self.lists is None:
            self.lists = read_enforce_lists(find_repo_root(self.cwd))
        return self.lists.get(name, [])

    def matches(self, name, value):
        return any(pattern.match(value) for pattern in self.patterns(name))


def find_repo_root(cwd):
    """Returns the nearest directory at or above cwd holding .git, or None."""
    directory = os.path.abspath(cwd or os.getcwd())
    while True:
        if os.path.exists(os.path.join(directory, ".git")):
            return directory
        parent = os.path.dirname(directory)
        if parent == directory:
            return None
        directory = parent


def read_enforce_lists(repo_root):
    """Returns {list name: [compiled pattern]} from .enforce.json: the
    production, preview and testing environments, and the top-level
    provider_hosts (B-32). * is the only wildcard and matching ignores case."""
    path = os.path.join(repo_root, ".enforce.json") if repo_root else None
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            config = json.load(handle)
        environments = config.get("environments") or {}
        if not isinstance(environments, dict):
            raise TypeError("environments must be an object")
        lists = {}
        for name in ("production", "preview", "testing"):
            lists[name] = wildcard_patterns(environments.get(name) or [], "environments.%s" % name)
        lists["provider_hosts"] = wildcard_patterns(config.get("provider_hosts") or [], "provider_hosts")
        return lists
    except (OSError, ValueError, AttributeError, TypeError) as error:
        raise EnforceConfigError(str(error))


def wildcard_patterns(entries, name):
    if not isinstance(entries, list):
        raise TypeError("%s must be a list" % name)
    if not all(isinstance(entry, str) for entry in entries):
        raise TypeError("%s entries must be strings" % name)
    return [re.compile("^" + re.escape(entry.lower()).replace(r"\*", ".*") + "$") for entry in entries]


def has_production_word(value):
    return bool(PRODUCTION_WORDS & set(re.split(r"[^a-z0-9]+", value)))


def is_production(value, environments, name_rule):
    """True when value marks a production target. Preview and testing entries
    win over everything; a production entry wins over the name rule, which is
    "substring" (contains prod), "exact" (prod or production) or "word"
    (prod, production or live as a word)."""
    value = value.strip().strip("'\"").lower()
    if not value:
        return False
    if environments.matches("preview", value) or environments.matches("testing", value):
        return False
    if environments.matches("production", value):
        return True
    if name_rule == "substring":
        return "prod" in value
    if name_rule == "exact":
        return value in ("prod", "production")
    return has_production_word(value)


def url_hosts(word):
    """Returns the host of every scheme://host URL in word, without userinfo or port."""
    hosts = []
    for authority in URL_HOST.findall(word):
        host = authority.rsplit("@", 1)[-1]
        host = host[1:host.find("]")] if host.startswith("[") else host.split(":", 1)[0]
        hosts.append(host.rstrip("."))
    return hosts


def glued_values(args, flag):
    """Returns the value of each short option written glued to it (-hHOST,
    -eproduction). -help is a flag, not -h elp."""
    return [word[2:] for word in args if word.startswith(flag) and len(word) > 2 and word != "-help"]


def environment_values(args):
    return option_values(args, ENVIRONMENT_OPTIONS) + glued_values(args, "-e")


def option_values(args, names):
    """Returns the values given to any of the options in names, as `--opt v`
    or `--opt=v`. Scanning stops at a bare `--`."""
    values = []
    for index, word in enumerate(args):
        if word == "--":
            break
        if word in names and index + 1 < len(args):
            values.append(args[index + 1])
        elif "=" in word and word.split("=", 1)[0] in names:
            values.append(word.split("=", 1)[1])
    return values


def production_signal(command, environments):
    """Returns a short description of what marks the command production-targeted
    (B-11), or None. Options are read from every argument of the command as
    typed, including those of a launcher (railway run -e production ...);
    rails and rake also take NAME=value arguments as environment."""
    env = dict(command.environment)
    if command.program in ("rails", "rake"):
        env.update(word.split("=", 1) for word in command.args if PARSER.is_assignment(word))
    if command.program in DJANGO_PROGRAMS:
        for value in option_values(command.args, ("--settings",)):
            env["DJANGO_SETTINGS_MODULE"] = value
    for name in PRODUCTION_ENV_VARS:
        if name in env and is_production(env[name], environments, "substring"):
            return "%s=%s" % (name, env[name])
    for name in NAMED_TARGET_ENV_VARS:
        if name in env and is_production(env[name], environments, "word"):
            return "%s=%s" % (name, env[name])
    for value in environment_values(command.typed_args):
        if is_production(value, environments, "exact"):
            return "environment %s" % value
    targets = option_values(command.typed_args, NAMED_TARGET_OPTIONS) + glued_values(command.typed_args, "-h")
    targets += [match for word in command.words for match in CONNINFO_TARGET.findall(word)]
    targets += [host for word in command.words for match in URI_QUERY_TARGET.findall(word)
                for host in match.split(",")]
    for value in targets:
        if is_production(value, environments, "word"):
            return "target %s" % value
    for word in command.words:
        for host in url_hosts(word):
            if is_production(host, environments, "word"):
                return "host %s" % host
    return None


# --- Commands -------------------------------------------------------------

STDIN_REDIRECTS = {OPERATOR_MARK + op for op in ("<", "<<<", "<<", "<<-")}


class SimpleCommand:
    """One parsed simple command: its environment (session exports plus its own
    assignments), program, plain arguments, and every word including redirect
    targets such as a herestring."""

    def __init__(self, segment, session_env, stdin_text=None, kube_context="", is_piped=False, unknown_names=None):
        program_index = PARSER.find_program_index(segment)
        own = dict(word.split("=", 1) for word in segment[:program_index])
        self.environment = dict(session_env, **own)
        self.assignments = own
        rest = segment[program_index:]
        # Lower case, because macOS resolves `AWS` to the aws binary.
        self.program = canonical_program(rest[0].lower()) if rest else ""
        self.args = PARSER.plain_words(rest[1:])
        self.typed_args = self.args
        self.words = [word for word in segment if not word.startswith(OPERATOR_MARK)]
        self.has_heredoc = any(word in (OPERATOR_MARK + "<<", OPERATOR_MARK + "<<-") for word in rest)
        self.stdin_text = stdin_text
        self.kube_context = kube_context
        self.stdin_fed = is_piped or any(word in STDIN_REDIRECTS for word in rest)
        self.unknown_names = unknown_names or set()

    def launched(self):
        """Returns the command a launcher (npx, pnpm dlx, bunx, bundle exec,
        railway run, python manage.py) runs, keeping this command's
        environment and typed arguments; None when there is no launcher."""
        program, args = launched_command(self.program, self.args)
        if (program, args) == (self.program, self.args):
            return None
        inner = copy.copy(self)
        inner.program, inner.args = canonical_program(program.lower()), args
        return inner

    def positionals(self, value_options=(), booleans=None):
        """Returns the arguments that are not options, skipping the value of
        each option in value_options. With booleans given, any other --long
        option written without = also takes the next word as its value, the
        way most CLIs parse an unknown flag. Stops at a bare `--`."""
        result, skip = [], False
        for word in self.args:
            if skip:
                skip = False
            elif word == "--":
                break
            elif word.startswith("-") and len(word) > 1:
                skip = word in value_options or (
                    booleans is not None and word.startswith("--") and "=" not in word and word not in booleans)
            else:
                result.append(word)
        return result

    def positional_readings(self, value_options=(), booleans=()):
        """Returns both readings of the positionals: unknown --flags as
        booleans, and as taking a value. A rule that must be sure of the verb
        checks both."""
        return [self.positionals(value_options), self.positionals(value_options, booleans)]


class Verdict:
    """The strongest decision seen so far and the reason for it."""
    RANK = {"allow": 0, "ask": 1, "deny": 2}

    def __init__(self):
        self.decision, self.reason = "allow", ""

    def add(self, decision, reason):
        if self.RANK[decision] > self.RANK[self.decision]:
            self.decision, self.reason = decision, reason


def deny_reason(rule, what, command_text):
    return redact("%s BLOCKED this call (%s): %s. Agents cannot run this; if it is intended, a human "
                  "runs it by hand in a terminal: %s" % (HOOK_NAME, rule, what, command_text))


def ask_reason(rule, what):
    return redact("%s (%s): %s. Confirm the target with the user before running." % (HOOK_NAME, rule, what))


JSON_SECRET = re.compile(r'("[^"]*(?:pass|token|secret|key)[^"]*"\s*:\s*)"[^"]*"', re.I)
SECRET_ASSIGNMENT = re.compile(r"\b([A-Za-z_]*(?:PASS|PASSWORD|TOKEN|SECRET|KEY)[A-Za-z_]*)=\S+", re.I)


def redact(text):
    """Replaces with *** every secret a command line commonly carries: URL
    passwords, -u/--user credentials, Authorization, X-Auth-Key and other
    *-Key or *-Token header values, Cookie and Set-Cookie header values,
    --token/--password/--secret/--auth style option values, httpie's -a,
    mysql's glued -pSECRET, JSON "password": "..." style members, and
    secret-named assignments."""
    text = re.sub(r"(://[^/\s:@]*:)[^@/\s]*@", r"\1***@", text)
    text = re.sub(r"(?i)(authorization:\s*(?:bearer|basic|token)?\s*)[^\s'\"]+", r"\1***", text)
    text = re.sub(r"(?i)([\w-]*-(?:key|token):\s*)[^\s'\"]+", r"\1***", text)
    text = re.sub(r"((?:^|\s)(?:-u|--user)(?:=|\s+)['\"]?)[^\s'\"]+", r"\1***", text)
    text = re.sub(r"(?i)((?:^|\s)(?:--?(?:token|password|passwd|secret|api-key|oauth2-bearer|access-token|auth)"
                  r"|-a)(?:=|\s+)['\"]?)[^\s'\"]+", r"\1***", text)
    text = re.sub(r"((?:^|\s)-p)[^\s'\"]+", r"\1***", text)
    text = re.sub(r"(?i)((?:set-)?cookie:\s*)(?:[^\s'\";]+;\s*)*[^\s'\"]+", r"\1***", text)
    text = JSON_SECRET.sub(r'\1"***"', text)
    return SECRET_ASSIGNMENT.sub(r"\1=***", text)


# --- Cloud CLIs (B-1, B-2, B-3) ---------------------------------------------

READ_VERB_HEADS = {"list", "describe", "get", "show", "ls", "help", "version"}
MUTATION_VERBS = {
    "create", "delete", "update", "remove", "rm", "set", "unset", "add", "patch", "put", "deploy",
    "destroy", "import", "start", "stop", "restart", "reset", "resize", "move", "mv", "copy", "cp",
    "enable", "disable", "attach", "detach", "apply", "run", "exec", "execute", "submit", "cancel",
    "rollback", "upgrade", "purge", "terminate", "transaction", "edit", "replace", "sync", "restore",
    "promote", "failover", "reboot", "suspend", "resume", "scale", "tag", "untag", "assign",
    "unassign", "invoke", "login", "logout", "revoke", "rotate", "abandon", "clear", "power",
    "deallocate", "shutdown", "rebuild", "snapshot", "binding", "drop", "wipe", "release",
}
# Global options of gcloud and doctl that take a separate value.
GROUP_CLI_VALUE_OPTIONS = {"--project", "--account", "--configuration", "--verbosity", "--format",
                           "--impersonate-service-account", "--billing-project", "--flags-file",
                           "--filter", "--sort-by", "--limit", "--page-size", "--zone", "--region", "--context", "-t", "--access-token",
                           "-o", "--output", "--config", "-u", "--api-url"}
# gcloud and doctl --flags that take no value; any other --flag written
# without = may take the next word as its value (--tags list).
GROUP_CLI_BOOLEANS = {"--quiet", "--async", "--force", "--yes", "--help", "--wait", "--no-header",
                      "--all", "--interactive", "--dangerous", "--trace", "--verbose"}
# Top-level gcloud groups whose names are also verbs: `gcloud run services list`.
GCLOUD_VERB_NAMED_GROUPS = {"run", "deploy"}
# doctl groups whose names are also verbs: `doctl compute snapshot list`.
DOCTL_VERB_NAMED_GROUPS = {"snapshot"}
# gcloud and doctl read operations with hyphenated names. Any other hyphenated
# command word is not a read, so an unknown verb is denied.
GROUP_CLI_READ_OPERATIONS = {"get-iam-policy", "get-credentials", "get-value", "list-grantable-roles",
                             "list-testable-permissions", "get-server-config", "get-ancestors"}
# Command words that act without being in MUTATION_VERBS: a resource named
# like a read verb after one of these (gcloud compute ssh list) is not a read.
ACTING_VERBS = {"ssh", "scp", "clone", "deprecate", "call", "export", "connect", "console", "kill",
                "power-off", "power-on", "power-cycle", "shutdown", "add-iam-policy-binding",
                "remove-iam-policy-binding", "set-iam-policy"}
AWS_VALUE_OPTIONS = {"--region", "--profile", "--output", "--endpoint-url", "--query", "--color",
                     "--ca-bundle", "--cli-read-timeout", "--cli-connect-timeout",
                     "--cli-binary-format"}
AWS_DNS_SERVICES = {"route53", "route53domains", "route53resolver"}
DNS_WORDS = {"dns", "domain", "domains", "records", "record-set", "record-sets"}


def is_read_head(word):
    """aws and az name an operation fully by position, so the first part of a
    hyphenated name decides: get-login-password reads, delete-snapshot does not."""
    return word.lower().split("-")[0] in READ_VERB_HEADS


def is_group_cli_read(word):
    """gcloud and doctl: an exact read word, or a known hyphenated read operation."""
    return word in READ_VERB_HEADS or word in GROUP_CLI_READ_OPERATIONS


def judge_aws(command):
    if "--version" in command.args:
        return None
    positionals = command.positionals(AWS_VALUE_OPTIONS)
    if not positionals or (positionals[-1] == "help" and len(positionals) <= 3) or len(positionals) < 2:
        return None if positionals[:1] != ["configure"] else cloud_mutation(command, positionals)
    service, operation = positionals[0], positionals[1]
    if service == "configure":
        return None if operation in ("list", "get", "list-profiles") else cloud_mutation(command, positionals)
    if is_read_head(operation):
        return None
    return cloud_mutation(command, positionals)


def judge_cloud_cli(command):
    """gcloud, az, doctl: allowed only when the command is a read; every other
    command, unknown verbs included, is denied (B-1, B-2)."""
    positionals = command.positionals(() if command.program == "az" else GROUP_CLI_VALUE_OPTIONS)
    if not positionals:
        return None
    if command.program == "az":
        verb = az_verb(command)
        return None if verb and is_read_head(verb) else cloud_mutation(command, positionals)
    readings = command.positional_readings(GROUP_CLI_VALUE_OPTIONS, GROUP_CLI_BOOLEANS)
    if all(is_group_cli_read_command(command.program, reading) for reading in readings):
        return None
    return cloud_mutation(command, positionals)


def az_verb(command):
    """az names its command entirely before the first option: the verb is the
    last word before it (az vm deallocate -g rg -n x). Boolean global options
    in front of the command (az --only-show-errors vm list) are skipped."""
    words = []
    for word in command.args:
        if word.startswith("-"):
            if words:
                break
            continue
        words.append(word)
    return words[-1] if words else None


def is_group_cli_read_command(program, positionals):
    """gcloud, doctl: the verb is the first read word, and every word before it
    is a group noun. The command reads only when such a verb exists, no word
    before it is a known verb (except groups named like one: gcloud run,
    doctl compute snapshot), and no mutation verb follows it."""
    words = list(positionals)
    while program == "gcloud" and words[:1] and words[0] in ("alpha", "beta"):
        words = words[1:]
    read_index = next((i for i, word in enumerate(words) if is_group_cli_read(word)), None)
    if read_index is None:
        return False
    for index, word in enumerate(words[:read_index]):
        if program == "gcloud" and index == 0 and word in GCLOUD_VERB_NAMED_GROUPS:
            continue
        if program == "doctl" and word in DOCTL_VERB_NAMED_GROUPS:
            continue
        if word in MUTATION_VERBS or word in ACTING_VERBS:
            return False
    return not any(word in MUTATION_VERBS for word in words[read_index + 1:])


def cloud_mutation(command, positionals):
    words = set(positionals)
    aws_dns = command.program == "aws" and positionals[:1] and positionals[0] in AWS_DNS_SERVICES
    if aws_dns or words & DNS_WORDS:
        return ("deny", "B-3", "%s changes DNS records or zones" % command.program)
    return ("deny", "B-2", "%s %s is not a read-only cloud command; every cloud mutation is human-only"
            % (command.program, " ".join(positionals[:3])))


def judge_flarectl(command):
    positionals = command.positionals(("--account-id",))
    group, verb = (positionals + ["", ""])[:2]
    if group in ("dns", "d") and verb not in ("", "list", "l", "help", "h"):
        return ("deny", "B-3", "flarectl dns %s changes DNS records" % verb)
    if group in ("zone", "z") and verb not in ("", "list", "l", "info", "i", "help", "h"):
        return ("deny", "B-3", "flarectl zone %s changes a DNS zone" % verb)
    return None


# cli53 commands that change records or zones, with their short aliases.
CLI53_DENIED = {"rrcreate", "rc", "rrdelete", "rd", "rrpurge", "rp", "create", "c", "delete", "d", "import", "i",
                "instances"}


def judge_cli53(command):
    positionals = command.positionals(("--profile", "--endpoint-url", "--role-arn"))
    if positionals[:1] and positionals[0] in CLI53_DENIED:
        return ("deny", "B-21", "cli53 %s changes DNS records or zones" % positionals[0])
    return None


def judge_dnscontrol(command):
    if any(reading[:1] == ["push"] for reading in command.positional_readings()):
        return ("deny", "B-22", "dnscontrol push changes DNS records at the providers")
    return None


def judge_nsupdate(command):
    if {"-V", "--help", "-h"} & set(command.args):
        return None
    return ("deny", "B-23", "nsupdate sends dynamic DNS updates")


# gsutil global options, and cp/rsync options, that take a separate value.
GSUTIL_VALUE_OPTIONS = {"-o", "-h", "-u", "-i", "-a", "-j", "-z", "-L", "-s", "-x"}
GSUTIL_READ = {"ls", "cat", "du", "stat", "hash", "help", "version", "signurl"}
# gsutil groups whose get or list subcommand reads and whose other subcommands write.
GSUTIL_SETTING_GROUPS = {"acl", "iam", "defacl", "lifecycle", "cors", "versioning", "web", "label", "logging",
                         "notification", "requesterpays", "ubla", "pap", "autoclass", "rpo", "defstorageclass",
                         "retention", "kms", "hmac", "bucketpolicyonly"}


def judge_gsutil(command):
    """B-24: reads pass, a cp whose destination is a bucket and every other
    command, unknown ones included, is denied."""
    positionals = command.positionals(GSUTIL_VALUE_OPTIONS)
    verb, sub = (positionals + ["", ""])[:2]
    if not verb or verb in GSUTIL_READ:
        return None
    if verb in GSUTIL_SETTING_GROUPS and sub in ("get", "list", "ls"):
        return None
    if verb == "cp" and len(positionals) > 2 and "://" not in positionals[-1]:
        return None
    return ("deny", "B-24", "gsutil %s writes to Cloud Storage" % " ".join(positionals[:2]))


BQ_VALUE_OPTIONS = {"--project_id", "--location", "--format", "--dataset_id", "--api", "--apilog",
                    "--bigqueryrc", "--credential_file", "--service_account", "--job_id", "-n", "--max_rows"}
BQ_READ = {"ls", "show", "head", "help", "version", "wait", "get-iam-policy", "mkdef", "info"}
BQ_WRITE_SQL = re.compile(r"\b(DROP|TRUNCATE|DELETE|INSERT|UPDATE|MERGE|CREATE|ALTER)\b", re.I)


def judge_bq(command, raw_text):
    """B-25: reads pass; a query passes unless its SQL holds a write keyword
    or it writes its result to a table; every other command is denied."""
    readings = command.positional_readings(BQ_VALUE_OPTIONS)
    verbs = {(reading + [""])[0] for reading in readings}
    if verbs <= BQ_READ | {""}:
        return None
    if verbs == {"query"}:
        texts = command.args + ([raw_text] if command.has_heredoc else [])
        texts += [command.stdin_text] if command.stdin_text else []
        match = next((m for m in map(BQ_WRITE_SQL.search, texts) if m), None)
        if match:
            return ("deny", "B-25", "bq query runs %s, which writes to BigQuery" % match.group(1).upper())
        if option_values(command.args, ("--destination_table",)):
            return ("deny", "B-25", "bq query --destination_table writes its result to a table")
        return None
    return ("deny", "B-25", "bq %s writes to BigQuery" % " ".join(sorted(verbs - {""})))


S3CMD_VALUE_OPTIONS = {"-c", "--config", "--access_key", "--secret_key", "--access_token", "--region", "--host",
                       "--host-bucket", "--bucket-location"}
S3CMD_READ = {"ls", "la", "get", "info", "du", "help", "cfinfo", "cflist"}


def judge_s3cmd(command):
    """B-26: reads pass; every other command, unknown ones included, is denied."""
    positionals = command.positionals(S3CMD_VALUE_OPTIONS)
    if not positionals or positionals[0] in S3CMD_READ:
        return None
    return ("deny", "B-26", "s3cmd %s writes to object storage" % positionals[0])


AZD_DENIED = {"up", "down", "deploy", "provision"}


def judge_azd(command):
    positionals = command.positionals(("-e", "--environment", "-C", "--cwd"))
    if positionals[:1] and positionals[0] in AZD_DENIED:
        return ("deny", "B-27", "azd %s changes Azure resources" % positionals[0])
    return None


# --- Provider API calls (B-4) ---------------------------------------------

PROVIDER_HOSTS = {"api.cloudflare.com", "management.azure.com", "api.digitalocean.com",
                  "api.vercel.com", "api.fly.io", "api.heroku.com", "backboard.railway.app",
                  "api.netlify.com", "api.namecheap.com", "api.godaddy.com", "api.gandi.net",
                  "api.porkbun.com"}
PROVIDER_HOST_SUFFIXES = (".amazonaws.com", ".googleapis.com")
READ_METHODS = {"GET", "HEAD", "OPTIONS"}
CURL_VALUE_SHORT = set("XdFHoAuUeEKbcrTwmyYzCQxDtP")
# curl --options that take the next word as their value; any other --option
# is read as a flag when looking for the URLs.
CURL_VALUE_LONG = {
    "--request", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii", "--json",
    "--form", "--form-string", "--header", "--user", "--output", "--url", "--variable", "--cookie",
    "--cookie-jar", "--user-agent", "--referer", "--upload-file", "--config", "--connect-timeout",
    "--max-time", "--retry", "--proxy", "--proxy-user", "--resolve", "--connect-to", "--cacert", "--cert",
    "--key", "--write-out", "--oauth2-bearer", "--aws-sigv4", "--interface", "--limit-rate", "--range",
    "--dns-servers", "--output-dir", "--continue-at", "--max-filesize", "--retry-delay", "--retry-max-time",
    "--unix-socket", "--abstract-unix-socket", "--doh-url", "--trace", "--trace-ascii", "--stderr",
    "--dump-header", "--time-cond", "--quote", "--preproxy", "--socks5", "--socks5-hostname", "--noproxy",
}
# A URL-ish word without a scheme: host.name[:port] and optional path.
URLISH_AUTHORITY = re.compile(r"^[A-Za-z0-9_.{}\[\],*-]*\.[A-Za-z0-9_.{}\[\],*-]*(?::[0-9{}\[\],-]*)?$")


def word_host(word):
    """Returns the lower-case host a URL-ish word names, with or without a scheme."""
    rest = word.split("://", 1)[1] if "://" in word else word
    authority = re.split(r"[/?#]", rest, maxsplit=1)[0].rsplit("@", 1)[-1]
    return authority.split(":", 1)[0].lower().rstrip(".")


def is_provider_host(host, environments):
    """True for a built-in provider API host or one the repo's .enforce.json
    provider_hosts lists (B-32)."""
    if host in PROVIDER_HOSTS or host.endswith(PROVIDER_HOST_SUFFIXES):
        return True
    return environments.matches("provider_hosts", host)


def curl_method(args):
    """Returns the method curl sends: an explicit -X/--request, else POST when
    data or a form is attached (unless -G), PUT for an upload, else GET."""
    method, has_body, as_get, upload = None, False, False, False
    index = 0
    while index < len(args):
        word = args[index]
        nxt = args[index + 1] if index + 1 < len(args) else ""
        if word == "--":
            break
        if word.startswith("--"):
            name, _, inline = word.partition("=")
            value = inline if "=" in word else nxt
            if name == "--request":
                method = value
            elif name.startswith("--data") or name in ("--form", "--form-string", "--json"):
                has_body = True
            elif name == "--get":
                as_get = True
            elif name == "--upload-file":
                upload = True
            index += 1
            continue
        if word.startswith("-") and len(word) > 1:
            for position, letter in enumerate(word[1:], 1):
                if letter in CURL_VALUE_SHORT:
                    value = word[position + 1:] or nxt
                    if letter == "X":
                        method = value
                    elif letter in "dF":
                        has_body = True
                    elif letter == "T":
                        upload = True
                    if not word[position + 1:]:
                        index += 1
                    break
                if letter == "G":
                    as_get = True
        index += 1
    if method:
        return method.upper()
    if has_body and not as_get:
        return "POST"
    return "PUT" if upload else "GET"


def curl_urls(args):
    """Returns curl's positional arguments, its URLs, skipping each option's value."""
    urls, index = [], 0
    while index < len(args):
        word = args[index]
        if word == "--":
            return urls + args[index + 1:]
        if word.startswith("--"):
            index += 2 if word in CURL_VALUE_LONG else 1
            continue
        if word.startswith("-") and len(word) > 1:
            for position, letter in enumerate(word[1:], 1):
                if letter in CURL_VALUE_SHORT:
                    index += 0 if word[position + 1:] else 1
                    break
        else:
            urls.append(word)
        index += 1
    return urls + option_values(args, ("--url",))


def is_url_word(word):
    """True when word is a scheme://URL or a scheme-less host.name/path."""
    if "://" in word:
        return True
    return bool(URLISH_AUTHORITY.match(re.split(r"[/?#]", word, maxsplit=1)[0]))


def wget_method(args):
    method = None
    for value in option_values(args, ("--method",)):
        method = value
    if method:
        return method.upper()
    if any(word.split("=", 1)[0] in ("--post-data", "--post-file", "--body-data", "--body-file")
           for word in args):
        return "POST"
    return "GET"


HTTPIE_VALUE_OPTIONS = {"-a", "--auth", "-A", "--auth-type", "--session", "--session-read-only",
                        "-o", "--output", "--verify", "--cert", "--cert-key", "--timeout", "-p",
                        "--print", "--pretty", "-s", "--style", "--proxy", "--default-scheme",
                        "--raw", "--max-redirects", "--response-charset", "--response-mime", "--boundary"}


def httpie_method(command):
    """Returns the method httpie or xh sends: an explicit METHOD before the URL,
    else POST when standard input carries a body (a redirect, heredoc or
    pipe, unless --ignore-stdin), a data item (a=b, a:=b, a@file), --form or
    a --raw body is given, else GET."""
    positionals = command.positionals(HTTPIE_VALUE_OPTIONS)
    for index, word in enumerate(positionals[:-1]):
        if re.match(r"^[A-Za-z]+$", word):
            return word.upper()
    if command.stdin_fed and not {"--ignore-stdin", "-I"} & set(command.args):
        return "POST"
    items = positionals[1:]
    has_data = any(re.search(r":=|(?<![=])=(?!=)|@", item) and "==" not in item for item in items)
    has_raw_body = any(word == "--raw" or word.startswith("--raw=") for word in command.args)
    body_flags = {"-f", "--form", "--multipart"} & set(command.args)
    return "POST" if has_data or has_raw_body or body_flags else "GET"


def judge_http_client(command, environments):
    program = command.program
    if program == "curl":
        method = curl_method(command.args)
    elif program == "wget":
        method = wget_method(command.args)
    else:
        method = httpie_method(command)
    if method in READ_METHODS:
        return None
    urls = [word for word in command.args if not word.startswith("-")]
    urls += option_values(command.args, ("--url",))
    target = next((word_host(url) for url in urls if is_provider_host(word_host(url), environments)), None)
    if target is None and program == "curl" and not {"-g", "--globoff"} & set(command.args):
        # curl expands {a,b} and [1-3] in a URL, so a globbed host can be any host.
        target = next((url for url in curl_urls(command.args)
                       if is_url_word(url) and re.search(r"[{\[]", word_host(url))), None)
    if target is None and program == "curl" and any(
            word.split("=", 1)[0] == "--variable" or word.startswith("--expand-") for word in command.args):
        # --variable with --expand-url builds the host at run time from values
        # this guard cannot see.
        target = "a host built by --variable/--expand-*"
    if target is None:
        unknown = [url for url in urls if references_unknown(url, command.unknown_names)]
        if unknown:
            return ("ask", "B-4", "%s %s to %s, whose host comes from a variable set at run time (read, printf -v)"
                    % (program, method, unknown[0]))
        return None
    return ("deny", "B-4", "%s %s to the provider API %s changes cloud or DNS state" % (program, method, target))


# --- Infrastructure tools (B-5 .. B-8) -------------------------------------

TERRAFORM_DENIED = {"apply", "destroy", "import", "taint", "untaint", "force-unlock", "refresh"}
TERRAFORM_STATE_DENIED = {"rm", "mv", "push", "replace-provider"}


HELP_FLAGS = {"-help", "--help", "-h"}


def judge_terraform(command):
    if HELP_FLAGS & set(command.args):
        return None
    return terraform_verdict(command.program, command.positionals(), "B-5")


def terraform_verdict(program, positionals, rule):
    verb, sub = (positionals + ["", ""])[:2]
    if (verb in TERRAFORM_DENIED or (verb == "state" and sub in TERRAFORM_STATE_DENIED)
            or (verb == "workspace" and sub == "delete")):
        return ("deny", rule, "%s %s changes real infrastructure or its state" % (program, " ".join(positionals[:2])))
    return None


TERRAGRUNT_VALUE_OPTIONS = {
    "--terragrunt-working-dir", "--working-dir", "--terragrunt-config", "--config", "--terragrunt-tfpath",
    "--tf-path", "--terragrunt-iam-role", "--iam-assume-role", "--terragrunt-source", "--source",
    "--terragrunt-log-level", "--log-level", "--terragrunt-parallelism", "--parallelism",
    "--terragrunt-include-dir", "--queue-include-dir", "--terragrunt-exclude-dir", "--queue-exclude-dir"}
# Words that run a terraform command across units: run-all apply, run --all
# -- apply, stack run apply.
TERRAGRUNT_RUNNERS = {"run-all", "run", "stack"}
TERRAGRUNT_DENIED = {"apply-all", "destroy-all"}


def judge_terragrunt(command):
    """B-28: the terraform command terragrunt runs, directly or through
    run-all, run [--all] [--] or stack run, is judged like terraform."""
    if HELP_FLAGS & set(command.args):
        return None
    inner = copy.copy(command)
    inner.args = [word for word in command.args if word != "--"]
    positionals = inner.positionals(TERRAGRUNT_VALUE_OPTIONS)
    while positionals[:1] and positionals[0] in TERRAGRUNT_RUNNERS:
        positionals = positionals[1:]
    if positionals[:1] and positionals[0] in TERRAGRUNT_DENIED:
        return ("deny", "B-28", "terragrunt %s changes real infrastructure" % positionals[0])
    return terraform_verdict("terragrunt", positionals, "B-28")


CDK_DENIED = {"deploy", "destroy", "watch", "bootstrap", "import", "rollback"}
SAM_DENIED = {"deploy", "delete", "sync", "publish"}
SAM_DENIED_PAIRS = {("pipeline", "bootstrap"), ("remote", "invoke")}
SERVERLESS_DENIED = {"deploy", "remove", "rollback"}
DEPLOY_TOOL_VALUE_OPTIONS = {"-a", "--app", "-c", "--context", "--profile", "-o", "--output", "--role-arn",
                             "-t", "--template", "--template-file", "--stack-name", "--region", "--config-file",
                             "--config-env", "-s", "--stage", "-r", "--config", "-f", "--function"}


def judge_deploy_tool(command):
    """B-29: cdk, sam and serverless commands that deploy or remove stacks
    are denied; synth, diff, build, validate, local and package pass."""
    positionals = command.positionals(DEPLOY_TOOL_VALUE_OPTIONS)
    verb, sub = (positionals + ["", ""])[:2]
    program = command.program
    denied = ((program == "cdk" and verb in CDK_DENIED)
              or (program == "sam" and (verb in SAM_DENIED or (verb, sub) in SAM_DENIED_PAIRS))
              or (program == "serverless" and (verb in SERVERLESS_DENIED or (verb == "invoke" and sub != "local"))))
    if denied:
        return ("deny", "B-29", "%s %s deploys or removes a cloud stack" % (program, verb))
    return None


EKSCTL_READ = {"get", "info", "version", "help", "completion"}
EKSCTL_READ_UTILS = {"write-kubeconfig", "schema", "nodegroup-health"}


def judge_eksctl(command):
    """B-30: reads pass; every other command, unknown ones included, is denied."""
    positionals = command.positionals(("--name", "--cluster", "--region", "--profile", "-f", "--config-file"))
    verb, sub = (positionals + ["", ""])[:2]
    if not verb or verb in EKSCTL_READ:
        return None
    if verb == "utils" and (sub.startswith("describe-") or sub in EKSCTL_READ_UTILS):
        return None
    return ("deny", "B-30", "eksctl %s changes an EKS cluster" % " ".join(positionals[:2]))


PULUMI_VALUE_OPTIONS = {"--cwd", "-C", "--stack", "-s", "--color", "--config-file", "--tracing", "--profiling",
                        "-v", "--verbose"}
PULUMI_BOOLEANS = {"--yes", "--skip-preview", "--diff", "--refresh", "--non-interactive", "--emoji",
                   "--logtostderr", "--debug", "--json", "--show-secrets", "--expect-no-changes",
                   "--suppress-outputs", "--force", "--help", "--disable-integrity-checking"}
PULUMI_DENIED = {"up", "update", "destroy", "down", "dn", "refresh", "cancel", "import", "watch"}
PULUMI_DENIED_PAIRS = {("stack", "rm"), ("stack", "remove"), ("stack", "import"), ("state", "delete"),
                       ("state", "unprotect"), ("state", "move"), ("state", "rename")}


def judge_pulumi(command):
    if HELP_FLAGS & set(command.args):
        return None
    for positionals in command.positional_readings(PULUMI_VALUE_OPTIONS, PULUMI_BOOLEANS):
        verb, sub = (positionals + ["", ""])[:2]
        if verb in PULUMI_DENIED or (verb, sub) in PULUMI_DENIED_PAIRS:
            return ("deny", "B-6", "pulumi %s changes real infrastructure or its state" % " ".join(positionals[:2]))
    return None


LOCAL_CONTEXT = re.compile(r"^(kind-.*|minikube|docker-desktop|k3d-.*|rancher-desktop)$")
KUBECTL_VALUE_OPTIONS = {"--context", "--kubeconfig", "--cluster", "--user", "-n", "--namespace", "-s",
                         "--server", "--token", "--as", "--as-group", "--request-timeout", "-l",
                         "--selector", "-o", "--output", "-f", "--filename", "-c", "--container"}
KUBECTL_READ = {"get", "describe", "logs", "top", "explain", "version", "api-resources", "api-versions",
                "cluster-info", "diff"}
KUBECTL_READ_PAIRS = {("config", "view"), ("config", "get-contexts"), ("config", "current-context"),
                      ("auth", "can-i"), ("rollout", "status"), ("rollout", "history")}
# OpenShift's oc reads on top of the kubectl ones (B-31).
OC_READ = {"whoami", "status", "projects"}
HELM_VALUE_OPTIONS = {"--kube-context", "--kubeconfig", "-n", "--namespace"}
HELM_CONTEXT_VERBS = {"install", "upgrade", "uninstall", "rollback", "delete", "del", "un"}


def judge_cluster_mutation(command, context_option, rule, environments):
    """B-7 context rule: a local context passes, a production one is denied,
    any other context, or none, asks."""
    contexts = option_values(command.args, (context_option,))
    context = contexts[-1] if contexts else command.kube_context
    action = "%s %s" % (command.program, " ".join(command.positionals(KUBECTL_VALUE_OPTIONS | HELM_VALUE_OPTIONS)[:2]))
    for server in option_values(command.args, ("--server", "-s", "--kube-apiserver")):
        if is_production(word_host(server), environments, "word"):
            return ("deny", rule, "%s against the production API server %s" % (action, server))
    for value in option_values(command.args, ("--cluster", "--user")):
        if is_production(value, environments, "word"):
            return ("deny", rule, "%s against the production cluster or user %s" % (action, value))
    for value in option_values(command.args, ("--kubeconfig",)):
        if is_production(os.path.basename(value), environments, "word"):
            return ("deny", rule, "%s through the production kubeconfig %s" % (action, value))
    if context and LOCAL_CONTEXT.match(context):
        return None
    if context and is_production(context, environments, "word"):
        return ("deny", rule, "%s against the production context %s" % (action, context))
    where = "context %s" % context if context else "the current kube context"
    return ("ask", rule, "%s mutates a cluster through %s, which is not a known local cluster" % (action, where))


def judge_kubectl(command, environments):
    """B-7 for kubectl, and for oc, which takes the same verbs and contexts (B-31)."""
    positionals = command.positionals(KUBECTL_VALUE_OPTIONS)
    if not positionals:
        return None
    verb, sub = (positionals + [""])[:2]
    if verb in KUBECTL_READ or (verb, sub) in KUBECTL_READ_PAIRS or (command.program == "oc" and verb in OC_READ):
        return None
    return judge_cluster_mutation(command, "--context", "B-7", environments)


def judge_helm(command, environments):
    positionals = command.positionals(HELM_VALUE_OPTIONS)
    if not positionals or positionals[0] not in HELM_CONTEXT_VERBS:
        return None
    return judge_cluster_mutation(command, "--kube-context", "B-8", environments)


# --- PaaS (B-9, B-10) --------------------------------------------------------

def judge_fly(command, environments):
    positionals = command.positionals(("-a", "--app", "-c", "--config", "-r", "--region"))
    verb, sub = (positionals + ["", ""])[:2]
    if {"destroy", "remove", "rm"} & set(positionals[:3]):
        return ("deny", "B-9", "%s %s destroys a Fly resource" % (command.program, " ".join(positionals[:3])))
    for value in option_values(command.args, ("-a", "--app")):
        if is_production(value, environments, "word"):
            return ("deny", "B-10", "fly against the production app %s" % value)
    if verb == "deploy":
        for value in option_values(command.args, ("-a", "--app", "-c", "--config")):
            if is_production(os.path.basename(value), environments, "word"):
                return ("deny", "B-10", "fly deploy to the production app or config %s" % value)
    return None


def judge_heroku(command, environments):
    positionals = command.positionals(("-a", "--app", "-r", "--remote"))
    if positionals[:1] and positionals[0] in ("apps:destroy", "destroy", "pg:reset", "addons:destroy"):
        return ("deny", "B-9", "heroku %s destroys a Heroku resource" % positionals[0])
    for value in option_values(command.args, ("-a", "--app")):
        if is_production(value, environments, "word"):
            return ("deny", "B-10", "heroku against the production app %s" % value)
    return None


def environment_is_production(command, environments):
    return any(is_production(value, environments, "exact") for value in environment_values(command.args))


def judge_railway(command, environments):
    positionals = command.positionals(("-e", "--environment", "-s", "--service"))
    verb = positionals[0] if positionals else ""
    if verb in ("down", "delete"):
        return ("deny", "B-9", "railway %s removes a Railway deployment or project" % verb)
    if verb == "up" and environment_is_production(command, environments):
        return ("deny", "B-10", "railway up to the production environment")
    return None


def judge_vercel(command, environments):
    positionals = command.positionals(("--scope", "--token", "-t", "--target", "--cwd"))
    group, verb = (positionals + ["", ""])[:2]
    if ((group == "dns" and verb in ("add", "rm", "remove", "import"))
            or (group in ("domains", "domain") and verb in ("rm", "remove", "move"))):
        return ("deny", "B-3", "vercel %s %s changes DNS records or domains" % (group, verb))
    if group == "alias" and verb not in ("", "ls", "list", "help"):
        return ("deny", "B-10", "vercel alias %s changes which deployment a production domain serves" % verb)
    if {"remove", "rm"} & set(positionals[:2]):
        return ("deny", "B-9", "vercel %s removes a Vercel deployment or project" % " ".join(positionals[:2]))
    if group in ("promote", "rollback"):
        return ("deny", "B-10", "vercel %s changes the production deployment" % group)
    targets = option_values(command.args, ("--target",))
    prod_flag = any(word == "--prod" or (word.startswith("--prod=") and word[7:].lower() not in ("false", "0"))
                    for word in command.args)
    if prod_flag or any(is_production(value, environments, "exact") for value in targets):
        return ("deny", "B-10", "vercel production deploy")
    return None


def judge_netlify(command, environments):
    positionals = command.positionals(("--dir", "-d", "--site", "-s", "--auth", "--alias", "--message", "-m",
                                       "--functions", "-f", "--data"))
    verb, sub = (positionals + ["", ""])[:2]
    if verb == "sites:delete":
        return ("deny", "B-9", "netlify sites:delete removes a Netlify site")
    if verb == "deploy" and {"--prod", "-p", "--prod-if-unlocked"} & set(command.args):
        return ("deny", "B-10", "netlify production deploy")
    if verb == "api" and sub and not re.match(r"^(get|list)", sub):
        return ("deny", "B-9", "netlify api %s changes Netlify resources" % sub)
    return None


def judge_wrangler(command, environments):
    positionals = command.positionals(("-e", "--env", "-c", "--config"))
    verb, sub = (positionals + ["", ""])[:2]
    if verb == "dns" and sub not in ("", "list", "ls", "get", "help"):
        return ("deny", "B-3", "wrangler dns %s changes DNS records" % sub)
    if "delete" in positionals[:3]:
        return ("deny", "B-9", "wrangler %s deletes a Cloudflare resource" % " ".join(positionals[:positionals.index("delete") + 1]))
    if verb in ("deploy", "publish") and environment_is_production(command, environments):
        return ("deny", "B-10", "wrangler %s to the production environment" % verb)
    return None


# --- ORM, migrations and SQL (B-13 .. B-17) --------------------------------

LAUNCHER_SUBCOMMANDS = {"bundle": ("exec",), "poetry": ("run",), "uv": ("run",), "pipenv": ("run",),
                        "railway": ("run",), "npm": ("exec", "x"), "pnpm": ("exec", "dlx"),
                        "yarn": ("exec", "dlx"), "bun": ("x", "run"),
                        "heroku": ("run", "run:detached", "run:inside")}
# Launcher subcommands that take positionals before the program: the dyno of
# heroku run:inside DYNO COMMAND.
LAUNCHER_POSITIONALS = {("heroku", "run:inside"): 1}
LAUNCHER_VALUE_OPTIONS = {"-p", "--package", "-e", "--environment", "-s", "--service", "-c", "-a", "--app",
                          "-r", "--remote", "--call"}
PYTHONS = re.compile(r"^python(\d+(\.\d+)?)?$")


# Other names the same CLIs install under.
PROGRAM_ALIASES = {"vc": "vercel", "ntl": "netlify", "netlify-cli": "netlify", "sls": "serverless",
                   "aws-cdk": "cdk"}


def canonical_program(name):
    """Returns the CLI a program name runs: vc is vercel, ntl is netlify, sls
    is serverless, the aws-cdk package is cdk."""
    return PROGRAM_ALIASES.get(name, name)


def launched_program_name(word):
    """Returns the program a launcher runs: a package spec loses its @version
    (wrangler@3 is wrangler) but keeps its @scope/ prefix; a path is reduced
    to its basename."""
    if word.startswith("@"):
        return "@" + word[1:].split("@", 1)[0]
    return os.path.basename(word).split("@", 1)[0]


def launched_command(program, args):
    """Returns the program and arguments a launcher (npx, bundle exec, railway
    run, python manage.py) actually runs, unwrapping up to three levels."""
    for _ in range(3):
        rest, positionals = None, 0
        if program in ("npx", "bunx", "pnpx"):
            rest = args
        elif program in LAUNCHER_SUBCOMMANDS and args[:1] and args[0] in LAUNCHER_SUBCOMMANDS[program]:
            rest, positionals = args[1:], LAUNCHER_POSITIONALS.get((program, args[0]), 0)
        elif program in ("pnpm", "yarn") and args[:1] and not args[0].startswith("-"):
            rest = args
        elif PYTHONS.match(program) and args[:1] == ["-m"] and len(args) > 1:
            rest = args[1:]
        elif PYTHONS.match(program):
            scripts = [word for word in args if not word.startswith("-")]
            if scripts and os.path.basename(scripts[0]) == "manage.py":
                rest = args[args.index(scripts[0]):]
        if rest is None:
            break
        index = 0
        while index < len(rest) and (rest[index].startswith("-") or positionals):
            if rest[index].startswith("-"):
                index += 2 if rest[index] in LAUNCHER_VALUE_OPTIONS else 1
            else:
                index, positionals = index + 1, positionals - 1
        if index >= len(rest):
            break
        program, args = launched_program_name(rest[index]), rest[index + 1:]
    return program, args


def classify_database_command(program, args):
    """Returns "data-loss" (B-14), "migration" (B-17) or None."""
    first, second = (args + ["", ""])[:2]
    flags = set(args)
    if program == "prisma":
        if (first, second) == ("migrate", "reset"):
            return "data-loss"
        if (first, second) == ("db", "push") and flags & {"--accept-data-loss", "--force-reset"}:
            return "data-loss"
        if (first, second) == ("migrate", "deploy"):
            return "migration"
    elif program in ("rails", "rake"):
        if flags & {"db:drop", "db:reset", "db:purge", "db:schema:load", "db:migrate:reset", "db:truncate_all",
                    "db:seed:replant", "db:setup"}:
            return "data-loss"
        if "db:migrate" in flags:
            return "migration"
    elif program in DJANGO_PROGRAMS:
        if first in ("flush", "reset_db"):
            return "data-loss"
        if first == "migrate":
            return "migration"
    elif program == "alembic":
        positionals = [w for w in args if not w.startswith("-")]
        if positionals[:2] == ["downgrade", "base"]:
            return "data-loss"
        if positionals[:1] == ["upgrade"]:
            return "migration"
    elif program == "knex":
        if first == "migrate:rollback" and "--all" in flags:
            return "data-loss"
        if first == "migrate:latest":
            return "migration"
    elif program in ("sequelize", "sequelize-cli"):
        if first in ("db:migrate:undo:all", "db:drop"):
            return "data-loss"
        if first == "db:migrate":
            return "migration"
    elif program.startswith("typeorm"):
        if first == "schema:drop":
            return "data-loss"
        if first == "migration:run":
            return "migration"
    elif program == "drizzle-kit":
        if first == "drop":
            return "data-loss"
        if first == "migrate":
            return "migration"
    elif program == "mix":
        if first == "ecto.drop":
            return "data-loss"
        if first == "ecto.migrate":
            return "migration"
    elif program == "dbmate" and "drop" in flags:
        return "data-loss"
    elif program == "flyway" and "clean" in flags:
        return "data-loss"
    elif program == "migrate" and "down" in flags:
        return "data-loss"
    return None


def judge_database_command(command, environments):
    program, args = command.program, command.args
    kind = classify_database_command(program, args)
    if kind is None:
        return None
    action = "%s %s" % (program, " ".join(args[:2]))
    signal = production_signal(command, environments)
    if kind == "data-loss":
        if signal:
            return ("deny", "B-14", "%s destroys data on a production target (%s)" % (action, signal))
        return ("ask", "B-14", "%s destroys database data" % action)
    if signal:
        return ("deny", "B-17", "%s runs a migration against a production target (%s)" % (action, signal))
    return None


TEXT_PROGRAMS = {"echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "git", "gh", "cat", "sed",
                 "awk", "jq", "man", "less", "head", "tail"}
# ALTER TABLE t DROP name drops a column without the COLUMN keyword; dropping a
# constraint, index, key, default or NOT NULL loses no data.
DESTRUCTIVE_SQL = re.compile(r"DROP\s+(DATABASE|SCHEMA|TABLE|OWNED|COLUMN)|TRUNCATE(\s|$)|DELETE\s+FROM"
                             r"|ALTER\s+TABLE\b[^;]*\bDROP\s+(?!\s|(?:CONSTRAINT|INDEX|KEY|PRIMARY|FOREIGN|CHECK"
                             r"|DEFAULT|NOT|IDENTITY|EXPRESSION|PARTITIONING)\b)")
SQL_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
SQL_LINE_COMMENT = re.compile(r"--[^\n]*")
DESTRUCTIVE_TOOL = re.compile(r"pg_restore|migrate:down", re.I)
# A SQL client whose text carries DROP or TRUNCATE as a bare word is treated as
# destructive whatever separates the keyword from its object: comment syntax
# (--, #, nested /* */) varies by dialect, so matching it is a losing race.
SQL_CLIENTS = {"psql", "mysql", "mariadb", "sqlcmd", "pgcli", "mycli"}
DESTRUCTIVE_KEYWORD = re.compile(r"\b(DROP|TRUNCATE)\b")
UNBOUNDED_UPDATE = re.compile(r"\bUPDATE\s+(ONLY\s+)?\S+(\s+(AS\s+)?\w+)?\s+SET\b")
UNBOUNDED_DELETE = re.compile(r"\bDELETE\s+FROM\b")
WHERE = re.compile(r"\bWHERE\b")


def has_top_level_where(text):
    """True when text has a WHERE outside every parenthesis: a WHERE inside a
    subquery (SET a = (SELECT ... WHERE ...)) does not bound the statement."""
    depth, top_level = 0, []
    for char in text:
        depth += {"(": 1, ")": -1}.get(char, 0)
        top_level.append(char if depth == 0 and char != ")" else " ")
    return bool(WHERE.search("".join(top_level)))


def sql_readings(text):
    """Returns the ways text can read as SQL: as written, with /* */ comments
    removed, and with -- comments removed as well, each with whitespace
    collapsed. A rule matches when any reading does, so a comment cannot split
    a keyword (DROP/**/TABLE) and a quoted '--' cannot hide the rest."""
    without_blocks = SQL_BLOCK_COMMENT.sub(" ", text)
    without_comments = SQL_BLOCK_COMMENT.sub(" ", SQL_LINE_COMMENT.sub(" ", text))
    return [text] + [re.sub(r"\s+", " ", reading) for reading in (without_blocks, without_comments)]


def unbounded_statement(texts, statement):
    """True when any ;-separated statement in texts matches statement and has
    no top-level WHERE after it."""
    for text in texts:
        for part in text.upper().split(";"):
            match = statement.search(part)
            if match and not has_top_level_where(part[match.end():]):
                return True
    return False


def is_destructive_database_tool(command):
    """dropdb, and mysqladmin drop, delete a whole database."""
    return command.program == "dropdb" or (command.program == "mysqladmin" and "drop" in command.positionals(
        ("-h", "--host", "-u", "--user", "-P", "--port", "-S", "--socket")))


def judge_sql(command, raw_text, environments):
    if command.program in TEXT_PROGRAMS or not command.program:
        return None
    texts = command.words + ([raw_text] if command.has_heredoc else [])
    texts += [command.stdin_text] if command.stdin_text else []
    texts = [reading for text in texts for reading in sql_readings(text)]
    joined = " ".join(texts)
    destructive = bool(DESTRUCTIVE_SQL.search(joined.upper()) or DESTRUCTIVE_TOOL.search(joined)
                       or is_destructive_database_tool(command)
                       or (command.program in SQL_CLIENTS and DESTRUCTIVE_KEYWORD.search(joined.upper())))
    unbounded_update = unbounded_statement(texts, UNBOUNDED_UPDATE)
    unbounded_delete = unbounded_statement(texts, UNBOUNDED_DELETE)
    if not (destructive or unbounded_update or unbounded_delete):
        return None
    signal = production_signal(command, environments)
    if signal and destructive:
        return ("deny", "B-13", "destructive SQL against a production target (%s)" % signal)
    if unbounded_update:
        if signal:
            return ("deny", "B-15", "UPDATE with no WHERE against a production target (%s)" % signal)
        return ("ask", "B-15", "UPDATE ... SET with no WHERE rewrites every row")
    if unbounded_delete:
        return ("ask", "B-16", "DELETE FROM with no WHERE removes every row")
    return None


# --- Dispatch ---------------------------------------------------------------

# Judges that need only the command.
STATELESS_JUDGES = {
    "flarectl": judge_flarectl, "cli53": judge_cli53, "dnscontrol": judge_dnscontrol, "nsupdate": judge_nsupdate,
    "gsutil": judge_gsutil, "s3cmd": judge_s3cmd, "azd": judge_azd, "terraform": judge_terraform,
    "tofu": judge_terraform, "terragrunt": judge_terragrunt, "pulumi": judge_pulumi, "cdk": judge_deploy_tool,
    "sam": judge_deploy_tool, "serverless": judge_deploy_tool, "eksctl": judge_eksctl}


def strongest(verdicts):
    verdicts = [v for v in verdicts if v]
    return max(verdicts, key=lambda v: Verdict.RANK[v[0]]) if verdicts else None


def judge_command(command, raw_text, environments):
    """Returns (decision, rule, what) for the strongest rule one simple
    command, or the command a launcher in it runs, meets, or None."""
    inner = command.launched()
    return strongest([judge_program(command, raw_text, environments),
                      judge_program(inner, raw_text, environments) if inner else None,
                      judge_unknown_wrapper(inner or command)])


def judge_program(command, raw_text, environments):
    """Returns the strongest rule the command's own program meets, or None."""
    program = command.program
    if program == "aws":
        return judge_aws(command)
    if program in ("gcloud", "az", "doctl"):
        return judge_cloud_cli(command)
    if program in STATELESS_JUDGES:
        return STATELESS_JUDGES[program](command)
    if program == "bq":
        return judge_bq(command, raw_text)
    if program in ("curl", "wget", "http", "https", "xh", "xhs"):
        return judge_http_client(command, environments)
    if program in ("kubectl", "oc"):
        return judge_kubectl(command, environments)
    if program == "helm":
        return judge_helm(command, environments)
    paas = {"fly": judge_fly, "flyctl": judge_fly, "heroku": judge_heroku, "railway": judge_railway,
            "vercel": judge_vercel, "netlify": judge_netlify, "wrangler": judge_wrangler}
    verdicts = [paas[program](command, environments)] if program in paas else []
    verdicts += [judge_database_command(command, environments), judge_sql(command, raw_text, environments)]
    return strongest(verdicts)


def substituted_program(word):
    """Stands in for the parser's program_name while looking for B-18: a
    program word that is a command substitution is kept, marked, instead of
    being resolved to the program `which` would print."""
    if word.startswith("$(") or word.startswith("`"):
        return SUBSTITUTION_MARK + word
    return ORIGINAL_PROGRAM_NAME(word)


ORIGINAL_PROGRAM_NAME = PARSER.program_name


def substitution_program_segments(text):
    """Returns the segments whose command word is a command substitution."""
    PARSER.program_name = substituted_program
    try:
        segments = PARSER.split_segments(text)
    finally:
        PARSER.program_name = ORIGINAL_PROGRAM_NAME
    found = []
    for segment in segments:
        index = PARSER.find_program_index(segment)
        if index < len(segment) and segment[index].startswith(SUBSTITUTION_MARK):
            found.append(segment[index][1:])
    return found


VARIABLE_REFERENCE = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")


def expand_variables(segment, session_env):
    """Expands $NAME and ${NAME} from assignments made earlier in the same
    command (H=api.cloudflare.com; curl https://$H/...); other references
    are left as written."""
    def value_of(match):
        name = match.group(1) or match.group(2)
        return session_env.get(name, match.group(0))
    return [word if word.startswith(OPERATOR_MARK) else VARIABLE_REFERENCE.sub(value_of, word)
            for word in segment]


def references_unknown(word, unknown_names):
    """True when word refers to a variable whose value is set at run time."""
    return any((match.group(1) or match.group(2)) in unknown_names for match in VARIABLE_REFERENCE.finditer(word))


# A program word that expands a variable: $c, ${c}, $1, "$@". $( is a command
# substitution, which substitution_program_segments reports.
VARIABLE_PROGRAM = re.compile(r"\$(?:\{|[A-Za-z_0-9@*#?!-])")
DECLARATION_PROGRAMS = {"export", "declare", "typeset", "local", "readonly"}
# read options that take a value; -a takes an array name, which read sets.
READ_VALUE_OPTIONS = set("dinNptu")


def program_word(segment):
    index = PARSER.find_program_index(segment)
    return segment[index] if index < len(segment) else ""


def names_set_at_run_time(command):
    """Returns the variables `read NAME...` and `printf -v NAME` set from
    values this guard cannot see."""
    if command.program == "printf":
        return option_values(command.args, ("-v",)) + glued_values(command.args, "-v")
    if command.program != "read":
        return []
    names, index = [], 0
    while index < len(command.args):
        word = command.args[index]
        if word.startswith("-") and len(word) > 1:
            for position, letter in enumerate(word[1:], 1):
                if letter in READ_VALUE_OPTIONS or letter == "a":
                    glued = word[position + 1:]
                    value = glued or (command.args[index + 1] if index + 1 < len(command.args) else "")
                    names += [value] if letter == "a" and value else []
                    index += 0 if glued else 1
                    break
        else:
            names.append(word)
        index += 1
    return names


# Programs judged on their own, and the in-scope CLIs an unknown wrapper may run.
IN_SCOPE_PROGRAMS = {"aws", "gcloud", "az", "doctl", "flarectl", "curl", "wget", "http", "https", "xh", "xhs",
                     "terraform", "tofu", "pulumi", "kubectl", "helm", "fly", "flyctl", "heroku", "railway",
                     "vercel", "netlify", "wrangler", "cli53", "dnscontrol", "nsupdate", "gsutil", "bq", "s3cmd",
                     "azd", "terragrunt", "cdk", "sam", "serverless", "eksctl", "oc"}
# Programs whose arguments name a CLI without running it: package managers,
# lookups, launchers (unwrapped by launched()) and shells (whose command
# strings are parsed as segments).
NAMING_PROGRAMS = TEXT_PROGRAMS | PARSER.SHELLS | {
    "eval", "which", "type", "whereis", "whatis", "help", "tldr", "info", "brew", "apt", "apt-get", "yum", "dnf",
    "apk", "pacman", "pip", "pip3", "pipx", "gem", "cargo", "go", "asdf", "mise", "nix", "snap", "choco",
    "winget", "scoop", "npm", "pnpm", "yarn", "bun", "bunx", "npx", "pnpx", "bundle", "poetry", "uv", "pipenv"}


def runs_in_scope_cli(word):
    """True when word is an in-scope CLI name followed by arguments in one
    string ("gcloud compute ..."), or is the bare CLI name."""
    tokens = word.split()
    return bool(tokens) and canonical_program(os.path.basename(tokens[0]).lower()) in IN_SCOPE_PROGRAMS


def judge_unknown_wrapper(command):
    """B-18 class rule: a program this guard does not know as a wrapper whose
    arguments run an in-scope CLI (taskset 1 gcloud ..., watch gcloud ...,
    su -c "gcloud ...") may run it, so it asks. The CLI must be followed by
    more words, so `brew install terraform`-like naming passes."""
    if command.program in IN_SCOPE_PROGRAMS or command.program in NAMING_PROGRAMS:
        return None
    args = command.args
    for index, word in enumerate(args):
        if word.startswith("-") or not runs_in_scope_cli(word):
            continue
        if len(word.split()) > 1 or index + 1 < len(args):
            return ("ask", "B-18", "%s runs %s, so a cloud, infrastructure or PaaS command may run through a "
                    "wrapper this guard does not unwrap" % (command.program, word.split()[0]))
    return None


def split_segments_with_input(text):
    """Returns (segment, piped_text, is_piped) triples, where piped_text is
    what an echo or printf before a pipe feeds the segment (echo "DROP TABLE
    x" | psql), as the parser computes it for shells, else None, and is_piped
    tells whether any command pipes into the segment."""
    input_by_segment = {}
    original = PARSER.expand_segment

    def recording_expand(segment, piped_text, is_piped=False):
        input_by_segment[id(segment)] = (piped_text, is_piped)
        return original(segment, piped_text, is_piped)

    PARSER.expand_segment = recording_expand
    try:
        segments = PARSER.split_segments(text)
    finally:
        PARSER.expand_segment = original
    return [(segment,) + input_by_segment.get(id(segment), (None, False)) for segment in segments]


def launcher_command_string(command):
    """Returns the command string npx -c or npm exec --call runs, or None."""
    runs_package = command.program in ("npx", "pnpx") or (
        command.program in ("npm", "pnpm") and command.args[:1] and command.args[0] in ("exec", "x"))
    if not runs_package:
        return None
    strings = option_values(command.args, ("-c", "--call"))
    return strings[-1] if strings else None


def switched_kube_context(command):
    """Returns X for `kubectl config use-context X`, `kubectl ctx X`,
    `kubectx X` or `kubie ctx X`, else None."""
    positionals = command.positionals(KUBECTL_VALUE_OPTIONS)
    if command.program in ("kubectl", "oc") and positionals[:2] == ["config", "use-context"] and len(positionals) > 2:
        return positionals[2]
    if command.program == "kubectl" and positionals[:1] == ["ctx"] and len(positionals) > 1:
        return positionals[1]
    if command.program == "kubie" and positionals[:1] == ["ctx"] and len(positionals) > 1:
        return positionals[1]
    if command.program == "kubectx" and positionals:
        return positionals[0]
    return None


def decide(text, cwd):
    """Returns a Verdict for the whole command text."""
    verdict = Verdict()
    environments = Environments(cwd)
    session_env, kube_context, unknown_names = {}, "", set()
    queue = split_segments_with_input(text)
    while queue:
        segment, stdin_text, is_piped = queue.pop(0)
        expanded = expand_variables(segment, session_env)
        written_program = program_word(segment)
        if VARIABLE_PROGRAM.search(written_program):
            # The value may itself be a wrapper (c=sudo; $c gcloud ...).
            expanded = PARSER.normalize_segment(expanded, [])
            if re.search(r"[\s$]", program_word(expanded)):
                verdict.add("ask", ask_reason("B-18", "the command word %s comes from a variable, so the program "
                                                      "that runs is unknown until it runs" % written_program))
                continue
        command = SimpleCommand(expanded, session_env, stdin_text, kube_context, is_piped, unknown_names)
        if not command.program or command.program in DECLARATION_PROGRAMS:
            assignments = dict(command.assignments) if not command.program else dict(
                w.split("=", 1) for w in command.args if PARSER.is_assignment(w))
            session_env.update(assignments)
            unknown_names.difference_update(assignments)
            continue
        for name in names_set_at_run_time(command):
            session_env.pop(name, None)
            unknown_names.add(name)
        inner_text = launcher_command_string(command)
        if inner_text:
            queue = split_segments_with_input(inner_text) + queue
        kube_context = switched_kube_context(command) or kube_context
        result = judge_command(command, text, environments)
        if result:
            decision, rule, what = result
            reason = deny_reason(rule, what, text) if decision == "deny" else ask_reason(rule, what)
            verdict.add(decision, reason)
    for word in substitution_program_segments(text):
        verdict.add("ask", ask_reason("B-18", "the command word %s is a command substitution, so the "
                                              "program that runs is unknown until it runs" % word))
    return verdict


def main():
    event = json.loads(sys.stdin.read() or "{}")
    if event.get("tool_name") not in (None, "Bash"):
        return
    text = (event.get("tool_input") or {}).get("command") or ""
    if not text.strip():
        return
    try:
        verdict = decide(text, event.get("cwd") or "")
    except EnforceConfigError as error:
        verdict = Verdict()
        verdict.add("deny", "%s BLOCKED this call: the environments or provider_hosts in .enforce.json cannot be "
                            "read (%s), so production targets and provider API hosts cannot be told apart. Fix "
                            ".enforce.json outside the session."
                    % (HOOK_NAME, error))
    if verdict.decision == "allow":
        return
    sys.stdout.write(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": verdict.decision,
        "permissionDecisionReason": verdict.reason,
    }}) + "\n")


if __name__ == "__main__":
    main()
