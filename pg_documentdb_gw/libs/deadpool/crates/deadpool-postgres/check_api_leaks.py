#!/usr/bin/env python3

import json
import sys
from pathlib import Path

CRATE_NAME = "deadpool"  # Change if needed
DEBUG = True


def debug_log(msg):
    if DEBUG:
        print(f"DEBUG: {msg}", file=sys.stderr)


def load_rustdoc_json(path):
    with open(path) as f:
        return json.load(f)


def collect_exports(index):
    """Return all re-exported paths from the current crate"""
    exported = set()
    for item in index.values():
        if item.get("visibility") != "public":
            continue
        inner = item.get("inner", {})
        if "extern_crate" in inner:
            continue  # skip extern crate entries
        name = item.get("name")
        if not name:
            continue
        # Only count top-level re-exports from deadpool
        if "resolved_path" in str(inner):
            path = str(inner)
            if f"{CRATE_NAME}::" in path:
                exported.add(name)
    return exported


def walk_type(ty, leaked, index=None, visited_ids=None, crate_name="deadpool"):
    if not ty or not isinstance(ty, dict):
        return

    if visited_ids is None:
        visited_ids = set()

    if "resolved_path" in ty:
        path = ty["resolved_path"].get("path", "")
        type_id = ty["resolved_path"].get("id")

        if path.startswith(f"{crate_name}::"):
            leaked.add(path)
            debug_log(f" -> Leaked path: {path}")

        if type_id is not None and index and str(type_id) not in visited_ids:
            visited_ids.add(str(type_id))
            target = index.get(str(type_id))
            if target:
                walk_definition(target, leaked, index, visited_ids, crate_name)

        args = ty["resolved_path"].get("args")
        if args and "angle_bracketed" in args:
            for arg in args["angle_bracketed"].get("args", []):
                walk_type(arg.get("type"), leaked, index, visited_ids)

    elif "tuple" in ty:
        for subty in ty["tuple"]:
            walk_type(subty, leaked, index, visited_ids)

    elif "slice" in ty:
        walk_type(ty["slice"], leaked, index, visited_ids)

    elif "array" in ty:
        walk_type(ty["array"]["type"], leaked, index, visited_ids)

    elif "pointer" in ty:
        walk_type(ty["pointer"]["type"], leaked, index, visited_ids)

    elif "borrowed_ref" in ty:
        walk_type(ty["borrowed_ref"]["type"], leaked, index, visited_ids)

    elif "qualified_path" in ty:
        walk_type(ty["qualified_path"]["type"], leaked, index, visited_ids)


def walk_definition(item, leaked, index, visited_ids, crate_name):
    inner = item.get("inner", {})
    kind = inner.get("kind") or next(iter(inner), None)

    if kind == "type_alias":
        ty = inner.get("type_alias", {}).get("type")
        walk_type(ty, leaked, index, visited_ids, crate_name)

    elif kind == "enum":
        for variant_id in inner.get("variants", []):
            variant = index.get(str(variant_id))
            if not variant:
                continue
            kind_info = variant.get("inner", {}).get("variant_kind", {})
            if "tuple" in kind_info:
                for ty in kind_info["tuple"]:
                    walk_type(ty, leaked, index, visited_ids, crate_name)
            elif "struct" in kind_info:
                for field_id in kind_info["struct"].get("fields", []):
                    field = index.get(str(field_id))
                    if field:
                        walk_type(field.get("inner"), leaked, index, visited_ids, crate_name)


def collect_leaks(public_api, index, crate_name):
    leaked = set()
    for item in public_api:
        if item.get("visibility") != "public":
            continue
        name = item.get("name")
        debug_log(f"Analyzing item: {name}")
        walk_definition(item, leaked, index, visited_ids=set(), crate_name=crate_name)
    return leaked


def main():
    if len(sys.argv) != 2:
        print("Usage: check_deadpool_leaks.py rustdoc.json", file=sys.stderr)
        sys.exit(1)

    path = Path(sys.argv[1])
    rustdoc = load_rustdoc_json(path)

    index = rustdoc["index"]
    public_api = [item for item in index.values() if item.get("visibility") == "public"]

    exported = collect_exports(index)
    leaked = collect_leaks(public_api, index, crate_name=CRATE_NAME)

    unresolved = {ty for ty in leaked if ty.split("::")[-1] not in exported}

    if unresolved:
        print("❌ Public API uses types from `deadpool` that are NOT re-exported:")
        for ty in sorted(unresolved):
            print(f" - {ty}")
        sys.exit(1)
    else:
        print("✅ No un-reexported `deadpool` types found in public API.")


if __name__ == "__main__":
    main()
