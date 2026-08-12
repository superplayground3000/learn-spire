#!/usr/bin/env python3
"""Zone-lab control panel. A host-side operator console for the running lab.

The panel runs on the host with the Python standard library only. It binds
127.0.0.1:8900 and shells out to `docker` against the running compose project.
It is a demo and operator tool, not a security control. It needs no identity and
does not sit behind Envoy.

The one teaching purpose: make the three enforcement points visible and movable
at once. One zone-pair toggle drives all three at the same time:

  network   -- `docker network connect` / `disconnect` a gateway to a zone
  identity  -- rewrite the target gateway Envoy RBAC allow-list and restart it
  DNS       -- restart the registry with a new POLICY_JSON so the views change

Two layers are always shown SEPARATELY, because the whole lab exists to keep
them apart:

  network   -- did a packet even arrive?      (nc; "refused" still means reached)
  identity  -- was the caller allowed?         (mTLS with the caller SVID)

"reachable but rejected" and "not reachable at all" are different security
properties. The panel never joins them into one state.

Usage:  python3 ui/server.py [--port 8900] [--bind 127.0.0.1] [--no-reconcile]
"""
import argparse
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --------------------------------------------------------------------------- paths
UI_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(UI_DIR)          # labs/zone-lab
POLICY_FILE = os.path.join(UI_DIR, ".policy.json")
COMPOSE = os.environ.get("COMPOSE", "docker compose").split()

TOKEN = None  # set in main(); when set, every request must present it
COOKIE = "zlab"

# --------------------------------------------------------------------------- names
# Containers use the "zone-lab-" prefix from docker-compose container_name.
C_A_PEER = "zone-lab-zone-a-peer"
C_B_GW = "zone-lab-zone-b-gateway"
C_B_BE = "zone-lab-zone-b-backend"
C_C_GW = "zone-lab-zone-c-gateway"
C_C_BE = "zone-lab-zone-c-backend"
C_REG = "zone-lab-zone-registry"
C_SPIRE = "zone-lab-spire-server"
# The client is a one-shot demo service. It has no long-lived container, so a
# client-origin probe runs it with "docker compose run --rm".
SVC_A_CLIENT = "zone-a-client"

# Zone-facing addresses only. The mgmt networks carry control traffic; they are
# not the data path being zoned, so the panel never probes them.
IP_A_PEER = "10.10.0.30"
IP_B_GW_A = "10.10.0.40"   # zone-b gateway, zone-a side (the A->B front door)
IP_B_GW_B = "10.20.0.40"   # zone-b gateway, zone-b side
IP_C_GW_B = "10.20.0.41"   # zone-c gateway, zone-b side (the B->C front door)
IP_C_GW_C = "10.30.0.40"   # zone-c gateway, zone-c side
IP_B_BE = "10.20.0.50"
IP_C_BE = "10.30.0.50"

GW_PORT = 9000
BE_PORT = 9001
PEER_PORT = 8080

AGENT_SOCK = "/run/spire/agent.sock"

# --------------------------------------------------------------------------- graph
# The graph nodes are the data-plane workloads. Gateways carry an address in TWO
# zones on purpose: that is what makes them the bridge, and the graph shows it.
NODES = [
    {"id": "a-client",  "label": "a-client",  "zone": "zone-a", "kind": "client",
     "src": ("run", SVC_A_CLIENT), "ips": [], "port": None, "svid": True},
    {"id": "a-peer",    "label": "a-peer",    "zone": "zone-a", "kind": "peer",
     "src": ("exec", C_A_PEER), "ips": [IP_A_PEER], "port": PEER_PORT, "plain": True, "svid": True},
    {"id": "b-gateway", "label": "b-gateway", "zone": "zone-b", "kind": "gateway",
     "src": ("exec", C_B_GW), "ips": [IP_B_GW_A, IP_B_GW_B], "port": GW_PORT, "mtls": True, "svid": True},
    {"id": "b-backend", "label": "b-backend", "zone": "zone-b", "kind": "backend",
     "src": ("exec", C_B_BE), "ips": [IP_B_BE], "port": BE_PORT, "mtls": True, "svid": True},
    {"id": "c-gateway", "label": "c-gateway", "zone": "zone-c", "kind": "gateway",
     "src": ("exec", C_C_GW), "ips": [IP_C_GW_B, IP_C_GW_C], "port": GW_PORT, "mtls": True, "svid": True},
    {"id": "c-backend", "label": "c-backend", "zone": "zone-c", "kind": "backend",
     "src": ("exec", C_C_BE), "ips": [IP_C_BE], "port": BE_PORT, "mtls": True, "svid": True},
]
NODE = {n["id"]: n for n in NODES}

# A label for every known address, so a DNS answer or a graph node reads as a
# named workload rather than a bare number.
IP_LABELS = {
    IP_A_PEER: ("a-peer", "workload", "zone-a"),
    "10.10.0.20": ("a-client", "workload", "zone-a"),
    IP_B_GW_A: ("b-gateway", "gateway", "zone-b"),
    IP_B_GW_B: ("b-gateway", "gateway", "zone-b"),
    IP_C_GW_B: ("c-gateway", "gateway", "zone-c"),
    IP_C_GW_C: ("c-gateway", "gateway", "zone-c"),
    IP_B_BE: ("b-backend", "workload", "zone-b"),
    IP_C_BE: ("c-backend", "workload", "zone-c"),
}

# --------------------------------------------------------------------------- policy
# The lab is a linear chain: zone-a/client -> zone-b, zone-b/backend -> zone-c.
# So there are two controllable pairs. Each pair owns one gateway and drives the
# three enforcement points for that hop.
NET_ZONE_A = "zone-lab_zone-a"
NET_ZONE_B = "zone-lab_zone-b"

