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
  B-18      a command word that is a command substitution asks

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
    """The repo's .enforce.json exists but its environments cannot be read."""


# --- Production classification (B-11, B-12) -------------------------------

PRODUCTION_WORDS = {"prod", "production", "live"}
PRODUCTION_ENV_VARS = ("RAILS_ENV", "NODE_ENV", "APP_ENV", "ENVIRONMENT", "STAGE", "MIX_ENV",
                       "DJANGO_SETTINGS_MODULE")
NAMED_TARGET_ENV_VARS = ("AWS_PROFILE", "TF_WORKSPACE")
ENVIRONMENT_OPTIONS = ("-e", "--env", "--environment")
NAMED_TARGET_OPTIONS = ("--context", "--kube-context", "--profile", "-h", "--host")
URL_HOST = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://([^/\s?#]*)")


class Environments:
    """The repo's .enforce.json environments lists, read on first use."""

    def __init__(self, cwd):
        self.cwd = cwd
        self.lists = None

    def patterns(self, name):
        if self.lists is None:
            self.lists = read_environments(find_repo_root(self.cwd))
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


def read_environments(repo_root):
    """Returns {list name: [compiled pattern]} from .enforce.json, where * is
    the only wildcard and matching ignores case."""
    path = os.path.join(repo_root, ".enforce.json") if repo_root else None
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            environments = json.load(handle).get("environments") or {}
        if not isinstance(environments, dict):
            raise TypeError("environments must be an object")
        lists = {}
        for name in ("production", "preview", "testing"):
            entries = environments.get(name) or []
            if not isinstance(entries, list):
                raise TypeError("environments.%s must be a list" % name)
            lists[name] = [wildcard_pattern(entry) for entry in entries]
        return lists
    except (OSError, ValueError, AttributeError, TypeError) as error:
        raise EnforceConfigError(str(error))


def wildcard_pattern(entry):
    if not isinstance(entry, str):
        raise TypeError("environments entries must be strings")
    return re.compile("^" + re.escape(entry.lower()).replace(r"\*", ".*") + "$")


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


def glued_host_values(args):
    """Returns the host of each -hHOST option written as one word."""
    return [word[2:] for word in args if word.startswith("-h") and len(word) > 2 and word != "-help"]


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
    for name in PRODUCTION_ENV_VARS:
        if name in env and is_production(env[name], environments, "substring"):
            return "%s=%s" % (name, env[name])
    for name in NAMED_TARGET_ENV_VARS:
        if name in env and is_production(env[name], environments, "word"):
            return "%s=%s" % (name, env[name])
    for value in option_values(command.typed_args, ENVIRONMENT_OPTIONS):
        if is_production(value, environments, "exact"):
            return "environment %s" % value
    for value in option_values(command.typed_args, NAMED_TARGET_OPTIONS) + glued_host_values(command.typed_args):
        if is_production(value, environments, "word"):
            return "target %s" % value
    for word in command.words:
        for host in url_hosts(word):
            if is_production(host, environments, "word"):
                return "host %s" % host
    return None


# --- Commands -------------------------------------------------------------

class SimpleCommand:
    """One parsed simple command: its environment (session exports plus its own
    assignments), program, plain arguments, and every word including redirect
    targets such as a herestring."""

    def __init__(self, segment, session_env):
        program_index = PARSER.find_program_index(segment)
        own = dict(word.split("=", 1) for word in segment[:program_index])
        self.environment = dict(session_env, **own)
        self.assignments = own
        rest = segment[program_index:]
        # Lower case, because macOS resolves `AWS` to the aws binary.
        self.program = rest[0].lower() if rest else ""
        self.args = PARSER.plain_words(rest[1:])
        self.typed_args = self.args
        self.words = [word for word in segment if not word.startswith(OPERATOR_MARK)]
        self.has_heredoc = any(word in (OPERATOR_MARK + "<<", OPERATOR_MARK + "<<-") for word in rest)

    def launched(self):
        """Returns the command a launcher (npx, pnpm dlx, bunx, bundle exec,
        railway run, python manage.py) runs, keeping this command's
        environment and typed arguments; None when there is no launcher."""
        program, args = launched_command(self.program, self.args)
        if (program, args) == (self.program, self.args):
            return None
        inner = copy.copy(self)
        inner.program, inner.args = program.lower(), args
        return inner

    def positionals(self, value_options=()):
        """Returns the arguments that are not options, skipping the value of
        each option in value_options. Stops at a bare `--`."""
        result, skip = [], False
        for word in self.args:
            if skip:
                skip = False
            elif word == "--":
                break
            elif word.startswith("-") and len(word) > 1:
                skip = word in value_options
            else:
                result.append(word)
        return result


