"""Deterministic data-access checker for Python: the decidable halves of R-361 and R-362.

Ruff cannot load custom rules, so this standard-library script is the Python
counterpart of the ESLint rules no-query-in-loop and transaction-client-required.
push-ruff-gate.sh runs it over the Python files of the outgoing diff and keeps
only the findings on lines that diff adds.

Usage: python3 python_data_access.py <file>...
Prints a JSON array, one object per finding:
    {"file": "<path as given>", "line": <int>, "rule": "R-361" | "R-362", "message": "..."}
Exits 0 with or without findings, and 2 on bad usage. A file that cannot be
read or parsed is skipped, because a syntax error is ruff's to report.

A data-access call is:
  - a method call named execute, scalar, scalars, scalar_one, stream, or
    stream_scalars on any object that passes at least one argument (the
    statement); the argument requirement keeps `result.scalars()` and
    `result.scalar_one()` on an already fetched Result from counting;
  - a call to a name imported from a module whose dotted path has a
    `repositories` or `db` segment (`from app.repositories.trips import get_trip`,
    `from app.repositories import trips` then `trips.get_trip(...)`,
    `import app.repositories.trips` then `app.repositories.trips.get_trip(...)`).
    Names imported from a `tables` module (`from app.db.tables import trips_table`)
    are excluded: table metadata builds statements, it does not run them.

R-361 (N+1) reports a data-access call evaluated once per iteration: in the body
of a `for` or `async for`, in the test or body of a `while`, and in the element,
key, or value expression, an `if` filter, or a later `for` clause's iterable of a
list, set, or dict comprehension or a generator expression, which is how
`asyncio.gather(*(repo.get(x) for x in ids))` is caught. The iterable of a `for`
and the first iterable of a comprehension run once and are not reported. The
walk stops at a `def`, `async def`, `class`, or `lambda` boundary, except a
lambda that is itself the per-element expression of a comprehension or the
function passed to `map` or `filter`.

R-362 reports, inside an explicit transaction block (`with`/`async with` over
`<expr>.begin()` or `<expr>.begin_nested()`):
  (a) a call to `httpx`, `requests`, or `aiohttp` (a module function, or a
      method on a client bound from one), or to a name imported from a module
      path with a `clients` segment: network I/O holding the transaction open;
  (b) a data-access call that is not given the transaction's connection. The
      connection is the `as` name and the receiver of `begin`/`begin_nested`,
      unless the receiver is named like an engine; SQLAlchemy binds a
      transaction, not a connection, to `connection.begin_nested() as savepoint`,
      so the receiver is the connection there. A repository call passes when any
      positional or keyword argument is one of those names, and an execute-style
      method passes when it is called on one.

What it does NOT decide: a query hidden behind a helper defined elsewhere
(interprocedural, left to the query-budget test); a repository method called on
an instance that already holds its connection (`trips.insert_trip(body)`); the
request-scoped `get_connection` dependency, whose transaction spans the route
and has no block to inspect; whether a group of writes needed a transaction at
all, which is intent and goes to the judge.

Suppression: `# data-access-allow: <reason>` on the finding's line or the line
directly above it, with a non-empty reason (a bounded keyset batch, say). Test
files, conftest.py, and scripts/, migrations/, and alembic/ trees are exempt.
"""

import ast
import json
import re
import sys

QUERY_METHODS = frozenset({"execute", "scalar", "scalars", "scalar_one", "stream", "stream_scalars"})
DATA_ACCESS_SEGMENTS = frozenset({"repositories", "db"})
NON_EXECUTING_SEGMENTS = frozenset({"tables"})
CLIENT_SEGMENTS = frozenset({"clients"})
NETWORK_MODULES = frozenset({"httpx", "requests", "aiohttp"})
TRANSACTION_METHODS = frozenset({"begin", "begin_nested"})
ITERATION_BUILTINS = frozenset({"map", "filter"})
EXEMPT_DIRECTORIES = frozenset({"tests", "test", "scripts", "migrations", "alembic"})
COMPREHENSIONS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
COMPREHENSION_LABELS = {
    ast.ListComp: "list comprehension",
    ast.SetComp: "set comprehension",
    ast.DictComp: "dict comprehension",
    ast.GeneratorExp: "generator expression",
}
SCOPE_BOUNDARIES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)
ALLOW_COMMENT = re.compile(r"#\s*data-access-allow:\s*\S")
USAGE_EXIT = 2