PAIRS = [("zone-a", "zone-b"), ("zone-b", "zone-c")]
DEFAULT_POLICY = {"zone-a|zone-b": True, "zone-b|zone-c": True}

# Per pair: the gateway container, its base config on the host, the caller-side
# network and address to attach, and the SPIFFE ID it must admit at Layer 7.
PAIR_GW = {
    "zone-a|zone-b": {
        "gw": C_B_GW,
        "base": os.path.join(PROJECT_DIR, "conf", "zone-b-gateway-envoy.yaml"),
        "net": NET_ZONE_A, "ip": IP_B_GW_A,
        "allow": "spiffe://lab.local/zone-a/client",
    },
    "zone-b|zone-c": {
        "gw": C_C_GW,
        "base": os.path.join(PROJECT_DIR, "conf", "zone-c-gateway-envoy.yaml"),
        "net": NET_ZONE_B, "ip": IP_C_GW_B,
        "allow": "spiffe://lab.local/zone-b/backend",
    },
}


def load_policy():
    try:
        with open(POLICY_FILE) as f:
            p = json.load(f)
        return {k: bool(p.get(k, DEFAULT_POLICY[k])) for k in DEFAULT_POLICY}
    except Exception:
        return dict(DEFAULT_POLICY)


def save_policy(p):
    with open(POLICY_FILE, "w") as f:
        json.dump(p, f)


def policy_json(policy):
    """Build the registry POLICY_JSON from the two toggles. A zone maps to the
    peer zones it may reach. The registry renders one wildcard per authorized
    peer, so the DNS views change with the policy."""
    return {
        "zone-a": ["zone-b"] if policy["zone-a|zone-b"] else [],
        "zone-b": ["zone-c"] if policy["zone-b|zone-c"] else [],
    }


# --------------------------------------------------------------------------- shell
def run(args, timeout=30, cwd=None):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except Exception as e:
        return 125, str(e)


def dexec(container, cmd, timeout=30):
    """Run a shell command inside an always-up container."""
    return run(["docker", "exec", container, "bash", "-c", cmd], timeout=timeout)


def crun(service, cmd, timeout=45):
    """Run a shell command in a fresh one-shot container of a compose service.
    Used for the client, which has no long-lived container."""
    return run(COMPOSE + ["--progress", "quiet", "run", "--rm", "--no-deps", "-T",
                          service, "bash", "-c", cmd], timeout=timeout, cwd=PROJECT_DIR)


def container_networks(name):
    _, out = run(["docker", "inspect", name, "-f",
                  "{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}"], timeout=10)
    return sorted(out.split())


# --------------------------------------------------------------------------- rbac
def rewrite_rbac(base_text, allow_ids):
    """Rewrite the L7 RBAC principal list of a gateway Envoy config.

    It replaces the entries under the first
    "principals:" key. An empty allow-list renders one sentinel principal,
    spiffe://invalid/none, which denies everyone -- the correct meaning of "no
    zone may call this gateway".
    """
    lines = base_text.split("\n")
    out, i, replaced = [], 0, False
    while i < len(lines):
        ln = lines[i]
        out.append(ln)
        if ln.strip() == "principals:" and not replaced:
            indent = " " * (len(ln) - len(ln.lstrip()))
            i += 1
            while i < len(lines) and lines[i].strip().startswith("- authenticated:"):
                i += 1
            ids = allow_ids or ["spiffe://invalid/none"]
            for sid in ids:
                out.append(f'{indent}- authenticated: {{ principal_name: {{ exact: "{sid}" }} }}')
            replaced = True
            continue
        i += 1
    if not replaced:
        raise ValueError("no 'principals:' block found in the base config")
    return "\n".join(out)


# --------------------------------------------------------------------------- apply
def apply_policy(policy):
    """Push one policy to all three enforcement points, per pair.

    Order per pair: attach the network first, then narrow identity. Opening the
    route before identity adds nothing extra, because RBAC still denies. Then
    restart the registry once, so the DNS views re-render for the whole policy.
    """
    steps = []
    for a, b in PAIRS:
        key = f"{a}|{b}"
        cfg = PAIR_GW[key]
        on = policy[key]
        gw = cfg["gw"]

        # 1. NETWORK. The gateway sits on the caller-side network only when the
        #    pair is authorized. That is what makes the pair reachable at all.
        attached = cfg["net"] in container_networks(gw)
        if on and not attached:
            rc, o = run(["docker", "network", "connect", "--ip", cfg["ip"], cfg["net"], gw], timeout=30)
            steps.append(f"network: attach {gw} -> {cfg['net']} ({'ok' if rc == 0 else o.strip()[-50:]})")
        elif not on and attached:
            rc, o = run(["docker", "network", "disconnect", cfg["net"], gw], timeout=30)
            steps.append(f"network: detach {gw} from {cfg['net']} ({'ok' if rc == 0 else o.strip()[-50:]})")
        else:
            steps.append(f"network: {gw} on {cfg['net']} already {'attached' if on else 'detached'}")

        # 2. IDENTITY. Rewrite the gateway RBAC allow-list and restart its Envoy.
        allow = [cfg["allow"]] if on else []
        try:
            new_text = rewrite_rbac(open(cfg["base"]).read(), allow)
        except Exception as e:
            steps.append(f"identity: {gw} rewrite FAILED: {e}")
            continue
        fd, tmp = tempfile.mkstemp(prefix="gw-envoy-", suffix=".yaml", dir=UI_DIR)
        try:
            with os.fdopen(fd, "w") as f:
                f.write(new_text)
            rc, o = run(["docker", "cp", tmp, f"{gw}:/tmp/gw-envoy.yaml"], timeout=20)
        finally:
            os.unlink(tmp)
        if rc != 0:
            steps.append(f"identity: {gw} copy FAILED: {o.strip()[-50:]}")
            continue
        dexec(gw, 'pkill -f "envoy -c" 2>/dev/null; sleep 1; true', timeout=15)
        run(["docker", "exec", "-d", gw, "bash", "-c",
             "envoy -c /tmp/gw-envoy.yaml --log-path /var/log/envoy/envoy.log"], timeout=15)
        steps.append(f"identity: {gw} RBAC allows {len(allow)} id(s), Envoy restarted")

    # 3. DNS. Restart the registry with the new POLICY_JSON. Pushing policy by
    #    restart avoids an unauthenticated endpoint that could rewrite it.
    pj = json.dumps(policy_json(policy))
    dexec(C_REG, 'pkill -x registry 2>/dev/null; pkill -f /usr/local/bin/registry 2>/dev/null; sleep 1; true', timeout=15)
    run(["docker", "exec", "-d", "-e", f"POLICY_JSON={pj}", "-e", "LEASE_TTL=30",
         "-e", "REAP_INTERVAL=5", C_REG, "bash", "-c",
         "registry >>/var/log/lab/registry.log 2>&1"], timeout=15)
    steps.append(f"dns: registry restarted with POLICY_JSON={pj}")

    time.sleep(6)
    return steps