class Verdict:
    """The strongest decision seen so far and the reason for it."""
    RANK = {"allow": 0, "ask": 1, "deny": 2}

    def __init__(self):
        self.decision, self.reason = "allow", ""

    def add(self, decision, reason):
        if self.RANK[decision] > self.RANK[self.decision]:
            self.decision, self.reason = decision, reason


def deny_reason(rule, what, command_text):
    return ("%s BLOCKED this call (%s): %s. Agents cannot run this; if it is intended, a human "
            "runs it by hand in a terminal: %s" % (HOOK_NAME, rule, what, redact(command_text)))


def ask_reason(rule, what):
    return "%s (%s): %s. Confirm the target with the user before running." % (HOOK_NAME, rule, what)


SECRET_ASSIGNMENT = re.compile(r"\b([A-Za-z_]*(?:PASS|PASSWORD|TOKEN|SECRET|KEY)[A-Za-z_]*)=\S+", re.I)


def redact(text):
    """Replaces with *** every secret a command line commonly carries: URL
    passwords, -u/--user credentials, Authorization, X-Auth-Key and other
    *-Key or *-Token header values, and secret-named assignments."""
    text = re.sub(r"(://[^/\s:@]*:)[^@/\s]*@", r"\1***@", text)
    text = re.sub(r"(?i)(authorization:\s*(?:bearer|basic|token)?\s*)[^\s'\"]+", r"\1***", text)
    text = re.sub(r"(?i)([\w-]*-(?:key|token):\s*)[^\s'\"]+", r"\1***", text)
    text = re.sub(r"((?:^|\s)(?:-u|--user)(?:=|\s+)['\"]?)[^\s'\"]+", r"\1***", text)
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
                           "--filter", "--zone", "--region", "--context", "-t", "--access-token",
                           "-o", "--output", "--config", "-u", "--api-url"}
# Top-level groups whose names are also verbs: `gcloud run services list`.
GCLOUD_VERB_NAMED_GROUPS = {"run", "deploy"}
AWS_VALUE_OPTIONS = {"--region", "--profile", "--output", "--endpoint-url", "--query", "--color",
                     "--ca-bundle", "--cli-read-timeout", "--cli-connect-timeout",
                     "--cli-binary-format"}
AWS_DNS_SERVICES = {"route53", "route53domains", "route53resolver"}
DNS_WORDS = {"dns", "domain", "domains", "records", "record-set", "record-sets"}


def is_read_verb(word):
    """True when a hyphenated verb starts with a read word (list, describe,
    get, show, ls, help, version) and none of its parts is a mutation verb:
    list-keys reads, listener and get-and-delete do not."""
    parts = word.lower().split("-")
    return parts[0] in READ_VERB_HEADS and not set(parts[1:]) & MUTATION_VERBS


def is_mutation_verb(word):
    return bool(set(word.lower().split("-")) & MUTATION_VERBS)


def judge_aws(command):
    if "--version" in command.args:
        return None
    positionals = command.positionals(AWS_VALUE_OPTIONS)
    if not positionals or positionals[-1] == "help" or len(positionals) < 2:
        return None if positionals[:1] != ["configure"] else cloud_mutation(command, positionals)
    service, operation = positionals[0], positionals[1]
    if service == "configure":
        return None if operation in ("list", "get", "list-profiles") else cloud_mutation(command, positionals)
    if is_read_verb(operation):
        return None
    return cloud_mutation(command, positionals)


def judge_cloud_cli(command):
    """gcloud, az, doctl: allowed only when the command's verb is a read verb;
    every other command, unknown verbs included, is denied (B-1, B-2)."""
    positionals = command.positionals(() if command.program == "az" else GROUP_CLI_VALUE_OPTIONS)
    if not positionals:
        return None
    verb = az_verb(command) if command.program == "az" else group_cli_verb(command.program, positionals)
    after = positionals[positionals.index(verb) + 1:] if verb in positionals else []
    if verb and is_read_verb(verb) and not any(word in MUTATION_VERBS for word in after):
        return None
    return cloud_mutation(command, positionals)


def az_verb(command):
    """az names its command entirely before the first option: the verb is the
    last word before it (az vm deallocate -g rg -n x)."""
    words = []
    for word in command.args:
        if word.startswith("-"):
            break
        words.append(word)
    return words[-1] if words else None


