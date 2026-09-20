#!/usr/bin/env python3
"""Tailscale state for the Tailscale DMS plugin.

Without arguments: talks to tailscaled's LocalAPI over the unix socket (honours
TS_SOCKET) and prints one JSON object with the backend state, this device, the
peers and the preferences. Needs no privileges.

With "netcheck": runs "tailscale netcheck" and pairs its per-region latencies
with the region names from the DERP map.
"""

import http.client
import json
import os
import socket
import subprocess
import sys

SOCKETS = ("/var/run/tailscale/tailscaled.sock", "/run/tailscale/tailscaled.sock")
ZERO_TIME = "0001-01-01T00:00:00Z"


def socket_path():
    env = os.environ.get("TS_SOCKET", "")
    if env:
        return env
    for path in SOCKETS:
        if os.path.exists(path):
            return path
    return SOCKETS[0]


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        # tailscaled checks the Host header, the name is not resolved
        super().__init__("local-tailscaled.sock", timeout=10)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def api(conn, path):
    conn.request("GET", path, headers={"Host": "local-tailscaled.sock", "Sec-Tailscale": "localapi"})
    resp = conn.getresponse()
    body = resp.read()
    if resp.status != 200:
        raise RuntimeError("%s -> HTTP %d" % (path, resp.status))
    return json.loads(body)


def clean_time(value):
    if not value or value == ZERO_TIME:
        return ""
    return value


def node(raw, users, suffix, self_id):
    dns = (raw.get("DNSName") or "").rstrip(".")
    short = dns
    if suffix and dns.endswith("." + suffix):
        short = dns[: -(len(suffix) + 1)]
    ips = raw.get("TailscaleIPs") or []
    ipv4 = next((ip for ip in ips if ":" not in ip), ips[0] if ips else "")
    user = users.get(str(raw.get("UserID") or 0)) or {}
    tags = raw.get("Tags") or []
    return {
        "id": raw.get("ID") or "",
        "name": raw.get("HostName") or short or ipv4,
        "short": short,
        "fqdn": dns,
        "os": raw.get("OS") or "",
        "ips": ips,
        "ip": ipv4,
        "self": (raw.get("ID") or "") == self_id,
        "online": bool(raw.get("Online")),
        "active": bool(raw.get("Active")),
        "expired": bool(raw.get("Expired")),
        "exitNode": bool(raw.get("ExitNode")),
        "exitNodeOption": bool(raw.get("ExitNodeOption")),
        "relay": raw.get("Relay") or "",
        "curAddr": raw.get("CurAddr") or "",
        "rx": raw.get("RxBytes") or 0,
        "tx": raw.get("TxBytes") or 0,
        "lastSeen": clean_time(raw.get("LastSeen")),
        "lastHandshake": clean_time(raw.get("LastHandshake")),
        "created": clean_time(raw.get("Created")),
        "keyExpiry": clean_time(raw.get("KeyExpiry")),
        "routes": raw.get("PrimaryRoutes") or [],
        "tags": tags,
        "tagged": bool(tags),
        "shared": bool(raw.get("ShareeNode")),
        "userId": str(raw.get("UserID") or 0),
        "user": user.get("DisplayName") or user.get("LoginName") or "",
        "userLogin": user.get("LoginName") or "",
    }