# --------------------------------------------------------------------------- probe
def _build_batch(probes):
    """Build one shell script that runs every probe for a single source. A
    source is one container, so all its probes share one container and never
    fight over the fixed zone address."""
    need_svid = any(p["kind"] == "mtls" for p in probes)
    parts = []
    if need_svid:
        parts.append("rm -rf /tmp/svid; mkdir -p /tmp/svid; "
                     f"spire-agent api fetch x509 -socketPath {AGENT_SOCK} -write /tmp/svid >/dev/null 2>&1 || true")
    for p in probes:
        pid, port = p["id"], p["port"]
        ips = p["ips"]
        # A node can be multi-homed. Try every address, so "reachable" means the
        # packet arrived at ANY of the node's addresses. The reverse of a probe
        # is never wrongly marked unreachable because the wrong side was tried.
        cmds = []
        for ip in ips:
            if p["kind"] == "net":
                cmds.append(f"nc -v -w2 -z {ip} {port} 2>&1")
            elif p["kind"] == "mtls":
                cmds.append(f"curl -sS -k --cert /tmp/svid/svid.0.pem --key /tmp/svid/svid.0.key "
                            f"--cacert /tmp/svid/bundle.0.pem 'https://{ip}:{port}/' --max-time 6 "
                            f"-w '\\nCODE:%{{http_code}}\\n' 2>&1")
            else:  # plain
                cmds.append(f"curl -sS 'http://{ip}:{port}/' --max-time 6 -w '\\nCODE:%{{http_code}}\\n' 2>&1")
        body = "; ".join(cmds) if cmds else "true"
        parts.append(f"printf '@@ID {pid}\\n'; {body}; printf '\\n@@END {pid}\\n'")
    return "\n".join(parts)


def _parse_batch(out, probes):
    res = {}
    for p in probes:
        pid = p["id"]
        m = re.search(r"@@ID " + re.escape(pid) + r"\n(.*?)\n@@END " + re.escape(pid),
                      out, re.S)
        raw = m.group(1) if m else ""
        res[pid] = classify(p["kind"], raw)
    return res


def source_batch(node, probes, timeout=45):
    """Run a batch of probes from one source container."""
    if not probes:
        return {}
    script = _build_batch(probes)
    mode, target = node["src"]
    if mode == "run":
        _, out = crun(target, script, timeout=timeout)
    else:
        _, out = dexec(target, script, timeout=timeout)
    return _parse_batch(out, probes)


def classify(kind, out):
    low = out.lower()
    if kind == "net":
        if "succeeded" in low or "open" in low:
            return ("open", "TCP connection established")
        if "refused" in low:
            return ("refused", "arrived, then refused (host reachable)")
        if "unreachable" in low or "no route" in low:
            return ("no-route", "no route to the address")
        if "timed out" in low or "timeout" in low:
            return ("filtered", "timed out (silently dropped)")
        return ("unknown", " ".join(out.split())[-70:] or "no output")
    if kind == "mtls":
        # Any address that answered 200 means allowed. A 401/403 on any address
        # means reached-but-denied. Only when every address failed to connect is
        # the pair NEVER REACHED, which says nothing about identity.
        if "code:200" in low:
            return ("allowed", "HTTP 200, real backend body")
        if "code:403" in low or "code:401" in low:
            return ("rejected", "HTTP 403/401 (identity denied)")
        if "code:000" in low or "couldn't connect" in low or "could not connect" in low \
                or "unreachable" in low or "no route" in low or "connection refused" in low \
                or "failed to connect" in low:
            return ("never_reached", " ".join(out.split())[-70:] or "no route")
        return ("rejected", " ".join(out.split())[-70:] or "denied")
    # plain
    if "code:200" in low:
        return ("open", "HTTP 200, plain HTTP")
    return ("blocked", " ".join(out.split())[-70:] or "no output")


# --------------------------------------------------------------------------- state
def envoy_stat(container, pattern):
    _, out = dexec(container, f"curl -s http://127.0.0.1:9901/stats | grep -E '{pattern}' || true", timeout=10)
    d = {}
    for line in out.splitlines():
        m = re.match(r"^([\w.]+):\s*(\d+)$", line.strip())
        if m:
            d[m.group(1)] = int(m.group(2))
    return d