def group_cli_verb(program, positionals):
    """gcloud, doctl: the verb is the first positional that reads or mutates;
    the groups before it are nouns. Returns None when no positional is a verb."""
    for index, word in enumerate(positionals):
        if index == 0 and program == "gcloud" and word in GCLOUD_VERB_NAMED_GROUPS:
            continue
        if word == "transaction":
            continue
        if is_read_verb(word) or is_mutation_verb(word):
            return word
    return None


def cloud_mutation(command, positionals):
    words = set(positionals)
    aws_dns = command.program == "aws" and positionals[:1] and positionals[0] in AWS_DNS_SERVICES
    if aws_dns or words & DNS_WORDS:
        return ("deny", "B-3", "%s changes DNS records or zones" % command.program)
    return ("deny", "B-2", "%s %s is not a read-only cloud command; every cloud mutation is human-only"
            % (command.program, " ".join(positionals[:3])))


def judge_flarectl(command):
    positionals = command.positionals()
    group, verb = (positionals + ["", ""])[:2]
    if group in ("dns", "d") and verb not in ("", "list", "l", "help", "h"):
        return ("deny", "B-3", "flarectl dns %s changes DNS records" % verb)
    if group in ("zone", "z") and verb not in ("", "list", "l", "info", "i", "help", "h"):
        return ("deny", "B-3", "flarectl zone %s changes a DNS zone" % verb)
    return None


# --- Provider API calls (B-4) ---------------------------------------------

PROVIDER_HOSTS = {"api.cloudflare.com", "management.azure.com", "api.digitalocean.com",
                  "api.vercel.com", "api.fly.io", "api.heroku.com", "backboard.railway.app",
                  "api.netlify.com", "api.namecheap.com", "api.godaddy.com", "api.gandi.net",
                  "api.porkbun.com"}
PROVIDER_HOST_SUFFIXES = (".amazonaws.com", ".googleapis.com")
READ_METHODS = {"GET", "HEAD", "OPTIONS"}
CURL_VALUE_SHORT = set("XdFHoAuUeEKbcrTwmyYzCQxDtP")


def word_host(word):
    """Returns the lower-case host a URL-ish word names, with or without a scheme."""
    rest = word.split("://", 1)[1] if "://" in word else word
    authority = re.split(r"[/?#]", rest, maxsplit=1)[0].rsplit("@", 1)[-1]
    return authority.split(":", 1)[0].lower().rstrip(".")


def is_provider_host(host):
    return host in PROVIDER_HOSTS or host.endswith(PROVIDER_HOST_SUFFIXES)


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
                        "--print", "--pretty", "-s", "--style", "--proxy", "--default-scheme"}


def httpie_method(command):
    """Returns the method httpie or xh sends: an explicit METHOD before the URL,
    else POST when a data item (a=b, a:=b, a@file) or --form is given, else GET."""
    positionals = command.positionals(HTTPIE_VALUE_OPTIONS)
    if len(positionals) >= 2 and re.match(r"^[A-Za-z]+$", positionals[0]):
        return positionals[0].upper()
    items = positionals[1:]
    has_data = any(re.search(r":=|(?<![=])=(?!=)|@", item) and "==" not in item for item in items)
    return "POST" if has_data or {"-f", "--form", "--multipart"} & set(command.args) else "GET"


def judge_http_client(command):
    program = command.program
    if program == "curl":
        method = curl_method(command.args)
    elif program == "wget":
        method = wget_method(command.args)
    else:
        method = httpie_method(command)
    if method in READ_METHODS:
        return None
    hosts = [word_host(word) for word in command.args if not word.startswith("-")]
    hosts += [word_host(value) for value in option_values(command.args, ("--url",))]
    target = next((host for host in hosts if is_provider_host(host)), None)
    if target is None:
        return None
    return ("deny", "B-4", "%s %s to the provider API %s changes cloud or DNS state" % (program, method, target))


# --- Infrastructure tools (B-5 .. B-8) -------------------------------------

TERRAFORM_DENIED = {"apply", "destroy", "import", "taint", "untaint", "force-unlock", "refresh"}
TERRAFORM_STATE_DENIED = {"rm", "mv", "push", "replace-provider"}


HELP_FLAGS = {"-help", "--help", "-h"}


