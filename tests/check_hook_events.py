#!/usr/bin/env python3
"""Fails unless the events registered in a plugin hooks.json equal the events
the hook script dispatches.

Usage: check_hook_events.py <hooks.json> <hook.py>

Dispatched events are read statically (AST) from every comparison against a
variable named `event` (`event == "X"`, `event in ("X", "Y")`), so an event
handled in code but missing from hooks.json (or registered but never handled)
is caught without running the hook.
"""
import ast
import json
import sys


def registered_events(hooks_json_path: str) -> set:
    with open(hooks_json_path) as f:
        doc = json.load(f)
    hooks = doc.get("hooks", doc)
    return {event for event, blocks in hooks.items() if blocks}


def _string_constants(node) -> set:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return {node.value}
    if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
        out = set()
        for elt in node.elts:
            out |= _string_constants(elt)
        return out
    return set()


def dispatched_events(hook_path: str) -> set:
    with open(hook_path) as f:
        tree = ast.parse(f.read(), filename=hook_path)
    events = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Compare):
            continue
        if not (isinstance(node.left, ast.Name) and node.left.id == "event"):
            continue
        for op, comparator in zip(node.ops, node.comparators):
            if isinstance(op, (ast.Eq, ast.In)):
                events |= _string_constants(comparator)
    return events


def main(argv) -> int:
    if len(argv) != 3:
        print("usage: check_hook_events.py <hooks.json> <hook.py>")
        return 2
    registered = registered_events(argv[1])
    dispatched = dispatched_events(argv[2])
    if registered == dispatched and registered:
        print(f"OK {len(registered)} == {len(dispatched)}")
        return 0
    print(f"MISMATCH {len(registered)} registered != {len(dispatched)} dispatched")
    for name in sorted(registered - dispatched):
        print(f"  registered but not dispatched: {name}")
    for name in sorted(dispatched - registered):
        print(f"  dispatched but not registered: {name}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