def gather():
    """Probe the running lab. Every source runs one batch, in parallel with the
    other sources."""
    # source id -> list of probes
    batches = {
        "a-peer": [
            {"id": "a_to_b_direct", "kind": "net", "ips": [IP_B_BE], "port": BE_PORT},
            {"id": "a_to_bgw", "kind": "net", "ips": [IP_B_GW_A], "port": GW_PORT},
            {"id": "a_to_c_backend", "kind": "net", "ips": [IP_C_BE], "port": BE_PORT},
            {"id": "a_to_cgw", "kind": "net", "ips": [IP_C_GW_B], "port": GW_PORT},
            {"id": "a_peer_bgw_id", "kind": "mtls", "ips": [IP_B_GW_A], "port": GW_PORT},
        ],
        "b-gateway": [
            {"id": "bgw_to_b", "kind": "net", "ips": [IP_B_BE], "port": BE_PORT},
        ],
        "b-backend": [
            {"id": "b_to_c_id", "kind": "mtls", "ips": [IP_C_GW_B], "port": GW_PORT},
        ],
        "a-client": [
            {"id": "a_client_bgw_id", "kind": "mtls", "ips": [IP_B_GW_A], "port": GW_PORT},
            {"id": "a_client_cgw_id", "kind": "mtls", "ips": [IP_C_GW_B], "port": GW_PORT},
            {"id": "a_peer_intra", "kind": "plain", "ips": [IP_A_PEER], "port": PEER_PORT},
        ],
    }
    src_node = {"a-peer": NODE["a-peer"], "b-gateway": NODE["b-gateway"],
                "b-backend": NODE["b-backend"], "a-client": NODE["a-client"]}
    results = {}
    with ThreadPoolExecutor(max_workers=6) as ex:
        futs = {k: ex.submit(source_batch, src_node[k], v) for k, v in batches.items()}
        for k, f in futs.items():
            try:
                results.update(f.result(timeout=60))
            except Exception as e:
                for p in batches[k]:
                    results[p["id"]] = ("unknown", str(e)[:70])

    allc = [C_A_PEER, C_B_GW, C_B_BE, C_C_GW, C_C_BE, C_REG, C_SPIRE]
    nets, up = {}, {}
    for n in allc:
        nets[n] = container_networks(n)
        rc, o = run(["docker", "inspect", n, "-f", "{{.State.Running}}"], timeout=10)
        up[n] = (rc == 0 and "true" in o)

    stats = {
        "b_gateway": envoy_stat(C_B_GW, r"^http\.gateway\.rbac\.(allowed|denied)"),
        "c_gateway": envoy_stat(C_C_GW, r"^http\.gateway\.rbac\.(allowed|denied)"),
        "b_backend": envoy_stat(C_B_BE, r"^rbac_backend\.rbac\.(allowed|denied)|^listener\.0\.0\.0\.0_9001\.ssl\.(fail_verify_san|handshake)"),
        "c_backend": envoy_stat(C_C_BE, r"^rbac_backend\.rbac\.(allowed|denied)|^listener\.0\.0\.0\.0_9001\.ssl\.(fail_verify_san|handshake)"),
    }
    return {"results": {k: {"state": s, "detail": d} for k, (s, d) in results.items()},
            "networks": nets, "running": up, "policy": load_policy(), "stats": stats}


# --------------------------------------------------------------------------- dns
def dig_from(container, resolver, name):
    _, out = dexec(container, f"dig @{resolver} {name} +time=2 +tries=1 2>&1 || true", timeout=15)
    status = "UNKNOWN"
    ms = re.search(r"status:\s*(\w+)", out)
    if ms:
        status = ms.group(1)
    ip = ""
    for line in out.splitlines():
        m = re.search(r"\bIN\s+A\s+([0-9.]+)\s*$", line.strip())
        if m and not line.strip().startswith(";"):
            ip = m.group(1)
            break
    return status, ip


def build_dns():
    """Resolve the cross-zone names through each zone's own CoreDNS. The same
    name resolves differently per zone: a zone's own service gives the real
    address, an authorized peer gives that peer's gateway address, and an
    unauthorized zone gives NXDOMAIN."""
    viewers = [
        ("zone-a", C_A_PEER, "10.10.0.53"),
        ("zone-b", C_B_BE, "10.20.0.53"),
        ("zone-c", C_C_BE, "10.30.0.53"),
    ]
    names = ["backend.zone-a.internal", "backend.zone-b.internal", "backend.zone-c.internal"]
    zones = {}
    for zone, container, resolver in viewers:
        recs = []
        for name in names:
            status, ip = dig_from(container, resolver, name)
            label = IP_LABELS.get(ip, ("?", "unknown", "?"))
            recs.append({
                "name": name, "status": status, "ip": ip,
                "target": label[0] if ip else "", "kind": label[1] if ip else "",
                "answer": ("NXDOMAIN" if status == "NXDOMAIN" else
                           (ip if ip else status)),
            })
        zones[zone] = recs
    return {"zones": zones}


# --------------------------------------------------------------------------- graph
def _identity_targets():
    return [n for n in NODES if n.get("mtls")]