def judge_terraform(command):
    if HELP_FLAGS & set(command.args):
        return None
    positionals = command.positionals()
    verb, sub = (positionals + ["", ""])[:2]
    if (verb in TERRAFORM_DENIED or (verb == "state" and sub in TERRAFORM_STATE_DENIED)
            or (verb == "workspace" and sub == "delete")):
        return ("deny", "B-5", "%s %s changes real infrastructure or its state" % (command.program, " ".join(positionals[:2])))
    return None


PULUMI_VALUE_OPTIONS = {"--cwd", "-C", "--stack", "-s", "--color", "--config-file", "--tracing", "--profiling"}
PULUMI_DENIED = {"up", "update", "destroy", "down", "refresh", "cancel"}


def judge_pulumi(command):
    if HELP_FLAGS & set(command.args):
        return None
    positionals = command.positionals(PULUMI_VALUE_OPTIONS)
    verb, sub = (positionals + ["", ""])[:2]
    if (verb in PULUMI_DENIED or (verb == "stack" and sub in ("rm", "remove"))
            or (verb == "state" and sub == "delete")):
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
HELM_VALUE_OPTIONS = {"--kube-context", "--kubeconfig", "-n", "--namespace"}
HELM_CONTEXT_VERBS = {"install", "upgrade", "uninstall", "rollback", "delete", "del", "un"}


def judge_cluster_mutation(command, context_option, rule, environments):
    """B-7 context rule: a local context passes, a production one is denied,
    any other context, or none, asks."""
    contexts = option_values(command.args, (context_option,))
    context = contexts[-1] if contexts else ""
    action = "%s %s" % (command.program, " ".join(command.positionals(KUBECTL_VALUE_OPTIONS | HELM_VALUE_OPTIONS)[:2]))
    if context and LOCAL_CONTEXT.match(context):
        return None
    if context and is_production(context, environments, "word"):
        return ("deny", rule, "%s against the production context %s" % (action, context))
    where = "context %s" % context if context else "the current kube context"
    return ("ask", rule, "%s mutates a cluster through %s, which is not a known local cluster" % (action, where))


def judge_kubectl(command, environments):
    positionals = command.positionals(KUBECTL_VALUE_OPTIONS)
    if not positionals:
        return None
    verb, sub = (positionals + [""])[:2]
    if verb in KUBECTL_READ or (verb, sub) in KUBECTL_READ_PAIRS:
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
    if verb == "destroy" or (verb in ("apps", "app", "volumes", "volume", "vol", "postgres", "pg")
                             and sub == "destroy"):
        return ("deny", "B-9", "%s %s destroys a Fly resource" % (command.program, " ".join(positionals[:2])))
    if verb == "deploy":
        for value in option_values(command.args, ("-a", "--app", "-c", "--config")):
            if is_production(os.path.basename(value), environments, "word"):
                return ("deny", "B-10", "fly deploy to the production app or config %s" % value)
    return None


def judge_heroku(command, environments):
    positionals = command.positionals(("-a", "--app", "-r", "--remote"))
    if positionals[:1] and positionals[0] in ("apps:destroy", "pg:reset", "addons:destroy"):
        return ("deny", "B-9", "heroku %s destroys a Heroku resource" % positionals[0])
    for value in option_values(command.args, ("-a", "--app")):
        if is_production(value, environments, "word"):
            return ("deny", "B-10", "heroku against the production app %s" % value)
    return None


def environment_is_production(command, environments):
    return any(is_production(value, environments, "exact")
               for value in option_values(command.args, ENVIRONMENT_OPTIONS))


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
    if positionals[:1] and positionals[0] in ("remove", "rm"):
        return ("deny", "B-9", "vercel %s removes a Vercel deployment or project" % positionals[0])
    targets = option_values(command.args, ("--target",))
    if "--prod" in command.args or any(is_production(value, environments, "exact") for value in targets):
        return ("deny", "B-10", "vercel production deploy")
    return None


def judge_netlify(command, environments):
    if command.positionals()[:1] == ["sites:delete"]:
        return ("deny", "B-9", "netlify sites:delete removes a Netlify site")
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
                        "yarn": ("exec", "dlx"), "bun": ("x", "run")}
LAUNCHER_VALUE_OPTIONS = {"-p", "--package", "-e", "--environment", "-s", "--service", "-c"}
PYTHONS = re.compile(r"^python(\d+(\.\d+)?)?$")


