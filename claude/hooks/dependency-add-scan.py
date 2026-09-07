#!/usr/bin/env python3
"""Companion to dependency-add-guard.sh (R-331): reads the PreToolUse payload
on stdin and the manifest path as argv[1], and prints the dependency names the
write would add, space-separated, or nothing. Parsing rules per manifest are in
the hook's header. Any parse failure exits 0 with no output (fail open)."""
import json, os, re, sys

path = sys.argv[1]
payload = json.load(sys.stdin)
tool_input = payload.get("tool_input", {})
kind = os.path.basename(path)

try:
    before = open(path, encoding="utf-8").read()
except OSError:
    before = ""

if payload.get("tool_name") == "Write":
    after = tool_input.get("content", "")
else:
    old, new = tool_input.get("old_string", ""), tool_input.get("new_string", "")
    if old == "" or old not in before:
        sys.exit(0)
    after = before.replace(old, new) if tool_input.get("replace_all") else before.replace(old, new, 1)

PEP508_NAME = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)")
GO_REQUIRE = re.compile(r"^\s*(?:require\s+)?([A-Za-z0-9][\w./~-]*)\s+v[\w.+-]+(.*)$")
GEM_LINE = re.compile(r"""^\s*gem\s+['"]([^'"]+)['"]""")


def package_json_names(text):
    data = json.loads(text)
    names = set()
    for field in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        section = data.get(field)
        if isinstance(section, dict):
            names.update(section.keys())
    return names


def pyproject_names(text):
    import tomllib
    data = tomllib.loads(text)
    names = set()

    def add_specs(specs):
        for spec in specs or []:
            match = PEP508_NAME.match(spec) if isinstance(spec, str) else None
            if match:
                names.add(match.group(1).lower())

    project = data.get("project", {})
    add_specs(project.get("dependencies"))
    for specs in (project.get("optional-dependencies") or {}).values():
        add_specs(specs)
    for specs in (data.get("dependency-groups") or {}).values():
        add_specs([entry for entry in specs if isinstance(entry, str)])
    poetry = (data.get("tool") or {}).get("poetry") or {}
    for key in (poetry.get("dependencies") or {}):
        if key.lower() != "python":
            names.add(key.lower())
    for group in (poetry.get("group") or {}).values():
        for key in (group.get("dependencies") or {}):
            names.add(key.lower())
    return names


def go_mod_names(text):
    names = set()
    in_block = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("require ("):
            in_block = True
            continue
        if in_block and stripped == ")":
            in_block = False
            continue
        if not (in_block or stripped.startswith("require ")):
            continue
        match = GO_REQUIRE.match(line if in_block else stripped)
        if match and "// indirect" not in match.group(2):
            names.add(match.group(1))
    return names


def gemfile_names(text):
    return {match.group(1) for line in text.splitlines() for match in [GEM_LINE.match(line)] if match}


PARSERS = {"package.json": package_json_names, "pyproject.toml": pyproject_names, "go.mod": go_mod_names, "Gemfile": gemfile_names}
parse = PARSERS[kind]
try:
    after_names = parse(after)
except Exception:
    sys.exit(0)
try:
    before_names = parse(before) if before.strip() else set()
except Exception:
    before_names = set()

added = sorted(after_names - before_names)
if added:
    print(" ".join(added))