def build_graph(layer="network"):
    """Probe every workload pair in both directions.

    The network layer is symmetric, so it never shows a one-way link. The
    identity layer is where asymmetry is real: it traces the authorized call
    chain as one-way edges.
    """
    ids = [n["id"] for n in NODES]
    pairs = [(ids[i], ids[j]) for i in range(len(ids)) for j in range(i + 1, len(ids))]

    # Group the directed probes by source, so each source runs one container.
    per_source = {nid: [] for nid in ids}

    def add(src_id, dst_id):
        s, d = NODE[src_id], NODE[dst_id]
        if layer == "network":
            if not d["ips"] or d["port"] is None:
                return None
            pid = f"{src_id}__{dst_id}"
            per_source[src_id].append({"id": pid, "kind": "net", "ips": d["ips"], "port": d["port"]})
            return pid
        else:
            if not d.get("mtls") or not s.get("svid"):
                return None
            pid = f"{src_id}__{dst_id}"
            per_source[src_id].append({"id": pid, "kind": "mtls", "ips": d["ips"], "port": d["port"]})
            return pid

    edge_ids = {}
    for a, b in pairs:
        edge_ids[(a, b, "fwd")] = add(a, b)
        edge_ids[(a, b, "rev")] = add(b, a)

    # Run every source batch in parallel.
    out = {}
    with ThreadPoolExecutor(max_workers=len(ids)) as ex:
        futs = {nid: ex.submit(source_batch, NODE[nid], per_source[nid], 60)
                for nid in ids if per_source[nid]}
        for nid, f in futs.items():
            try:
                out.update(f.result(timeout=90))
            except Exception as e:
                for p in per_source[nid]:
                    out[p["id"]] = ("unknown", str(e)[:60])

    def ok(pid):
        if pid is None:
            return None, "not applicable"
        st, det = out.get(pid, ("unknown", "no result"))
        if layer == "network":
            return (st in ("open", "refused")), f"{st}: {det}"
        return ({"allowed": True, "rejected": False, "never_reached": None}.get(st, None)), f"{st}: {det}"

    edges = []
    for a, b in pairs:
        fok, fd = ok(edge_ids[(a, b, "fwd")])
        rok, rd = ok(edge_ids[(a, b, "rev")])
        if fok is None and rok is None:
            state = "na"
        elif fok and rok:
            state = "both"
        elif fok or rok:
            state = "one"
        else:
            state = "none"
        edges.append({"a": a, "b": b, "state": state, "fwd": fok, "rev": rok,
                      "fwd_detail": fd, "rev_detail": rd,
                      "cross": NODE[a]["zone"] != NODE[b]["zone"]})
    view_nodes = [{k: v for k, v in n.items() if k != "src"} for n in NODES]
    return {"layer": layer, "nodes": view_nodes, "edges": edges}


