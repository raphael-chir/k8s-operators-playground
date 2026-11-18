"""Static validation of a draft use case. Nothing here executes a generated script.

validate_draft(draft, name) checks the files of one draft; snapshot()/diff_snapshots() prove that the AI agent
touched nothing outside it. Standard library only (PyYAML is used for manifests when it happens to be installed).
"""
import hashlib
import os
import re
import subprocess
from pathlib import Path

SERVICE_KEYS = ("cert_manager", "minio", "prometheus", "grafana")
NAME_RE = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")
SCENARIO_RE = re.compile(r"^([0-9]{2})_[a-z0-9][a-z0-9_]*\.sh$")
MANIFEST_REF_RE = re.compile(r"manifests/([A-Za-z0-9_./-]+\.ya?ml)")
TOP_FILES = {"usecase.yaml", "README.md"}
MAX_FILES, MAX_BYTES = 60, 256 * 1024
SNAPSHOT_SKIP_DIRS = {".git", ".ai-builder", "__pycache__", "node_modules"}
SNAPSHOT_SKIP_FILES = {".DS_Store"}


# --- usecase.yaml: the small YAML subset the engine reads (two levels, scalars) --------------------------------
def parse_usecase_yaml(text):
    """Return (dict, errors). Same subset as engine/infrastructure/kind/common.sh: `key: value` and one nested level."""
    data, errors, section = {}, [], None
    for n, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if "\t" in raw:
            errors.append(f"usecase.yaml line {n}: tabs are not allowed")
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*?))?\s*$", raw.strip())
        if not m or indent not in (0, 2):
            errors.append(f"usecase.yaml line {n}: not a valid 'key: value' line at indent 0 or 2")
            continue
        key, value = m.group(1), m.group(2)
        if indent == 0:
            if key in data:
                errors.append(f"usecase.yaml line {n}: duplicate key '{key}'")
            if value is None or value == "":
                data[key] = {}
                section = key
            else:
                data[key] = value.strip().strip("\"'")
                section = None
        else:
            if section is None:
                errors.append(f"usecase.yaml line {n}: indented key '{key}' without a parent section")
            elif key in data[section]:
                errors.append(f"usecase.yaml line {n}: duplicate key '{section}.{key}'")
            else:
                data[section][key] = (value or "").strip().strip("\"'")
    return data, errors


def check_usecase_yaml(text):
    data, errors = parse_usecase_yaml(text)
    if errors:
        return errors
    for key in ("title", "description"):
        if not isinstance(data.get(key), str) or not data[key]:
            errors.append(f"usecase.yaml: '{key}' is missing")
    infra = data.get("infrastructure")
    if not isinstance(infra, dict):
        errors.append("usecase.yaml: 'infrastructure' section is missing")
    else:
        for key in ("clusters", "workers_per_cluster"):
            if not re.fullmatch(r"[1-9][0-9]*", infra.get(key, "")):
                errors.append(f"usecase.yaml: 'infrastructure.{key}' must be a positive integer")
    services = data.get("services", {})
    if not isinstance(services, dict):
        errors.append("usecase.yaml: 'services' must be a section")
    else:
        for key, value in services.items():
            if key not in SERVICE_KEYS:
                errors.append(f"usecase.yaml: unknown service '{key}' (expected: {' '.join(SERVICE_KEYS)})")
            elif value not in ("true", "false"):
                errors.append(f"usecase.yaml: 'services.{key}' must be true or false")
    return errors


# --- manifests ------------------------------------------------------------------------------------------------------
def check_manifest(path, rel):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return [f"{rel}: unreadable ({exc.__class__.__name__})"]
    if not text.strip():
        return [f"{rel}: empty"]
    try:
        import yaml  # optional
    except ImportError:
        yaml = None
    if yaml is not None:
        try:
            docs = [d for d in yaml.safe_load_all(text) if d is not None]
        except yaml.YAMLError as exc:
            return [f"{rel}: invalid YAML ({str(exc).splitlines()[0]})"]
        bad = [d for d in docs if not (isinstance(d, dict) and "apiVersion" in d and "kind" in d)]
        return [f"{rel}: every document needs apiVersion and kind"] if bad or not docs else []
    # Fallback without PyYAML: structural checks only (tabs, and apiVersion/kind per document).
    errors = []
    if re.search(r"^\t|^ *\t", text, re.M):
        errors.append(f"{rel}: tab characters in indentation")
    for i, doc in enumerate(re.split(r"^---\s*$", text, flags=re.M), 1):
        if doc.strip() and not (re.search(r"^apiVersion:", doc, re.M) and re.search(r"^kind:", doc, re.M)):
            errors.append(f"{rel}: document {i} lacks a top-level apiVersion or kind")
    return errors


# --- scenarios --------------------------------------------------------------------------------------------------------
def check_scenario(path, rel, text):
    errors = []
    if not text.startswith("#!/usr/bin/env bash"):
        errors.append(f"{rel}: first line must be '#!/usr/bin/env bash'")
    if "set -Eeuo pipefail" not in text:
        errors.append(f"{rel}: missing 'set -Eeuo pipefail'")
    for lib in ("engine/lib/ui.sh", "engine/usecase.sh"):
        if not re.search(r"^\s*source\s+\"\$\{SCRIPT_DIR\}/\.\./\.\./" + re.escape(lib) + r"\"", text, re.M):
            errors.append(f"{rel}: must source \"${{SCRIPT_DIR}}/../../{lib}\" (SCRIPT_DIR is the script's directory)")
    if not re.search(r"^SCRIPT_DIR=", text, re.M):
        errors.append(f"{rel}: SCRIPT_DIR is not defined")
    if not re.search(r"^main\s+\"\$@\"\s*$", text, re.M):
        errors.append(f"{rel}: must end by calling main \"$@\"")
    if not path.name.startswith("99_"):
        for fn in ("ui_note", "ui_command", "ui_pause"):
            if fn not in text:
                errors.append(f"{rel}: a scenario must use {fn}")
    return errors