def main():
    path = socket_path()
    try:
        conn = UnixHTTPConnection(path)
        status = api(conn, "/localapi/v0/status")
        conn = UnixHTTPConnection(path)
        prefs = api(conn, "/localapi/v0/prefs")
    except (OSError, RuntimeError, ValueError) as e:
        json.dump({"error": str(e), "socket": path}, sys.stdout)
        return

    users = status.get("User") or {}
    tailnet = status.get("CurrentTailnet") or {}
    suffix = status.get("MagicDNSSuffix") or ""
    raw_self = status.get("Self") or {}
    self_id = raw_self.get("ID") or ""

    me = node(raw_self, users, suffix, self_id) if raw_self else None
    peers = [node(p, users, suffix, self_id) for p in (status.get("Peer") or {}).values()]
    peers.sort(key=lambda p: (not p["online"], p["name"].lower()))

    routes = prefs.get("AdvertiseRoutes") or []
    exit_routes = {"0.0.0.0/0", "::/0"}

    health = status.get("Health") or []
    client = status.get("ClientVersion") or {}

    json.dump({
        "version": status.get("Version", ""),
        "backendState": status.get("BackendState", ""),
        "tun": bool(status.get("TUN")),
        "authURL": status.get("AuthURL") or "",
        "health": [h for h in health if isinstance(h, str)],
        "tailnet": tailnet.get("Name") or "",
        "magicDNSSuffix": suffix,
        "magicDNS": bool(tailnet.get("MagicDNSEnabled")),
        "self": me,
        "peers": peers,
        "clientVersion": {
            "runningLatest": bool(client.get("RunningLatest")),
            "latest": client.get("LatestVersion") or "",
            "urgent": bool(client.get("UrgentSecurityUpdate")),
        },
        "prefs": {
            "wantRunning": bool(prefs.get("WantRunning")),
            "loggedOut": bool(prefs.get("LoggedOut")),
            "acceptRoutes": bool(prefs.get("RouteAll")),
            "acceptDNS": bool(prefs.get("CorpDNS")),
            "shieldsUp": bool(prefs.get("ShieldsUp")),
            "runSSH": bool(prefs.get("RunSSH")),
            "webClient": bool(prefs.get("RunWebClient")),
            "allowLANAccess": bool(prefs.get("ExitNodeAllowLANAccess")),
            "exitNodeID": prefs.get("ExitNodeID") or "",
            "exitNodeIP": prefs.get("ExitNodeIP") or "",
            "advertiseRoutes": [r for r in routes if r not in exit_routes],
            "advertiseExitNode": exit_routes.issubset(set(routes)),
            "hostname": prefs.get("Hostname") or "",
            "controlURL": prefs.get("ControlURL") or "",
        },
    }, sys.stdout, separators=(",", ":"))


def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=60)


def netcheck():
    """Latency per DERP region, with the names from the DERP map."""
    try:
        report = run(["tailscale", "netcheck", "--format=json"])
        if report.returncode != 0:
            raise RuntimeError(report.stderr.strip().splitlines()[-1] if report.stderr.strip() else "netcheck failed")
        data = json.loads(report.stdout)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as e:
        json.dump({"error": str(e)}, sys.stdout)
        return

    names = {}
    try:
        derp = json.loads(run(["tailscale", "debug", "derp-map"]).stdout)
        for rid, region in (derp.get("Regions") or {}).items():
            names[str(rid)] = {
                "code": region.get("RegionCode") or rid,
                "name": region.get("RegionName") or region.get("RegionCode") or rid,
            }
    except (OSError, ValueError, subprocess.SubprocessError):
        pass

    preferred = str(data.get("PreferredDERP") or "")
    latency = data.get("RegionLatency") or {}
    v4 = data.get("RegionV4Latency") or {}
    v6 = data.get("RegionV6Latency") or {}
    regions = []
    for rid, ns in latency.items():
        if not ns:
            continue
        region = names.get(str(rid)) or {"code": str(rid), "name": str(rid)}
        regions.append({
            "id": str(rid),
            "code": region["code"],
            "name": region["name"],
            "ms": round(ns / 1e6, 1),
            "v4": round(v4[rid] / 1e6, 1) if v4.get(rid) else 0,
            "v6": round(v6[rid] / 1e6, 1) if v6.get(rid) else 0,
            "preferred": str(rid) == preferred,
        })
    regions.sort(key=lambda r: r["ms"])

    json.dump({
        "at": data.get("Now") or "",
        "preferred": preferred,
        "regions": regions,
        "checks": {
            "udp": bool(data.get("UDP")),
            "ipv4": bool(data.get("IPv4")),
            "ipv6": bool(data.get("IPv6")),
            "upnp": bool(data.get("UPnP")),
            "pmp": bool(data.get("PMP")),
            "pcp": bool(data.get("PCP")),
            "hairpinning": bool(data.get("HairPinning")),
            "easyNAT": not bool(data.get("MappingVariesByDestIP")),
            "captivePortal": bool(data.get("CaptivePortal")),
        },
    }, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "netcheck":
        netcheck()
    else:
        main()