# --------------------------------------------------------------------------- page
INDEX = r"""<!doctype html><html><head><meta charset="utf-8">
<title>Zone-lab — live control</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#0d1117;--fg:#e6edf3;--mut:#8b949e;--card:#161b22;--line:#30363d;
--ok:#3fb950;--bad:#f85149;--warn:#d29922;--info:#58a6ff}
@media(prefers-color-scheme:light){:root{--bg:#fff;--fg:#1f2328;--mut:#59636e;--card:#f6f8fa;--line:#d1d9e0;
--ok:#1a7f37;--bad:#cf222e;--warn:#9a6700;--info:#0969da}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;padding:24px}
h1{font-size:20px;margin:0 0 4px}p.sub{color:var(--mut);margin:0 0 20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(340px,100%),1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;min-width:0;overflow:hidden}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:0 0 12px}
.row{display:flex;align-items:flex-start;gap:10px;padding:9px 0;border-top:1px solid var(--line)}
.row:first-of-type{border-top:none}
.dot{width:9px;height:9px;border-radius:50%;flex:0 0 9px;margin-top:6px}
.n{flex:1;min-width:0}.n b{font-weight:600}
.n small{display:block;color:var(--mut);font-family:ui-monospace,Menlo,monospace;font-size:11px;
word-break:break-all;margin-top:2px}
.tag{font-size:10px;font-weight:700;letter-spacing:.04em;padding:2px 7px;border-radius:20px;white-space:nowrap;margin-top:3px}
.ok{background:color-mix(in srgb,var(--ok) 18%,transparent);color:var(--ok)}
.bad{background:color-mix(in srgb,var(--bad) 18%,transparent);color:var(--bad)}
.warn{background:color-mix(in srgb,var(--warn) 18%,transparent);color:var(--warn)}
.info{background:color-mix(in srgb,var(--info) 18%,transparent);color:var(--info)}
.d-ok{background:var(--ok)}.d-bad{background:var(--bad)}.d-warn{background:var(--warn)}.d-info{background:var(--info)}
.tg{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:11px 0;border-top:1px solid var(--line)}
.tg:first-of-type{border-top:none}
.sw{position:relative;width:44px;height:24px;flex:0 0 44px;border:none;border-radius:99px;background:var(--line);cursor:pointer;transition:.15s}
.sw[aria-pressed="true"]{background:var(--ok)}
.sw::after{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:#fff;transition:.15s}
.sw[aria-pressed="true"]::after{transform:translateX(20px)}
.sw:disabled{opacity:.5;cursor:wait}
button.rf{background:var(--info);color:#fff;border:none;border-radius:7px;padding:7px 14px;font-weight:600;cursor:pointer}
.bar{display:flex;align-items:center;gap:12px;margin-bottom:16px;flex-wrap:wrap}
.legend{color:var(--mut);font-size:12px}
.note{border-left:3px solid var(--warn);padding:8px 12px;margin-top:12px;color:var(--mut);font-size:12px;
background:color-mix(in srgb,var(--warn) 7%,transparent)}
table{width:100%;border-collapse:collapse;font-size:12px;table-layout:fixed}
td{padding:5px 0;border-top:1px solid var(--line);overflow-wrap:anywhere}
td:first-child{color:var(--mut)}
td:last-child{text-align:right;font-family:ui-monospace,Menlo,monospace;width:44%}
</style></head><body>
<h1>Zone-lab — live control</h1>
<p class="sub">Probes the running lab. <b>Network</b> and <b>identity</b> stay separate:
"reachable but rejected" is not the same security property as "no route at all".</p>
<div class="bar">
  <button class="rf" onclick="load()">Refresh</button>
  <label class="legend"><input type="checkbox" id="auto"> auto every 20s</label>
  <span class="legend" id="stamp"></span>
</div>
<div class="grid">
  <div class="card"><h2>Zone A → Zone B (network layer)</h2><div id="x"></div>
    <div class="note">The design wants <b>no route</b> from a zone-a workload to the zone-b backend.
    <b>Connection refused</b> would mean the packet arrived — containment at the service layer, not the network.</div></div>
  <div class="card"><h2>Inside Zone A (plaintext)</h2><div id="i"></div>
    <div class="note">The client reaches the zone-a peer over plain HTTP, with no mTLS and no gateway.
    mTLS happens only at the zone boundary (property P10).</div></div>
  <div class="card"><h2>Zone A → Zone C (not an authorized pair)</h2><div id="c"></div>
    <div class="note">Zone A may reach Zone B; Zone B may reach Zone C; <b>Zone A may not reach Zone C</b>.
    Zone A has no route even to the Zone C front door. The B→C row is also the liveness control.</div></div>
  <div class="card"><h2>Identity layer (mTLS + SPIFFE)</h2><div id="d"></div>
    <div class="note"><b>NEVER REACHED</b> is not an identity result. A pair with no route says nothing
    about the identity layer, so the panel never marks it "denied".</div></div>
  <div class="card"><h2>Policy matrix — changes the real lab</h2><div id="t"></div>
    <div class="note">Each toggle changes three layers at once: <b>network</b> (the gateway on the caller
    zone network), <b>identity</b> (the gateway RBAC allow-list), and <b>DNS</b> (each zone view).
    One apply takes about ten seconds; then press Refresh to see the graph move.</div></div>
  <div class="card" style="grid-column:1/-1"><h2>CoreDNS name map (per zone view)</h2>
    <div class="bar" style="margin:0 0 10px"><button class="rf" onclick="loadDns()">Re-read</button>
      <span class="legend" id="dstamp"></span></div>
    <div id="dns" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px"></div>
    <div class="note">The same name resolves differently per zone: a zone's own service gives the
    <b>real address</b>, an authorized peer gives that peer's <b>gateway address</b>, and an
    unauthorized zone gives <b>NXDOMAIN</b>.</div>
  </div>
  <div class="card" style="grid-column:1/-1"><h2>Connectivity graph</h2>
    <div class="bar" style="margin:0 0 10px">
      <label class="legend"><input type="radio" name="lay" value="network" checked> network layer</label>
      <label class="legend"><input type="radio" name="lay" value="identity"> identity layer (mTLS)</label>
      <button class="rf" onclick="loadGraph()">Re-probe</button>
      <span class="legend" id="gstamp"></span>
    </div>
    <div style="overflow-x:auto"><svg id="g" viewBox="0 0 900 470" style="width:100%;min-width:640px;height:auto"></svg></div>
    <div class="legend" style="margin-top:8px">
      <span style="color:var(--ok)">&#9472;&#9472; green: both ways</span> &nbsp;
      <span style="color:var(--warn)">&#9472;&#9472; amber: one way (arrow shows direction)</span> &nbsp;
      <span style="color:var(--bad)">&#9476;&#9476; red: neither way</span>
    </div>
    <div class="note" id="gnote"></div>
  </div>
  <div class="card"><h2>Envoy counters (which mechanism decided)</h2><div id="s"></div>
    <div class="note">L7 RBAC <code>http.gateway.rbac.denied</code>, network RBAC
    <code>rbac_backend.rbac.denied</code>, SAN verify <code>...ssl.fail_verify_san</code>.</div></div>
  <div class="card"><h2>Container networks</h2><div id="n"></div></div>
</div>
<script>
const L={open:['ok','REACHABLE'],'no-route':['ok','NO ROUTE'],refused:['bad','ARRIVED · REFUSED'],
filtered:['warn','DROPPED'],allowed:['ok','ALLOWED'],rejected:['ok','REJECTED'],blocked:['bad','BLOCKED'],
never_reached:['warn','NEVER REACHED — not an identity result'],unknown:['warn','UNKNOWN']};
function row(t,r,want){const [c,lab]=L[r.state]||['warn',(r.state||'?').toUpperCase()];
const good = want.includes(r.state);
const cls = good?'ok':(r.state==='unknown'?'warn':'bad');
return `<div class="row"><span class="dot d-${cls}"></span><span class="n"><b>${t}</b><small>${r.detail||''}</small></span><span class="tag ${cls}">${lab}</span></div>`}
const GN={b_gateway:'zone-b gateway',c_gateway:'zone-c gateway',b_backend:'zone-b backend',c_backend:'zone-c backend'};
function load(){fetch('/api/state').then(r=>r.json()).then(s=>{
 const R=s.results;
 x.innerHTML = row('zone-a peer → zone-b backend :9001',R.a_to_b_direct,['no-route','filtered'])
   + row('zone-a peer → zone-b gateway :9000 (front door)',R.a_to_bgw,['open'])
   + row('zone-b gateway → zone-b backend :9001 (control)',R.bgw_to_b,['open']);
 i.innerHTML = row('zone-a client → zone-a peer :8080 (plain HTTP, no mTLS)',R.a_peer_intra,['open']);
 c.innerHTML = row('zone-a peer → zone-c backend :9001',R.a_to_c_backend,['no-route','filtered'])
   + row('zone-a peer → zone-c gateway :9000 (front door on zone-b)',R.a_to_cgw,['no-route','filtered'])
   + row('zone-b backend → zone-c gateway :9000 (authorized pair · liveness)',R.b_to_c_id,['allowed']);
 d.innerHTML = row('zone-a client → zone-b gateway, presenting zone-a/client',R.a_client_bgw_id,['allowed'])
   + row('zone-a peer → zone-b gateway, presenting zone-a/peer',R.a_peer_bgw_id,['rejected'])
   + row('zone-b backend → zone-c gateway, presenting zone-b/backend',R.b_to_c_id,['allowed'])
   + row('zone-a client → zone-c gateway (no route)',R.a_client_cgw_id,['never_reached']);
 const PN={'zone-a|zone-b':'Zone A → Zone B (via zone-b gateway)','zone-b|zone-c':'Zone B → Zone C (via zone-c gateway)'};
 t.innerHTML = Object.entries(s.policy||{}).map(([k,v])=>
   `<div class="tg"><span class="n"><b>${PN[k]||k}</b><small>${v?'authorized: gateway attached, RBAC admits the caller, DNS resolves':'blocked: gateway detached, RBAC empty, DNS NXDOMAIN'}</small></span>
    <button class="sw" aria-pressed="${v}" onclick="setPolicy('${k}',this)"></button></div>`).join('');
 let h='<table>';for(const g of ['b_gateway','c_gateway','b_backend','c_backend']){for(const [k,v] of Object.entries(s.stats[g]||{}))
   h+=`<tr><td>${GN[g]} · ${k.replace(/^http\./,'').replace(/^listener\.0\.0\.0\.0_\d+\./,'')}</td><td>${v}</td></tr>`}
 st.innerHTML=h+'</table>';
 let m='<table>';for(const [k,v] of Object.entries(s.networks))
   m+=`<tr><td>${k.replace('zone-lab-','')}${s.running[k]?'':' <span class="tag bad">DOWN</span>'}</td><td>${v.map(z=>z.replace('zone-lab_','')).join(' · ')||'—'}</td></tr>`;
 nn.innerHTML=m+'</table>';
 stamp.textContent='updated '+new Date().toLocaleTimeString();
}).catch(e=>{stamp.textContent='error: '+e})}
function setPolicy(pair,el){const on=el.getAttribute('aria-pressed')==='true';
 el.disabled=true; stamp.textContent='applying policy (about 10s)…';
 fetch('/api/policy',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({pair:pair,on:!on})}).then(r=>r.json()).then(r=>{
   stamp.textContent='applied: '+((r.steps||[]).length)+' steps';
   load(); loadGraph();
 }).finally(()=>{el.disabled=false})}
const x=document.getElementById('x'),i=document.getElementById('i'),d=document.getElementById('d'),c=document.getElementById('c'),
t=document.getElementById('t'),st=document.getElementById('s'),nn=document.getElementById('n'),
stamp=document.getElementById('stamp'),gstamp=document.getElementById('gstamp'),gnote=document.getElementById('gnote'),dstamp=document.getElementById('dstamp');
let iv=null;document.getElementById('auto').onchange=e=>{clearInterval(iv);if(e.target.checked)iv=setInterval(load,20000)};
load();

const POS={'a-client':[135,140],'a-peer':[135,330],
'b-gateway':[450,140],'b-backend':[450,330],
'c-gateway':[762,140],'c-backend':[762,330]};
const ZBOX=[['Zone A',30,70,210,350],['Zone B',345,70,210,350],['Zone C',660,70,210,350]];
function loadGraph(){
 const lay=document.querySelector('input[name=lay]:checked').value;
 gstamp.textContent='probing…';
 fetch('/api/graph?layer='+lay).then(r=>r.json()).then(g=>{
  const C={both:'var(--ok)',one:'var(--warn)',none:'var(--bad)'};
  let o='<defs>';
  for(const [k,cc] of [['ok','#3fb950'],['warn','#d29922']])
    o+=`<marker id="ar-${k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="${cc}"/></marker>`;
  o+='</defs>';
  for(const [n,x,y,w,h] of ZBOX)
    o+=`<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="none" stroke="var(--line)" stroke-dasharray="4 4"/>
        <text x="${x+w/2}" y="${y-12}" text-anchor="middle" font-size="13" fill="var(--mut)">${n}</text>`;
  let stats={both:0,one:0,none:0};
  for(const e of g.edges){
    if(e.state==='na') continue;
    stats[e.state]++;
    const [x1,y1]=POS[e.a],[x2,y2]=POS[e.b];
    const dash=e.state==='none'?'stroke-dasharray="5 5"':'';
    const op=e.state==='none'?0.35:0.95;
    let mk='';
    if(e.state==='one') mk = e.fwd?`marker-end="url(#ar-warn)"`:`marker-start="url(#ar-warn)"`;
    if(e.state==='both') mk=`marker-start="url(#ar-ok)" marker-end="url(#ar-ok)"`;
    const tt=`${e.a} ${e.state==='both'?'<->':(e.fwd?'->':(e.rev?'<-':'X'))} ${e.b}\n→ ${e.fwd_detail}\n← ${e.rev_detail}`;
    o+=`<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${C[e.state]}" stroke-width="${e.state==='none'?1.5:2.5}" ${dash} ${mk} opacity="${op}"><title>${tt}</title></line>`;
  }
  for(const n of g.nodes){
    const [x,y]=POS[n.id]; const col=n.kind==='gateway'?'#d97706':(n.kind==='client'?'#2563eb':'#7c3aed');
    o+=`<circle cx="${x}" cy="${y}" r="26" fill="var(--card)" stroke="${col}" stroke-width="2.5"/>
        <text x="${x}" y="${y+4}" text-anchor="middle" font-size="10" fill="var(--fg)">${n.label.replace(/^[abc]-/,'')}</text>
        <text x="${x}" y="${y+42}" text-anchor="middle" font-size="10" fill="var(--mut)">${n.label}</text>`;
  }
  document.getElementById('g').innerHTML=o;
  gstamp.textContent=`${new Date().toLocaleTimeString()} · green ${stats.both} · amber ${stats.one} · red ${stats.none}`;
  gnote.innerHTML = lay==='network'
    ? 'Network reachability is <b>symmetric</b>, so this layer never shows a one-way line. "Connection refused" counts as <b>reachable</b> — the packet arrived, unlike "no route".'
    : 'One-way lines belong here: policy is asymmetric. The whole authorized call chain is one-way; the reverse is stopped by RBAC or SAN verification. Hover a line for both results.';
 }).catch(e=>{gstamp.textContent='error: '+e});
}
document.querySelectorAll('input[name=lay]').forEach(r=>r.onchange=loadGraph);
loadGraph();

function loadDns(){
 dstamp.textContent='reading…';
 fetch('/api/dns').then(r=>r.json()).then(d=>{
  let h='';
  for(const [z,recs] of Object.entries(d.zones)){
    h+=`<div><div style="font-size:12px;color:var(--mut);margin-bottom:6px;text-transform:uppercase;letter-spacing:.05em">${z} view</div><table>`;
    for(const r of recs){
      const nx = r.status==='NXDOMAIN';
      const col = nx?'var(--bad)':(r.kind==='gateway'?'var(--warn)':'var(--ok)');
      const tag = nx?'NXDOMAIN':(r.kind==='gateway'?'gateway VIP':'real VIP');
      h+=`<tr><td style="font-family:ui-monospace,Menlo,monospace;font-size:11px">${r.name}</td>
          <td><span style="font-family:ui-monospace,Menlo,monospace">${nx?'—':(r.ip||r.status)}</span>
           <div style="font-size:10px;color:${col}">${nx?'absent → NXDOMAIN':('→ '+r.target+' · '+tag)}</div></td></tr>`;
    }
    h+='</table></div>';
  }
  document.getElementById('dns').innerHTML=h;
  dstamp.textContent='updated '+new Date().toLocaleTimeString();
 }).catch(e=>{dstamp.textContent='error: '+e});
}
loadDns();
</script></body></html>"""