def launched_command(program, args):
    """Returns the program and arguments a launcher (npx, bundle exec, railway
    run, python manage.py) actually runs, unwrapping up to three levels."""
    for _ in range(3):
        rest = None
        if program in ("npx", "bunx", "pnpx"):
            rest = args
        elif program in LAUNCHER_SUBCOMMANDS and args[:1] and args[0] in LAUNCHER_SUBCOMMANDS[program]:
            rest = args[1:]
        elif program in ("pnpm", "yarn") and args[:1] and not args[0].startswith("-"):
            rest = args
        elif PYTHONS.match(program):
            scripts = [word for word in args if not word.startswith("-")]
            if scripts and os.path.basename(scripts[0]) == "manage.py":
                rest = args[args.index(scripts[0]):]
        if rest is None:
            break
        index = 0
        while index < len(rest) and rest[index].startswith("-"):
            index += 2 if rest[index] in LAUNCHER_VALUE_OPTIONS else 1
        if index >= len(rest):
            break
        program, args = os.path.basename(rest[index]), rest[index + 1:]
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
        if flags & {"db:drop", "db:reset", "db:purge", "db:schema:load"}:
            return "data-loss"
        if "db:migrate" in flags:
            return "migration"
    elif program == "manage.py":
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
    elif program in ("sequelize", "sequelize-cli") and first == "db:migrate:undo:all":
        return "data-loss"
    elif program.startswith("typeorm") and first == "schema:drop":
        return "data-loss"
    elif program == "drizzle-kit" and first == "drop":
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
DESTRUCTIVE_SQL = re.compile(r"DROP\s+(DATABASE|TABLE)|TRUNCATE(\s|$)|DELETE\s+FROM")
DESTRUCTIVE_TOOL = re.compile(r"pg_restore|migrate:down", re.I)
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


def unbounded_statement(texts, statement):
    """True when any ;-separated statement in texts matches statement and has
    no top-level WHERE after it."""
    for text in texts:
        for part in text.upper().split(";"):
            match = statement.search(part)
            if match and not has_top_level_where(part[match.end():]):
                return True
    return False


def judge_sql(command, raw_text, environments):
    if command.program in TEXT_PROGRAMS or not command.program:
        return None
    texts = command.words + ([raw_text] if command.has_heredoc else [])
    joined = " ".join(texts)
    destructive = bool(DESTRUCTIVE_SQL.search(joined.upper()) or DESTRUCTIVE_TOOL.search(joined))
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

def strongest(verdicts):
    verdicts = [v for v in verdicts if v]
    return max(verdicts, key=lambda v: Verdict.RANK[v[0]]) if verdicts else None


def judge_command(command, raw_text, environments):
    """Returns (decision, rule, what) for the strongest rule one simple
    command, or the command a launcher in it runs, meets, or None."""
    inner = command.launched()
    return strongest([judge_program(command, raw_text, environments),
                      judge_program(inner, raw_text, environments) if inner else None])


def judge_program(command, raw_text, environments):
    """Returns the strongest rule the command's own program meets, or None."""
    program = command.program
    if program == "aws":
        return judge_aws(command)
    if program in ("gcloud", "az", "doctl"):
        return judge_cloud_cli(command)
    if program == "flarectl":
        return judge_flarectl(command)
    if program in ("curl", "wget", "http", "https", "xh", "xhs"):
        return judge_http_client(command)
    if program in ("terraform", "tofu"):
        return judge_terraform(command)
    if program == "pulumi":
        return judge_pulumi(command)
    if program == "kubectl":
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


def decide(text, cwd):
    """Returns a Verdict for the whole command text."""
    verdict = Verdict()
    environments = Environments(cwd)
    session_env = {}
    for segment in PARSER.split_segments(text):
        command = SimpleCommand(segment, session_env)
        if not command.program:
            session_env.update(command.assignments)
            continue
        if command.program == "export":
            session_env.update(dict(w.split("=", 1) for w in command.args if PARSER.is_assignment(w)))
            continue
        result = judge_command(command, text, environments)
        if result:
            decision, rule, what = result
            reason = deny_reason(rule, what, text) if decision == "deny" else ask_reason(rule, what)
            verdict.add(decision, reason)
    for word in substitution_program_segments(text):
        verdict.add("ask", ask_reason("B-18", "the command word %s is a command substitution, so the "
                                              "program that runs is unknown until it runs" % redact(word)))
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
        verdict.add("deny", "%s BLOCKED this call: the environments in .enforce.json cannot be read (%s), "
                            "so production targets cannot be told apart. Fix .enforce.json outside the session."
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