def bash_syntax(path, rel):
    """bash -n only parses; it never runs the script."""
    try:
        r = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [f"{rel}: bash -n could not run ({exc.__class__.__name__})"]
    return [f"{rel}: bash -n: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'syntax error'}"] if r.returncode else []


# --- the draft as a whole -----------------------------------------------------------------------------------------------
def validate_draft(draft, name):
    """Return a list of error strings (empty = valid). `draft` is the directory that will become usecases/<name>/."""
    errors = []
    draft = Path(draft)
    if not NAME_RE.match(name or ""):
        return [f"invalid use case name '{name}'"]
    if not draft.is_dir() or draft.is_symlink():
        return [f"draft directory missing: {draft.name}"]
    root = draft.resolve()
    files = []
    for dirpath, dirnames, filenames in os.walk(draft, followlinks=False):
        for entry in list(dirnames) + filenames:
            p = Path(dirpath) / entry
            if p.is_symlink():
                errors.append(f"{p.relative_to(draft)}: symbolic links are not allowed")
        for fn in filenames:
            p = Path(dirpath) / fn
            if not p.is_symlink():
                files.append(p)
    for p in files:
        rel = str(p.relative_to(draft))
        try:
            p.resolve().relative_to(root)
        except ValueError:
            errors.append(f"{rel}: resolves outside the draft")
    if len(files) > MAX_FILES:
        errors.append(f"too many files ({len(files)} > {MAX_FILES})")
    for p in files:
        if p.stat().st_size > MAX_BYTES:
            errors.append(f"{p.relative_to(draft)}: larger than {MAX_BYTES // 1024} KB")

    # layout: usecase.yaml, README.md, NN_*.sh at the root; manifests/*.yaml below
    scenarios, manifests = [], {}
    for p in files:
        parts = p.relative_to(draft).parts
        rel = "/".join(parts)
        if len(parts) == 1:
            if parts[0] in TOP_FILES:
                continue
            if parts[0].endswith(".sh"):
                scenarios.append(p)
            else:
                errors.append(f"{rel}: unexpected file at the use case root (allowed: usecase.yaml, README.md, NN_name.sh, manifests/)")
        elif parts[0] == "manifests" and len(parts) == 2 and re.fullmatch(r"[A-Za-z0-9_.-]+\.ya?ml", parts[1]):
            manifests[parts[1]] = p
        else:
            errors.append(f"{rel}: unexpected path (manifests/ holds *.yaml files only, no subdirectories)")

    # 1-2 usecase.yaml
    uc = draft / "usecase.yaml"
    if not uc.is_file():
        errors.append("usecase.yaml is missing")
    else:
        try:
            errors += check_usecase_yaml(uc.read_text(encoding="utf-8"))
        except UnicodeDecodeError:
            errors.append("usecase.yaml: not valid UTF-8")
    if not (draft / "README.md").is_file():
        errors.append("README.md is missing")

    # 3-5 scenarios: names, numbering, bash syntax, structure
    numbers = {}
    for p in sorted(scenarios):
        m = SCENARIO_RE.match(p.name)
        if not m:
            errors.append(f"{p.name}: scenario names look like NN_short_name.sh (two digits, lowercase letters, digits, underscores)")
            continue
        numbers.setdefault(m.group(1), []).append(p.name)
    for nn, names in numbers.items():
        if len(names) > 1:
            errors.append(f"scenario number {nn} is used by several files: {', '.join(sorted(names))}")
    ordered = sorted(int(n) for n in numbers if n != "99")
    if not ordered:
        errors.append("no scenario found (expected at least 01_*.sh)")
    elif ordered != list(range(1, len(ordered) + 1)):
        errors.append("scenario numbers must run 01, 02, 03... without gaps (99_*.sh is reserved for cleanup)")
    referenced = set()
    for p in sorted(scenarios):
        rel = p.name
        errors += bash_syntax(p, rel)
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            errors.append(f"{rel}: not valid UTF-8")
            continue
        errors += check_scenario(p, rel, text)
        referenced.update(MANIFEST_REF_RE.findall(text))   # 6. referenced manifests exist
    for ref in sorted(referenced):
        if "/" in ref or ref not in manifests:
            errors.append(f"a scenario references manifests/{ref}, which does not exist in the draft")
    for fname, p in sorted(manifests.items()):
        errors += check_manifest(p, f"manifests/{fname}")
    return errors


# --- "nothing else changed" -----------------------------------------------------------------------------------------------
def snapshot(repo):
    """Map relative path -> (size, sha256) of every repository file, except Git data, caches and the AI Builder state."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(repo, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in SNAPSHOT_SKIP_DIRS]
        for fn in filenames:
            if fn in SNAPSHOT_SKIP_FILES:
                continue
            p = Path(dirpath) / fn
            rel = str(p.relative_to(repo))
            try:
                if p.is_symlink():
                    out[rel] = ("link", os.readlink(p))
                else:
                    out[rel] = (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest())
            except OSError:
                out[rel] = ("unreadable", "")
    return out


def diff_snapshots(before, after):
    errors = []
    for rel in sorted(set(before) | set(after)):
        if rel not in before:
            errors.append(f"file created outside the draft: {rel}")
        elif rel not in after:
            errors.append(f"existing repository file deleted: {rel}")
        elif before[rel] != after[rel]:
            errors.append(f"existing repository file modified: {rel}")
    return errors
