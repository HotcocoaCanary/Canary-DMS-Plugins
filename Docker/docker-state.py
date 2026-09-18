#!/usr/bin/env python3
"""Docker snapshot for the Docker DMS plugin.

Talks to the Engine API over the unix socket (honours DOCKER_HOST=unix://...)
and prints one JSON object: containers, compose projects, images, networks,
volumes. Read-only; actions are run by the widget through the docker CLI.
"""

import http.client
import json
import os
import socket
import sys


def socket_path():
    host = os.environ.get("DOCKER_HOST", "")
    if host.startswith("unix://"):
        return host[len("unix://"):]
    return "/var/run/docker.sock"


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=10)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def api(conn, path):
    conn.request("GET", path)
    resp = conn.getresponse()
    body = resp.read()
    if resp.status != 200:
        raise RuntimeError("%s -> HTTP %d" % (path, resp.status))
    return json.loads(body)


def split_list(value):
    return [v for v in (value or "").split(",") if v]


def main():
    path = socket_path()
    try:
        conn = UnixHTTPConnection(path)
        version = api(conn, "/version")
        raw_containers = api(conn, "/containers/json?all=1")
        raw_images = api(conn, "/images/json")
        raw_networks = api(conn, "/networks")
        raw_volumes = api(conn, "/volumes").get("Volumes") or []
    except (OSError, RuntimeError, ValueError) as e:
        json.dump({"error": str(e), "socket": path}, sys.stdout)
        return

    containers = []
    projects = {}
    image_use = {}
    network_use = {}
    volume_use = {}

    for c in raw_containers:
        labels = c.get("Labels") or {}
        project = labels.get("com.docker.compose.project", "")
        networks = sorted((c.get("NetworkSettings") or {}).get("Networks") or {})
        volumes = [m.get("Name") for m in c.get("Mounts") or [] if m.get("Type") == "volume" and m.get("Name")]
        ports = []
        seen_ports = set()
        for p in c.get("Ports") or []:
            # IPv4 and IPv6 bindings of the same port show up twice
            key = (p.get("PublicPort"), p.get("PrivatePort"), p.get("Type"))
            if key in seen_ports:
                continue
            seen_ports.add(key)
            ports.append({"public": p.get("PublicPort") or 0, "private": p.get("PrivatePort") or 0, "type": p.get("Type") or "tcp"})
        ports.sort(key=lambda p: (p["public"] == 0, p["private"]))

        status = c.get("Status") or ""
        health = "unhealthy" if "(unhealthy)" in status else "healthy" if "(healthy)" in status else "starting" if "(health: starting)" in status else ""
        item = {
            "id": c["Id"][:12],
            "name": (c.get("Names") or ["/?"])[0].lstrip("/"),
            "image": c.get("Image") or "",
            "state": c.get("State") or "",
            "status": status,
            "health": health,
            "created": c.get("Created") or 0,
            "ports": ports,
            "networks": networks,
            "volumes": volumes,
            "project": project,
            "service": labels.get("com.docker.compose.service", ""),
        }
        containers.append(item)

        image_use[c.get("ImageID")] = image_use.get(c.get("ImageID"), 0) + 1
        for n in networks:
            network_use[n] = network_use.get(n, 0) + 1
        for v in volumes:
            volume_use[v] = volume_use.get(v, 0) + 1

        if project:
            pr = projects.setdefault(project, {
                "name": project,
                "workingDir": labels.get("com.docker.compose.project.working_dir", ""),
                "configFiles": split_list(labels.get("com.docker.compose.project.config_files")),
                "envFiles": split_list(labels.get("com.docker.compose.project.environment_file")),
                "containers": [],
                "networks": [],
                "volumes": [],
            })
            pr["containers"].append(item["id"])

    containers.sort(key=lambda c: (c["project"], c["service"] or c["name"]))

    images = []
    for i in raw_images:
        tags = [t for t in i.get("RepoTags") or [] if t != "<none>:<none>"]
        images.append({
            "id": i["Id"].split(":")[-1][:12],
            "tags": tags,
            "size": i.get("Size") or 0,
            "created": i.get("Created") or 0,
            "containers": image_use.get(i["Id"], 0),
            "dangling": not tags,
        })
    images.sort(key=lambda i: (i["dangling"], (i["tags"] or [""])[0]))

    networks = []
    for n in raw_networks:
        labels = n.get("Labels") or {}
        project = labels.get("com.docker.compose.project", "")
        item = {
            "id": n["Id"][:12],
            "name": n.get("Name") or "",
            "driver": n.get("Driver") or "",
            "scope": n.get("Scope") or "",
            "project": project,
            "containers": network_use.get(n.get("Name"), 0),
            "builtin": n.get("Name") in ("bridge", "host", "none"),
        }
        networks.append(item)
        if project in projects:
            projects[project]["networks"].append(item["name"])
    networks.sort(key=lambda n: (not n["builtin"], n["name"]))

    volumes = []
    for v in raw_volumes:
        labels = v.get("Labels") or {}
        project = labels.get("com.docker.compose.project", "")
        item = {
            "name": v.get("Name") or "",
            "driver": v.get("Driver") or "",
            "mountpoint": v.get("Mountpoint") or "",
            "created": v.get("CreatedAt") or "",
            "project": project,
            "containers": volume_use.get(v.get("Name"), 0),
            # Anonymous volumes get a 64-hex name and no compose label
            "anonymous": len(v.get("Name") or "") == 64 and not project,
        }
        volumes.append(item)
        if project in projects:
            projects[project]["volumes"].append(item["name"])
    volumes.sort(key=lambda v: (v["anonymous"], v["name"]))

    json.dump({
        "version": version.get("Version", ""),
        "containers": containers,
        "projects": sorted(projects.values(), key=lambda p: p["name"]),
        "images": images,
        "networks": networks,
        "volumes": volumes,
    }, sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()