N_PLUS_ONE_FIX = (
    "load the set in one query (`WHERE id = ANY(:ids)`, a join, or `selectinload`) or write it in one "
    "statement, then work in memory; a deliberately bounded loop takes `# data-access-allow: <the bound>`."
)


def is_exempt(path):
    """Return True for test files and for trees that R-36x exempts (scripts, migrations)."""
    segments = path.replace("\\", "/").split("/")
    name = segments[-1]
    if name == "conftest.py" or name.startswith("test_") or name.endswith("_test.py"):
        return True
    return any(segment in EXEMPT_DIRECTORIES for segment in segments[:-1])


def dotted_name(node):
    """Return `a.b.c` for a Name or a chain of attributes on a Name, else None."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        base = dotted_name(node.value)
        return base + "." + node.attr if base else None
    return None


def module_segments(module_path):
    """Split a dotted module path into its segments, ignoring relative-import dots."""
    return [segment for segment in module_path.split(".") if segment]


class Bindings:
    """Names and dotted prefixes a file binds to data-access, client, and network modules."""

    def __init__(self, tree):
        self.data_access = set()
        self.clients = set()
        self.network = set()
        self._collect_imports(tree)
        self._collect_network_instances(tree)

    def _classify(self, local_name, full_path):
        segments = module_segments(full_path)
        if DATA_ACCESS_SEGMENTS.intersection(segments) and not NON_EXECUTING_SEGMENTS.intersection(segments):
            self.data_access.add(local_name)
        if CLIENT_SEGMENTS.intersection(segments):
            self.clients.add(local_name)
        if segments and segments[0] in NETWORK_MODULES:
            self.network.add(local_name)

    def _collect_imports(self, tree):
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    # `import a.b.c` binds `a` but is called as `a.b.c.f()`, so the
                    # whole dotted path is the binding; `import a.b.c as m` binds `m`.
                    self._classify(alias.asname or alias.name, alias.name)
            elif isinstance(node, ast.ImportFrom):
                module = node.module or ""
                for alias in node.names:
                    if alias.name == "*":
                        continue
                    self._classify(alias.asname or alias.name, module + "." + alias.name)

    def _collect_network_instances(self, tree):
        """Add names bound to a network client instance (`http = httpx.AsyncClient()`)."""
        for node in ast.walk(tree):
            pairs = []
            if isinstance(node, ast.Assign):
                pairs = [(target, node.value) for target in node.targets]
            elif isinstance(node, ast.AnnAssign) and node.value is not None:
                pairs = [(node.target, node.value)]
            elif isinstance(node, (ast.With, ast.AsyncWith)):
                pairs = [(item.optional_vars, item.context_expr) for item in node.items if item.optional_vars]
            for target, value in pairs:
                if isinstance(value, ast.Await):
                    value = value.value
                if isinstance(value, ast.Call) and matches(dotted_name(value.func), self.network):
                    name = dotted_name(target)
                    if name:
                        self.network.add(name)


def matches(callee, bindings):
    """True when the dotted callee is a binding or an attribute path under one."""
    if not callee:
        return False
    return any(callee == binding or callee.startswith(binding + ".") for binding in bindings)


def describe_data_access(call, bindings):
    """Return a label for the callee when the call reaches the database, else None."""
    callee = dotted_name(call.func)
    if matches(callee, bindings.data_access):
        return callee
    if isinstance(call.func, ast.Attribute) and call.func.attr in QUERY_METHODS and call.args:
        return (dotted_name(call.func.value) or "<expression>") + "." + call.func.attr
    return None


def describe_network(call, bindings):
    """Return a label for the callee when the call is network I/O, else None."""
    callee = dotted_name(call.func)
    if not callee:
        return None
    if matches(callee, bindings.clients):
        return callee
    if matches(callee, bindings.network):
        # Constructing a client or a config object (`httpx.AsyncClient()`,
        # `httpx.Timeout(10)`) does no I/O; only its methods and functions do.
        last = callee.rsplit(".", 1)[-1]
        return None if last[:1].isupper() else callee
    return None


def with_parents(tree):
    """Record each node's parent so a call can walk outward."""
    for parent in ast.walk(tree):
        for child in ast.iter_child_nodes(parent):
            child.parent_node = parent


