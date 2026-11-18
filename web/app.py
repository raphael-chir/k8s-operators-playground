"""Serves the playground Web UI. The terminal is the existing ttyd, embedded as an iframe.
API (all under /api): use case discovery and start/stop (delegated to engine/usecase-list.sh and the existing
`./playground usecase start|stop`, so no naming logic here), the persistent terminal sessions (engine/terminal.sh),
a read-only status of the selected terminal (context, clusters, Grafana/MinIO links) and read-only Docker resource
monitoring. See docs/architecture.md."""
import os
import json
import re
import socket
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Body, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.concurrency import run_in_threadpool

import ai_builder_proxy
import lab_delete

ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = Path(tempfile.gettempdir()) / "playground-operations"
LOG_DIR.mkdir(exist_ok=True)
MAX_LOG_CHUNK = 256 * 1024

app = FastAPI(title="CNPG Operator Playground", docs_url=None, redoc_url=None, openapi_url=None)

# In-memory registry: the latest operation of each use case. One active operation per use case.
# A use case owns its clusters exclusively (<prefix>-<usecase>-<n>), so this also serializes
# everything that touches those clusters.
_ops: dict = {}
_lock = threading.Lock()
_gate = lab_delete.DeleteGate(_lock, _ops, lambda: _discover())     # whole-Lab deletion: infrastructure verdict and start/delete coordination


