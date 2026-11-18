"""Static check of the AI Builder container definition, from the RENDERED Compose model (`docker compose config`).
Nothing is built or started. Usage: ai_builder_compose_test.py <rendered-model.json> <model-without-profile.json>"""
import json
import sys

full = json.load(open(sys.argv[1]))
plain = json.load(open(sys.argv[2]))
svc = full["services"]["ai-builder"]
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   [{detail}]"))
    if not ok:
        failures.append(name)


check("optional: not part of the default `./playground start` model", "ai-builder" not in plain["services"], list(plain["services"]))
check("profile ai-builder", svc.get("profiles") == ["ai-builder"], svc.get("profiles"))
check("non-root user", str(svc.get("user", "")).split(":")[0] not in ("", "0", "root"), svc.get("user"))
check("not privileged", not svc.get("privileged", False))
check("all capabilities dropped", svc.get("cap_drop") == ["ALL"] and not svc.get("cap_add"), (svc.get("cap_drop"), svc.get("cap_add")))
check("no-new-privileges", "no-new-privileges:true" in svc.get("security_opt", []), svc.get("security_opt"))
check("read-only root filesystem with a tmpfs /tmp", svc.get("read_only") is True and "/tmp" in str(svc.get("tmpfs")), (svc.get("read_only"), svc.get("tmpfs")))
check("no host network, pid or ipc namespace", not any(svc.get(k) in ("host",) for k in ("network_mode", "pid", "ipc")))
check("no devices, no extra group access", not svc.get("devices") and not svc.get("group_add"))
check("resource limits (pids, memory)", bool(svc.get("pids_limit")) and bool(svc.get("mem_limit")), (svc.get("pids_limit"), svc.get("mem_limit")))

vols = svc.get("volumes", [])
sources = [v.get("source", "") for v in vols]
targets = {v["target"]: v for v in vols}
check("no Docker socket anywhere", not any("docker.sock" in s for s in sources) and not any("docker.sock" in v["target"] for v in vols), sources)
check("no mount of the whole repository", all(not s.rstrip("/").endswith("cnpg-operator-playground") for s in sources), sources)
rw = sorted(t for t, v in targets.items() if not v.get("read_only"))
check("only /state and the login volume are writable: Claude's container cannot write usecases/", rw == ["/home/builder", "/state"], rw)
check("usecases/ is read-only in the AI Builder at EVERY mount point (no second, writable mount of it)",
      all(v.get("read_only") for v in vols if v.get("source", "").rstrip("/").endswith("usecases")) and "/publish/usecases" not in targets,
      [(v["target"], v.get("read_only")) for v in vols if v.get("source", "").rstrip("/").endswith("usecases")])
check("the AI Builder publishes through the publisher service", svc.get("environment", {}).get("AI_BUILDER_PUBLISHER_URL") == "http://ai-publisher:8098"
      and "AI_BUILDER_PUBLISH_DIR" not in svc.get("environment", {}), svc.get("environment", {}).get("AI_BUILDER_PUBLISHER_URL"))
check("every repository directory is mounted read-only",
      all(v.get("read_only") for t, v in targets.items() if t.startswith("/workspace")), [t for t, v in targets.items() if t.startswith("/workspace") and not v.get("read_only")])
for secret_path in (".env", ".git", "compose.yaml", "tests", "web", "Dockerfile"):
    check(f"{secret_path} is not mounted", f"/workspace/{secret_path}" not in targets and not any(s.endswith("/" + secret_path) for s in sources), sources)
check("the login lives in a dedicated named volume", targets.get("/home/builder", {}).get("type") == "volume" and targets["/home/builder"].get("source", "").endswith("claude-auth"),
      targets.get("/home/builder"))
check("state is a bind mount", targets["/state"]["type"] == "bind")
check("the API token is a compose secret (not an environment variable)", "ai_builder_token" in [s["source"] if isinstance(s, dict) else s for s in svc.get("secrets", [])]
      and "TOKEN" not in " ".join(k for k in svc.get("environment", {}) if not k.endswith("TOKEN_FILE")), svc.get("environment"))

ports = svc.get("ports", [])
check("published on the host loopback only", ports and all(p.get("host_ip") == "127.0.0.1" for p in ports), ports)
env = svc.get("environment", {})
check("no credential or API key in the environment", not any(k in env for k in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN")), list(env))
check("container name is fixed (the CLI addresses it)", svc.get("container_name") == "cnpg-ai-builder", svc.get("container_name"))
check("the Playground service is unchanged: root, with the socket", full["services"]["playground"].get("volumes") is not None
      and any("docker.sock" in v.get("source", "") for v in full["services"]["playground"]["volumes"]))
# --- the publisher: the ONLY writer of published Labs --------------------------------------------------------------------------
pub = full["services"].get("ai-publisher", {})
pvols = {v["target"]: v for v in pub.get("volumes", [])}
check("publisher: optional (profile ai-builder), not in the default model", pub.get("profiles") == ["ai-builder"] and "ai-publisher" not in plain["services"], pub.get("profiles"))
check("publisher: non-root, no capabilities, no new privileges, read-only root, tmpfs /tmp",
      str(pub.get("user", "")).split(":")[0] not in ("", "0", "root") and pub.get("cap_drop") == ["ALL"] and "no-new-privileges:true" in pub.get("security_opt", [])
      and pub.get("read_only") is True and "/tmp" in str(pub.get("tmpfs")) and not pub.get("privileged"), (pub.get("user"), pub.get("cap_drop")))
check("publisher: the usecases directory is its ONLY writable mount", sorted(t for t, v in pvols.items() if not v.get("read_only")) == ["/publish/usecases"],
      sorted(t for t, v in pvols.items() if not v.get("read_only")))
check("publisher: the state directory (drafts, working copies) is mounted read-only", pvols.get("/state", {}).get("read_only") is True, pvols.get("/state"))
check("publisher: no Claude login volume, no Docker socket, no whole-repository mount",
      "/home/builder" not in pvols and not any("docker.sock" in v.get("source", "") for v in pvols.values())
      and all(not v.get("source", "").rstrip("/").endswith("cnpg-operator-playground") for v in pvols.values()), list(pvols))
check("publisher: no port published on the host", not pub.get("ports"), pub.get("ports"))
check("publisher: only the API token secret, no credential in the environment",
      [s["source"] if isinstance(s, dict) else s for s in pub.get("secrets", [])] == ["ai_builder_token"]
      and not any(k in pub.get("environment", {}) for k in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN")), pub.get("secrets"))
check("publisher: same image as the AI Builder, runs publisher.py", pub.get("image") == svc.get("image") and "publisher.py" in " ".join(pub.get("command", [])), (pub.get("image"), pub.get("command")))
check("only the publisher can write usecases/: no other service mounts it writable besides the Playground's whole-repository mount",
      all(v.get("read_only") for name in ("ai-builder",) for v in full["services"][name].get("volumes", []) if v.get("source", "").rstrip("/").endswith("usecases")))
sys.exit(1 if failures else 0)