def is_per_element_lambda(lam):
    """True when a lambda is the element expression of a comprehension or the function of map/filter."""
    parent = getattr(lam, "parent_node", None)
    if isinstance(parent, COMPREHENSIONS):
        return lam in (getattr(parent, "elt", None), getattr(parent, "key", None), getattr(parent, "value", None))
    if isinstance(parent, ast.Call) and parent.args and parent.args[0] is lam:
        return isinstance(parent.func, ast.Name) and parent.func.id in ITERATION_BUILTINS
    return False


def describe_repetition(parent, child):
    """Name the construct when `child` is re-evaluated on each of `parent`'s iterations, else None."""
    if isinstance(parent, ast.AsyncFor):
        return "async for loop" if child in parent.body else None
    if isinstance(parent, ast.For):
        return "for loop" if child in parent.body else None
    if isinstance(parent, ast.While):
        return "while loop" if child is parent.test or child in parent.body else None
    if isinstance(parent, COMPREHENSIONS):
        per_element = (getattr(parent, "elt", None), getattr(parent, "key", None), getattr(parent, "value", None))
        return COMPREHENSION_LABELS[type(parent)] if child in per_element else None
    if isinstance(parent, ast.comprehension):
        if child in parent.ifs:
            return "comprehension filter"
        owner = getattr(parent, "parent_node", None)
        if child is parent.iter and owner is not None and owner.generators[0] is not parent:
            return "nested comprehension clause"
    return None


def find_repetition(call):
    """Walk outward from the call to the nearest construct that repeats it."""
    child = call
    parent = getattr(call, "parent_node", None)
    while parent is not None:
        repetition = describe_repetition(parent, child)
        if repetition:
            return repetition
        if isinstance(parent, ast.Lambda):
            if not is_per_element_lambda(parent):
                return None
            owner = parent.parent_node
            return "%s() callback" % owner.func.id if isinstance(owner, ast.Call) else COMPREHENSION_LABELS[type(owner)]
        if isinstance(parent, SCOPE_BOUNDARIES):
            return None
        child = parent
        parent = getattr(parent, "parent_node", None)
    return None


def check_n_plus_one(tree, bindings, report):
    """R-361: report data-access calls evaluated once per iteration."""
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        callee = describe_data_access(node, bindings)
        if not callee:
            continue
        repetition = find_repetition(node)
        if repetition:
            report(node.lineno, "R-361", "`%s(...)` runs once per iteration of this %s (N+1); %s" % (callee, repetition, N_PLUS_ONE_FIX))


def transaction_connections(item):
    """Return the names that hold the transaction's connection for one `with` item, or None if not a transaction."""
    expr = item.context_expr
    if not (isinstance(expr, ast.Call) and isinstance(expr.func, ast.Attribute) and expr.func.attr in TRANSACTION_METHODS):
        return None
    names = set()
    bound = dotted_name(item.optional_vars) if item.optional_vars is not None else None
    if bound:
        names.add(bound)
    receiver = dotted_name(expr.func.value)
    if receiver and "engine" not in receiver.rsplit(".", 1)[-1].lower():
        names.add(receiver)
    return names