def _discover():
    """[(name, clusters)] from engine/usecase-list.sh; raises HTTPException 503 if it cannot tell."""
    try:
        out = subprocess.run(["bash", str(ROOT / "engine/usecase-list.sh")],
                             capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        raise HTTPException(503, "use case discovery timed out")
    if out.returncode != 0:
        raise HTTPException(503, out.stderr.strip() or "use case discovery failed")
    return [(n, int(c)) for n, c in (line.split("\t") for line in out.stdout.splitlines())]


def _public(op):
    if not op:
        return None
    body = {k: op[k] for k in ("kind", "state", "exit_code", "started", "finished")}
    # Durations are computed here, on the server clock that stamped `started`, so the page needs no clock
    # agreement with the container (and a refreshed page resumes the same timer).
    now = time.time()
    body["started_at"] = datetime.fromtimestamp(op["started"], timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body["elapsed"] = round((op["finished"] or now) - op["started"], 1)
    body["since_finished"] = round(now - op["finished"], 1) if op["finished"] else None
    return body


@app.exception_handler(HTTPException)
def _http_error(_, exc):
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


@app.get("/api/meta")
def meta():
    """Playground metadata. The version is read from the VERSION file (single source of truth)."""
    try:
        version = (ROOT / "VERSION").read_text().strip() or "unknown"
    except OSError:
        version = "unknown"
    return {"version": version}


def _use_case_meta():
    """{name: (title, description)} from each usecases/<name>/usecase.yaml, read by engine/usecase-list.sh --meta."""
    out = subprocess.run(["bash", str(ROOT / "engine/usecase-list.sh"), "--meta"],
                         capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise HTTPException(503, out.stderr.strip() or "use case discovery failed")
    return {n: (t, d) for n, t, d in (line.split("\t", 2) for line in out.stdout.splitlines())}


@app.get("/api/usecases")
def usecases():
    items = []
    meta = _use_case_meta()
    for name, count in _discover():
        title, description = meta.get(name, (name, ""))
        items.append({"name": name, "title": title, "description": description,
                      "status": "running" if count > 0 else "stopped", "clusters": count,
                      "operation": _public(_ops.get(name))})
    return {"usecases": items}


def _watch(name, op, proc):
    rc = proc.wait()
    op["log_file"].close()
    with _lock:
        op["exit_code"] = rc
        op["state"] = "succeeded" if rc == 0 else "failed"
        op["finished"] = time.time()


def _launch(name, kind, extra, confirmed=True):
    if not confirmed:
        raise HTTPException(400, "confirmation required")
    if name not in dict(_discover()):    # same validity rules as the CLI / use case list
        raise HTTPException(404, f"unknown use case '{name}'")
    target = "start" if kind == "start" else "stop"
    with _lock:
        current = _ops.get(name)
        if _gate.deleting(name):
            raise HTTPException(409, f"{name} is being deleted")
        if current and current["state"] in ("starting", "stopping"):
            raise HTTPException(409, f"{name} already has an operation in progress ({current['state']})")
        log_file = open(LOG_DIR / f"{name}.log", "wb")
        # argv list, no shell: the name was validated above and is a single argument.
        proc = subprocess.Popen([str(ROOT / "playground"), "usecase", target, name, *extra], cwd=ROOT,
                                env={**os.environ, "PLAYGROUND_FORCE_COLOR": "1"},   # keep logger colors in the log
                                stdin=subprocess.DEVNULL, stdout=log_file, stderr=subprocess.STDOUT,
                                start_new_session=True)
        op = {"kind": kind, "state": "starting" if kind == "start" else "stopping", "exit_code": None,
              "started": time.time(), "finished": None, "log_file": log_file, "log_path": log_file.name}
        _ops[name] = op
    threading.Thread(target=_watch, args=(name, op, proc), daemon=True).start()
    return JSONResponse(_public(op), status_code=202)


@app.post("/api/usecases/{name}/start")
def start(name: str):
    return _launch(name, "start", [])


@app.post("/api/usecases/{name}/stop")
def stop(name: str, body: dict = Body(default={})):
    # --force skips the terminal prompt of `usecase stop`: the UI dialog has asked, and `confirm` proves it.
    return _launch(name, "stop", ["--force"], confirmed=body.get("confirm") is True)


@app.get("/api/usecases/{name}/operation")
def operation(name: str, offset: int = 0):
    op = _ops.get(name)
    if not op:
        return {"state": "idle"}
    data = Path(op["log_path"]).read_bytes()[max(offset, 0):][:MAX_LOG_CHUNK]
    if op["state"] in ("starting", "stopping") and b"\n" in data:
        data = data[:data.rindex(b"\n") + 1]      # never cut a line (or a UTF-8 character) in the middle
    elif op["state"] in ("starting", "stopping"):
        data = b""
    return {**_public(op), "log": data.decode(errors="replace"), "offset": max(offset, 0) + len(data)}


# --- Terminals: one tab = one ttyd connection = one Bash process (engine/terminal.sh, SPEC-007.1.7). The backend
# only lists the tabs; it never starts, inspects or stops a shell, and the browser never sends a command.
SESSION_PREFIX = "playground-"


def _use_case_names():
    out = subprocess.run(["bash", str(ROOT / "engine/usecase-list.sh"), "--names"],
                         capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise HTTPException(503, out.stderr.strip() or "use case discovery failed")
    return out.stdout.split()


@app.get("/api/terminals")
def terminals():
    tabs = [{"id": "main", "title": "Playground", "usecase": None}]
    meta = _use_case_meta()
    tabs += [{"id": f"uc-{n}", "title": meta[n][0], "usecase": n} for n in _use_case_names() if n in meta]
    return {"terminals": tabs}


# --- Status bar: read-only. The context shown is what the terminal's own kubeconfig file says (the file the
# shell's kubectl and helm write to, see engine/shell/bashrc), never an inference from the use case name.
# Nothing is executed in a terminal here.
_CONTEXT_FILE_RE = re.compile(r"""^current-context:[ \t]*(?:"([^"]*)"|'([^']*)'|(\S+))[ \t]*$""", re.M)


def _current_context(text):
    """The `current-context` of kubeconfig text, or None. kubectl writes `current-context: ""` when it is unset,
    and then resolves the next file in KUBECONFIG, so an empty value must count as unset here too."""
    match = _CONTEXT_FILE_RE.search(text)
    return (next(g for g in match.groups() if g is not None) or None) if match else None
_STATUS_TTL = 5
GRAFANA_NODE_PORT, MINIO_CONSOLE_NODE_PORT = 30082, 30084     # fixed NodePorts, same as engine/usecase-clusters.sh
_clusters_cache: dict = {}            # use case -> (time, (rows, error))
_contexts_cache = {"mtime": None, "names": set(), "current": None}


def _kubeconfig_contexts():
    """(names of the shared kubeconfig's contexts, its current-context or None), re-read only when it changes."""
    path = Path.home() / ".kube/config"
    try:
        mtime = path.stat().st_mtime_ns
    except OSError:
        return set(), None
    if _contexts_cache["mtime"] != mtime:
        env = {k: v for k, v in os.environ.items() if k != "KUBECONFIG"}
        names = subprocess.run(["kubectl", "config", "get-contexts", "-o", "name"], capture_output=True,
                               text=True, timeout=10, env=env)
        _contexts_cache.update(mtime=mtime, names=set(names.stdout.split()) if names.returncode == 0 else set(),
                               current=_current_context(path.read_text()))
    return _contexts_cache["names"], _contexts_cache["current"]


def _terminal_context(session):
    """(context, state): state is no-session | none | unavailable | ok.
    The effective context, as kubectl resolves it: the terminal's own file first, then (when that file has none)
    the shared kubeconfig's current-context. A context that does not exist is `none` for the Playground terminal
    (it must not depend on a cluster) and `unavailable` for a use case terminal, whose cluster is expected."""
    try:
        own = _current_context((Path.home() / ".kube/terminals" / f"{session}.yaml").read_text())
    except OSError:
        return None, "no-session"            # the terminal was never opened: its file does not exist yet
    names, shared_current = _kubeconfig_contexts()
    context = own or shared_current
    if not context:
        return None, "none"
    if context in names:
        return context, "ok"
    return (None, "none") if session == SESSION_PREFIX + "main" else (context, "unavailable")


def _service_up(host, port):
    """True if something accepts connections on the node port (a Service exists and is exposed)."""
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def _usecase_clusters(name):
    """([(cluster, grafana_port, console_port, grafana_up, console_up)], error), cached a few seconds."""
    cached = _clusters_cache.get(name)
    if cached and time.time() - cached[0] < _STATUS_TTL:
        return cached[1]
    try:
        out = subprocess.run(["bash", str(ROOT / "engine/usecase-clusters.sh"), name],
                             capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip() or "cluster discovery failed")
        rows = []
        for line in out.stdout.splitlines():
            cluster, g, m = (line.split("\t") + ["", ""])[:3]
            host = f"{cluster}-control-plane"
            rows.append((cluster, g, m, bool(g) and _service_up(host, GRAFANA_NODE_PORT),
                         bool(m) and _service_up(host, MINIO_CONSOLE_NODE_PORT)))
        result = (rows, None)
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        result = ([], str(exc) or "cluster discovery timed out")
    _clusters_cache[name] = (time.time(), result)
    return result


@app.get("/api/status")
def status(request: Request, terminal: str = "main"):
    if terminal == "main":
        usecase = None
    elif terminal.startswith("uc-") and terminal[3:] in _use_case_names():
        usecase = terminal[3:]
    else:
        raise HTTPException(404, f"unknown terminal '{terminal}'")
    context, context_state = _terminal_context(SESSION_PREFIX + terminal)
    body = {"terminal": terminal, "usecase": usecase, "status": None, "session_exists": context_state != "no-session",
            "context": context, "context_state": context_state, "clusters": [], "error": None}
    if usecase:
        # Links use the hostname the browser used for this page; the ports are published on the host's 127.0.0.1.
        host = request.url.hostname or "127.0.0.1"
        host = f"[{host}]" if ":" in host else host
        rows, error = _usecase_clusters(usecase)
        for cluster, g, m, g_up, m_up in rows:
            body["clusters"].append({
                "name": cluster, "context": f"kind-{cluster}",
                "grafana_url": f"http://{host}:{g}" if g_up else None,
                "minio_console_url": f"http://{host}:{m}" if m_up else None})
        op = _ops.get(usecase)
        body["error"] = error
        body["status"] = (op["state"] if op and op["state"] in ("starting", "stopping")
                          else "unknown" if error else "running" if rows else "stopped")
    return body

# --- Docker resource monitor: read-only. One background collector (started by the first request, stopped
# when nobody has asked for 30 s) refreshes a cached snapshot every 5 s, so `docker stats` (slow) never runs
# per HTTP request and never twice at once. A failed collection keeps the last good snapshot, marked stale.
# Playground workloads = node containers of Kind clusters named by the playground convention (managed_clusters),
# identified by Kind's own container label. Other containers only count in the engine-wide numbers.
KIND_LABEL = "io.x-k8s.kind.cluster"
_RES_INTERVAL, _RES_IDLE_STOP = 5, 30
_UNITS = {"b": 1, "kb": 1000, "mb": 1000**2, "gb": 1000**3, "tb": 1000**4,
          "kib": 1024, "mib": 1024**2, "gib": 1024**3, "tib": 1024**4}
_res = {"snapshot": None, "error": None, "last_request": 0.0, "thread": None, "first": threading.Event()}
_res_lock = threading.Lock()


def _docker(*args, timeout=15):
    out = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"docker {args[0]} failed")
    return out.stdout


def _bytes(text):
    """'3.332GiB' -> bytes (docker stats uses both SI and IEC units)."""
    m = re.fullmatch(r"([0-9.]+)\s*([A-Za-z]+)", text.strip())
    if not m or m.group(2).lower() not in _UNITS:
        raise ValueError(f"unexpected memory value '{text}'")
    return int(float(m.group(1)) * _UNITS[m.group(2).lower()])


def _collect_resources():
    info = json.loads(_docker("info", "--format", "{{json .}}"))
    if info.get("ServerErrors") or not info.get("NCPU") or not info.get("MemTotal"):
        # `docker info` exits 0 with empty fields when the daemon is unreachable: never turn that into zeros.
        raise RuntimeError((info.get("ServerErrors") or ["Docker Engine unreachable"])[0])
    clusters = subprocess.run(["bash", str(ROOT / "engine/managed-clusters.sh")], capture_output=True, text=True, timeout=15)
    if clusters.returncode != 0:
        raise RuntimeError(clusters.stderr.strip() or "cluster discovery failed")
    managed = set(clusters.stdout.split())
    # <name>|<state>|<kind cluster label>; labels are Docker metadata, so no name guessing for the nodes.
    nodes = {}                                  # container name -> (cluster, running)
    for line in _docker("ps", "-a", "--format", '{{.Names}}|{{.State}}|{{.Label "%s"}}' % KIND_LABEL).splitlines():
        name, state, cluster = (line.split("|") + ["", ""])[:3]
        if cluster in managed:
            nodes[name] = (cluster, state == "running")
    running = [n for n, (_, up) in nodes.items() if up]
    cpu, mem = 0.0, 0
    if running:
        seen = set()
        for line in _docker("stats", "--no-stream", "--format", "{{json .}}", *running, timeout=30).splitlines():
            row = json.loads(line)
            if row["Name"] in seen or row["Name"] not in nodes:       # never count a container twice
                continue
            seen.add(row["Name"])
            cpu += float(row["CPUPerc"].rstrip("%"))
            mem += _bytes(row["MemUsage"].split("/")[0])
        if seen != set(running):    # a node vanished between the two calls: this snapshot would be inconsistent
            raise RuntimeError("containers changed during collection")
    fully = sum(1 for c in managed if all(up for cl, up in nodes.values() if cl == c) and any(cl == c for cl, _ in nodes.values()))
    return {
        "engine": {"cpus": info["NCPU"], "memory_total_bytes": info["MemTotal"],
                   "containers_running": info["ContainersRunning"], "containers_stopped": info["ContainersStopped"]},
        "playground": {"cpu_percent": round(cpu, 2), "memory_used_bytes": mem, "kind_containers_running": len(running),
                       "kind_clusters_existing": len(managed), "kind_clusters_running": fully},
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "_t": time.time()}


def _resource_loop():
    while time.time() - _res["last_request"] < _RES_IDLE_STOP:
        started = time.time()
        try:
            snap = _collect_resources()
            with _res_lock:
                _res["snapshot"], _res["error"] = snap, None
        except (RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
            with _res_lock:
                _res["error"] = str(exc) or "Docker command timed out"
        _res["first"].set()
        time.sleep(max(0.5, _RES_INTERVAL - (time.time() - started)))
    with _res_lock:
        _res["thread"] = None


@app.get("/api/docker/resources")
def docker_resources():
    with _res_lock:
        _res["last_request"] = time.time()
        if _res["thread"] is None:                       # exactly one collector, whatever the number of clients
            _res["first"].clear()
            _res["thread"] = threading.Thread(target=_resource_loop, daemon=True)
            _res["thread"].start()
    _res["first"].wait(timeout=20)                       # only the very first call (or a restart after idle) waits
    with _res_lock:
        snap, error = _res["snapshot"], _res["error"]
    if snap is None:
        return {"engine": None, "playground": None, "updated_at": None, "age_seconds": None, "stale": True,
                "error": error or "no measurement yet"}
    return {"engine": snap["engine"], "playground": snap["playground"], "updated_at": snap["updated_at"],
            "age_seconds": round(time.time() - snap["_t"], 1), "stale": error is not None, "error": error}

# --- AI Builder proxy (docs/ai-builder.md): all logic, limits and security checks live in ai_builder_proxy.py; the token
# stays on the server. These routes only convert the HTTP request to its arguments and the result to a JSON response.
try:
    _aib = ai_builder_proxy.Proxy()
except ValueError as exc:      # a bad AI_BUILDER_URL must never stop the rest of the Web UI from starting
    print(f"AI Builder proxy: {exc}; using the default address", flush=True)
    _aib = ai_builder_proxy.Proxy(ai_builder_proxy.DEFAULT_UPSTREAM)


def _aib_response(result):
    status, payload = result
    return JSONResponse(payload, status_code=status, headers={"Cache-Control": "no-store"})


async def _read_limited(request, limit):
    """The request body, or None when it is larger than `limit` (never read beyond limit + one chunk)."""
    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > limit:
        return None
    chunks, size = [], 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
            return None
        chunks.append(chunk)
    return b"".join(chunks)


@app.get("/api/ai-builder/health")
def aib_health(request: Request):
    return _aib_response(_aib.handle("health", request.headers))


@app.post("/api/ai-builder/generate")
async def aib_generate(request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    return _aib_response(await run_in_threadpool(_aib.handle, "generate", request.headers, body))


@app.post("/api/ai-builder/conversations")
async def aib_conv_create(request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    return _aib_response(await run_in_threadpool(_aib.handle, "conv_create", request.headers, body))


@app.get("/api/ai-builder/conversations")
def aib_conv_list(request: Request):
    return _aib_response(_aib.handle("conv_list", request.headers))


@app.get("/api/ai-builder/conversations/{conv_id}")
def aib_conv_get(conv_id: str, request: Request):
    return _aib_response(_aib.handle("conv_get", request.headers, None, conv_id))


@app.post("/api/ai-builder/conversations/{conv_id}/messages")
async def aib_conv_send(conv_id: str, request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    return _aib_response(await run_in_threadpool(_aib.handle, "conv_send", request.headers, body, conv_id))


@app.delete("/api/ai-builder/conversations/{conv_id}")
def aib_conv_delete(conv_id: str, request: Request):
    return _aib_response(_aib.handle("conv_delete", request.headers, None, conv_id))


@app.get("/api/ai-builder/conversations/{conv_id}/review")
def aib_conv_review(conv_id: str, request: Request):
    return _aib_response(_aib.handle("conv_review", request.headers, None, conv_id))


@app.post("/api/ai-builder/conversations/{conv_id}/lab")
async def aib_conv_lab(conv_id: str, request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    return _aib_response(await run_in_threadpool(_aib.handle, "conv_lab", request.headers, body, conv_id))


@app.post("/api/ai-builder/conversations/{conv_id}/meta")
async def aib_conv_meta(conv_id: str, request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    return _aib_response(await run_in_threadpool(_aib.handle, "conv_meta", request.headers, body, conv_id))


@app.post("/api/ai-builder/conversations/{conv_id}/context")
async def aib_conv_context(conv_id: str, request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    return _aib_response(await run_in_threadpool(_aib.handle, "conv_context", request.headers, body, conv_id))


def _lab_of(body):
    lab = body.get("lab") if isinstance(body, dict) else None
    return lab if isinstance(lab, str) and lab_delete.LAB_RE.match(lab) else None


@app.post("/api/ai-builder/conversations/{conv_id}/delete_check")
async def aib_delete_check(conv_id: str, request: Request):
    """Is the Lab of the pending deletion request stopped? The browser names the Lab only: the verdict comes from this server's own Docker query."""
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)

    def transform(b):
        lab = _lab_of(b)
        return (400, {"error": "lab: not a valid use case name"}) if lab is None else {"lab": lab, "infrastructure": _gate.infra(lab)}
    return _aib_response(await run_in_threadpool(_aib.handle, "conv_delete_check", request.headers, body, conv_id, transform))


@app.post("/api/ai-builder/conversations/{conv_id}/delete_lab")
async def aib_delete_lab(conv_id: str, request: Request):
    """Delete a whole Lab (move it to the trash). The Lab is marked as being deleted (no start can begin) and its infrastructure is verified
    again right now; the AI Builder re-checks the typed name, the pending request and the Lab's content hash, the publisher does the move."""
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    held = []

    def transform(b):
        lab = _lab_of(b)
        if lab is None:
            return 400, {"error": "lab: not a valid use case name"}
        acquired, state = _gate.begin(lab)
        if acquired:
            held.append(lab)
        return {"lab": lab, "confirm": b.get("confirm"), "infrastructure": state}
    try:
        return _aib_response(await run_in_threadpool(_aib.handle, "conv_delete_lab", request.headers, body, conv_id, transform))
    finally:
        for lab in held:
            _gate.end(lab)


@app.post("/api/ai-builder/conversations/{conv_id}/undo")
def aib_conv_undo(conv_id: str, request: Request):
    return _aib_response(_aib.handle("conv_undo", request.headers, None, conv_id))


@app.post("/api/ai-builder/conversations/{conv_id}/reset")
def aib_conv_reset(conv_id: str, request: Request):
    return _aib_response(_aib.handle("conv_reset", request.headers, None, conv_id))


@app.post("/api/ai-builder/conversations/{conv_id}/discard")
def aib_conv_discard(conv_id: str, request: Request):
    return _aib_response(_aib.handle("conv_discard", request.headers, None, conv_id))


@app.post("/api/ai-builder/conversations/{conv_id}/publish")
async def aib_conv_publish(conv_id: str, request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    return _aib_response(await run_in_threadpool(_aib.handle, "conv_publish", request.headers, body, conv_id))


@app.get("/api/ai-builder/auth/status")
def aib_auth_status(request: Request):
    return _aib_response(_aib.handle("auth_status", request.headers))


@app.post("/api/ai-builder/auth/login")
async def aib_auth_login(request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)
    return _aib_response(await run_in_threadpool(_aib.handle, "auth_login", request.headers, body))


@app.post("/api/ai-builder/auth/code")
async def aib_auth_code(request: Request):
    body = await _read_limited(request, ai_builder_proxy.MAX_BODY)     # the authorization code: forwarded, never logged or stored
    return _aib_response(await run_in_threadpool(_aib.handle, "auth_code", request.headers, body))


@app.post("/api/ai-builder/auth/cancel")
def aib_auth_cancel(request: Request):
    return _aib_response(_aib.handle("auth_cancel", request.headers))


@app.post("/api/ai-builder/auth/logout")
def aib_auth_logout(request: Request):
    return _aib_response(_aib.handle("auth_logout", request.headers))


@app.get("/api/ai-builder/status/{job_id}")
def aib_status(job_id: str, request: Request):
    return _aib_response(_aib.handle("status", request.headers, None, job_id))


@app.get("/api/ai-builder/review/{job_id}")
def aib_review(job_id: str, request: Request):
    return _aib_response(_aib.handle("review", request.headers, None, job_id))


@app.post("/api/ai-builder/approve/{job_id}")
def aib_approve(job_id: str, request: Request):
    return _aib_response(_aib.handle("approve", request.headers, None, job_id))


@app.post("/api/ai-builder/publish/{job_id}")
def aib_publish(job_id: str, request: Request):
    return _aib_response(_aib.handle("publish", request.headers, None, job_id))


class _RevalidatedStatic(StaticFiles):
    """No heuristic caching: a browser must revalidate (ETag) so a changed ai-builder.js/index.html is not served stale."""
    async def get_response(self, path, scope):
        response = await super().get_response(path, scope)
        response.headers["Cache-Control"] = "no-cache"
        return response


app.mount("/", _RevalidatedStatic(directory=Path(__file__).parent / "static", html=True), name="ui")