# --------------------------------------------------------------------------- http
class H(BaseHTTPRequestHandler):
    # The panel can reconfigure container networking and join zones, so off
    # loopback it must never be reachable without a token. The token covers the
    # API, not only the page, because the policy endpoint can join zones.
    def _authed(self):
        if not TOKEN:
            return True
        cookie = self.headers.get("Cookie", "") or ""
        for part in cookie.split(";"):
            k, _, v = part.strip().partition("=")
            if k == COOKIE and hmac.compare_digest(v, TOKEN):
                return True
        return False

    def _token_from_query(self):
        q = self.path.split("?", 1)[1] if "?" in self.path else ""
        for part in q.split("&"):
            k, _, v = part.partition("=")
            if k == "t":
                return v
        return None

    def _deny(self):
        self._send(401, "Unauthorized: append ?t=<token> to the URL once.", "text/plain; charset=utf-8")

    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        t = self._token_from_query()
        if TOKEN and t is not None:
            if hmac.compare_digest(t, TOKEN):
                b = INDEX.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Set-Cookie", f"{COOKIE}={TOKEN}; Path=/; SameSite=Strict; HttpOnly")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
                return
            return self._deny()
        if not self._authed():
            return self._deny()
        if self.path.startswith("/api/state"):
            self._send(200, json.dumps(gather()))
        elif self.path.startswith("/api/dns"):
            self._send(200, json.dumps(build_dns()))
        elif self.path.startswith("/api/graph"):
            layer = "identity" if "layer=identity" in self.path else "network"
            self._send(200, json.dumps(build_graph(layer)))
        elif self.path in ("/", "/index.html"):
            self._send(200, INDEX, "text/html; charset=utf-8")
        else:
            self._send(404, "{}")

    def do_POST(self):
        if not self._authed():
            return self._deny()
        if not self.path.startswith("/api/policy"):
            return self._send(404, "{}")
        n = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self._send(400, json.dumps({"ok": False, "detail": "bad json"}))
        pol = load_policy()
        key = req.get("pair", "")
        if key not in DEFAULT_POLICY:
            return self._send(400, json.dumps({"ok": False, "detail": f"unknown pair {key}"}))
        pol[key] = bool(req.get("on"))
        save_policy(pol)
        steps = apply_policy(pol)
        self._send(200, json.dumps({"ok": True, "policy": pol, "steps": steps}))

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8900)
    ap.add_argument("--bind", default="127.0.0.1",
                    help="127.0.0.1 (default, safest) or 0.0.0.0 to reach it from the LAN")
    ap.add_argument("--token", default=None,
                    help="shared token; auto-generated when binding off loopback")
    ap.add_argument("--no-reconcile", action="store_true",
                    help="do not reconcile the saved policy on start (used by the smoke test)")
    a = ap.parse_args()

    global TOKEN
    TOKEN = a.token
    if a.bind != "127.0.0.1" and not TOKEN:
        TOKEN = secrets.token_urlsafe(12)

    if not shutil.which("docker"):
        sys.exit("docker not found on PATH")
    rc, _ = run(["docker", "inspect", C_B_GW, "-f", "{{.State.Running}}"], timeout=10)
    if rc != 0:
        sys.exit(f"{C_B_GW} not found — start the lab first:\n  make lab-up")

    # Reconcile on startup. A `docker compose up` resets every gateway to its
    # compose-declared networks, so the SAVED policy and the ACTUAL state drift
    # apart after a rebuild. Converging here makes the declared policy the truth.
    if not a.no_reconcile:
        pol = load_policy()
        print(f"[policy] reconciling to {pol}", flush=True)
        for st in apply_policy(pol):
            print(f"  {st}", flush=True)

    if a.bind == "127.0.0.1":
        print(f"Zone-lab control panel → http://127.0.0.1:{a.port}")
        if TOKEN:
            print(f"  token: {TOKEN}")
    else:
        lan = os.popen("hostname -I 2>/dev/null | awk '{print $1}'").read().strip()
        host = lan or a.bind
        print(f"WARNING: binding {a.bind} exposes this panel beyond loopback.")
        print("         It can reconfigure container networking, so it is token-protected.")
        print(f"  Open this once:  http://{host}:{a.port}/?t={TOKEN}")
    print("Ctrl-C to stop.")
    ThreadingHTTPServer((a.bind, a.port), H).serve_forever()


if __name__ == "__main__":
    main()