def passes_connection(call, connections):
    """True when a positional (or starred) or keyword argument is one of the connection names."""
    values = [arg.value if isinstance(arg, ast.Starred) else arg for arg in call.args]
    values.extend(keyword.value for keyword in call.keywords)
    return any(dotted_name(value) in connections for value in values)


class TransactionVisitor(ast.NodeVisitor):
    """R-362: walk statements, tracking the explicit transaction blocks that enclose each call."""

    def __init__(self, bindings, report):
        self.bindings = bindings
        self.report = report
        self.stack = []

    def _visit_with(self, node):
        found = [transaction_connections(item) for item in node.items]
        found = [names for names in found if names is not None]
        for item in node.items:
            self.visit(item)
        if found:
            self.stack.append(set().union(*found))
        for statement in node.body:
            self.visit(statement)
        if found:
            self.stack.pop()

    visit_With = _visit_with
    visit_AsyncWith = _visit_with

    def _visit_scope(self, node):
        # A nested function or lambda runs whenever it is called, not
        # necessarily inside the enclosing transaction, so its body starts clean.
        saved, self.stack = self.stack, []
        self.generic_visit(node)
        self.stack = saved

    visit_FunctionDef = _visit_scope
    visit_AsyncFunctionDef = _visit_scope
    visit_Lambda = _visit_scope
    visit_ClassDef = _visit_scope

    def visit_Call(self, node):
        if self.stack:
            self._check_call(node, set().union(*self.stack))
        self.generic_visit(node)

    def _check_call(self, node, connections):
        network = describe_network(node, self.bindings)
        if network:
            self.report(
                node.lineno,
                "R-362",
                "`%s(...)` waits on the network inside a transaction, holding its locks and connection for the round trip; "
                "call it before the transaction opens or after it commits, or write an outbox row." % network,
            )
            return
        callee = describe_data_access(node, self.bindings)
        if not callee or not connections:
            return
        receiver = dotted_name(node.func.value) if isinstance(node.func, ast.Attribute) else None
        is_query_method = isinstance(node.func, ast.Attribute) and node.func.attr in QUERY_METHODS
        if is_query_method and not matches(callee, self.bindings.data_access):
            if receiver is None or receiver in connections:
                return
        elif passes_connection(node, connections):
            return
        expected = " or ".join("`%s`" % name for name in sorted(connections))
        self.report(
            node.lineno,
            "R-362",
            "`%s(...)` inside this transaction does not run on its connection (%s), so it uses another connection "
            "outside the transaction (no rollback, cannot see its writes); pass the connection through." % (callee, expected),
        )


def is_allowed(lines, line):
    """True when the line or the one above it carries `# data-access-allow: <reason>`."""
    for number in (line, line - 1):
        if 1 <= number <= len(lines) and ALLOW_COMMENT.search(lines[number - 1]):
            return True
    return False


def check_file(path):
    """Return the findings for one file, or [] when it is exempt, unreadable, or unparsable."""
    if is_exempt(path):
        return []
    try:
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        tree = ast.parse(source, filename=path)
    except (OSError, UnicodeDecodeError, SyntaxError, ValueError):
        return []
    lines = source.splitlines()
    with_parents(tree)
    bindings = Bindings(tree)
    findings = []

    def report(line, rule, message):
        if not is_allowed(lines, line):
            findings.append({"file": path, "line": line, "rule": rule, "message": message})

    check_n_plus_one(tree, bindings, report)
    TransactionVisitor(bindings, report).visit(tree)
    return findings


def main(argv):
    """Check every file named on the command line and print the findings as JSON."""
    if not argv or any(arg in ("-h", "--help") for arg in argv):
        sys.stderr.write("usage: python3 python_data_access.py <file>...\n")
        return USAGE_EXIT
    findings = []
    for path in argv:
        findings.extend(check_file(path))
    findings.sort(key=lambda finding: (finding["file"], finding["line"], finding["rule"]))
    sys.stdout.write(json.dumps(findings) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
