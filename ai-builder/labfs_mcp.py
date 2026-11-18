#!/usr/bin/env python3
"""Minimal MCP server (stdio, standard library) giving Claude ONE narrow capability: delete a single file in an approved working copy.

    python3 labfs_mcp.py --lab <lab>=<working-copy-directory> [--lab ...]

It is started by Claude Code for an EDITING turn only, with the working copies the user approved for that message (the one-shot approval):
a read-only turn has no such server, so there is no tool to call. The tool takes a Lab name (one of the listed ones) and a relative file
path; every check lives in workspace.delete_file (no absolute path, no '..', no symlinks, no directories, never usecase.yaml).
No shell, no generic filesystem access, nothing is read or written besides that deletion."""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import workspace as wsmod  # noqa: E402

LAB_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
TOOL = "delete_file"
SCHEMA = {"type": "object", "additionalProperties": False, "required": ["path"], "properties": {
    "lab": {"type": "string", "description": "The Lab whose working copy holds the file (needed when several Labs are approved)."},
    "path": {"type": "string", "description": "Relative path of ONE file inside the Lab, e.g. 03_replication.sh or manifests/keeper.yaml."}}}
DESCRIPTION = ("Delete ONE file of an approved Lab working copy. Use it to remove a scenario, a manifest or another file; never empty a file instead. "
               "Directories, symbolic links, absolute paths and the root usecase.yaml are refused.")


def parse_labs(argv):
    labs = {}
    i = 0
    while i < len(argv):
        if argv[i] == "--lab" and i + 1 < len(argv) and "=" in argv[i + 1]:
            name, path = argv[i + 1].split("=", 1)
            if LAB_RE.match(name) and os.path.isabs(path):
                labs[name] = path
            i += 2
        else:
            i += 1
    return labs


def call(labs, args):
    """Run the tool. Returns (text, is_error)."""
    if not isinstance(args, dict):
        return "arguments: an object with path (and lab)", True
    lab = args.get("lab")
    if lab is None and len(labs) == 1:
        lab = next(iter(labs))
    if not isinstance(lab, str) or lab not in labs:
        return f"lab: one of {', '.join(sorted(labs))}", True
    try:
        wsmod.delete_file(labs[lab], args.get("path"))
    except wsmod.WorkspaceError as exc:
        return f"not deleted: {exc}", True
    return f"deleted {args['path']} from the working copy of {lab}", False


def handle(labs, msg):
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": (msg.get("params") or {}).get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}}, "serverInfo": {"name": "labfs", "version": "1"}}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": TOOL, "description": DESCRIPTION, "inputSchema": SCHEMA}]}}
    if method == "tools/call":
        params = msg.get("params") or {}
        if params.get("name") != TOOL:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool"}}
        text, bad = call(labs, params.get("arguments"))
        return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}], "isError": bad}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    return None if mid is None else {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}}


def main():
    labs = parse_labs(sys.argv[1:])
    for line in sys.stdin:
        try:
            msg = json.loads(line)
            reply = handle(labs, msg) if isinstance(msg, dict) else None
        except ValueError:
            continue
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
