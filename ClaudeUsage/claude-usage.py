#!/usr/bin/env python3
"""Claude Code usage backend for the Claude Usage DMS plugin.

    claude-usage.py          offline: scan local transcripts, print JSON
    claude-usage.py --sync   also fetch /api/oauth/usage once, then print JSON

Only --sync touches the network. Everything else reads ~/.claude and the
plugin's own cache in $XDG_CACHE_HOME/canary-claude-usage.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

DEFAULT_CLAUDE_DIR = os.path.expanduser("~/.claude")
CLAUDE_DIR = os.path.realpath(
    os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or DEFAULT_CLAUDE_DIR)
)
PROJECTS_DIR = os.path.join(CLAUDE_DIR, "projects")
CREDENTIALS = os.path.join(CLAUDE_DIR, ".credentials.json")

CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "canary-claude-usage"
)
# A non-default config dir is a different account: keep its caches apart.
if CLAUDE_DIR != os.path.realpath(DEFAULT_CLAUDE_DIR):
    CACHE_DIR = os.path.join(CACHE_DIR, "profiles", CLAUDE_DIR.strip("/").replace("/", "_"))
SCAN_CACHE = os.path.join(CACHE_DIR, "scan.json")
USAGE_CACHE = os.path.join(CACHE_DIR, "usage.json")

SCAN_CACHE_VERSION = 2
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"


def write_json_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(tmp, path)


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def parse_ts(ts):
    # Transcript timestamps are UTC ISO-8601; everything is bucketed in local time.
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def scan_file(path):
    """Aggregate one transcript.

    days:     {date: {models: {model: [input, output, cacheRead, cacheWrite, msgs]},
                      hours: {hour: msgs}, s: [sessionIds]}}
    sessions: {sessionId: [firstMs, lastMs, msgs, tokens]}
    """
    days = {}
    sessions = {}
    seen = set()
    version = ""
    last_ts = ""
    with open(path, "rb") as fh:
        for line in fh:
            # Cheap prefilter: most lines are user/tool/meta records.
            if b'"assistant"' not in line or b'"usage"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "assistant":
                continue
            msg = rec.get("message") or {}
            usage = msg.get("usage")
            model = msg.get("model") or "unknown"
            if not usage or model == "<synthetic>":
                continue
            # Streaming writes one line per content block, each carrying the same usage.
            key = (msg.get("id"), rec.get("requestId"))
            if key[0] and key in seen:
                continue
            seen.add(key)

            ts = rec.get("timestamp") or ""
            dt = parse_ts(ts)
            if not dt:
                continue
            counts = [
                usage.get("input_tokens") or 0,
                usage.get("output_tokens") or 0,
                usage.get("cache_read_input_tokens") or 0,
                usage.get("cache_creation_input_tokens") or 0,
            ]
            d = days.setdefault(dt.strftime("%Y-%m-%d"), {"models": {}, "hours": {}, "s": []})
            m = d["models"].setdefault(model, [0, 0, 0, 0, 0])
            for i in range(4):
                m[i] += counts[i]
            m[4] += 1
            hour = str(dt.hour)
            d["hours"][hour] = d["hours"].get(hour, 0) + 1

            sess = rec.get("sessionId")
            if sess:
                if sess not in d["s"]:
                    d["s"].append(sess)
                ms = int(dt.timestamp() * 1000)
                sd = sessions.setdefault(sess, [ms, ms, 0, 0])
                sd[0] = min(sd[0], ms)
                sd[1] = max(sd[1], ms)
                sd[2] += 1
                sd[3] += sum(counts)
            if ts > last_ts:
                last_ts = ts
                version = rec.get("version") or version
    return {"days": days, "sessions": sessions, "version": version, "last": last_ts}


def scan_local():
    tz = time.strftime("%z")
    cache = read_json(SCAN_CACHE, {})
    if cache.get("v") != SCAN_CACHE_VERSION or cache.get("tz") != tz:
        cache = {"v": SCAN_CACHE_VERSION, "tz": tz, "files": {}}
    files = cache["files"]
    changed = False

    for dirpath, _dirs, names in os.walk(PROJECTS_DIR):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            sig = [st.st_size, st.st_mtime_ns]
            entry = files.get(path)
            if entry and entry.get("sig") == sig:
                continue
            try:
                result = scan_file(path)
            except OSError:
                continue
            result["sig"] = sig
            files[path] = result
            changed = True

    # Entries for deleted transcripts are kept on purpose: Claude Code prunes
    # old sessions (cleanupPeriodDays), and this cache is what keeps the history.
    if changed:
        write_json_atomic(SCAN_CACHE, cache)

    days = {}
    sessions = {}
    version = ""
    newest = ""
    for entry in files.values():
        if entry.get("last", "") > newest:
            newest = entry["last"]
            version = entry.get("version") or version
        for day, d in entry["days"].items():
            out = days.setdefault(
                day, {"tokens": 0, "messages": 0, "sessions": set(), "models": {}, "hours": [0] * 24}
            )
            out["sessions"].update(d["s"])
            for model, c in d["models"].items():
                m = out["models"].setdefault(
                    model, {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "messages": 0}
                )
                m["input"] += c[0]
                m["output"] += c[1]
                m["cacheRead"] += c[2]
                m["cacheWrite"] += c[3]
                m["messages"] += c[4]
                out["tokens"] += c[0] + c[1] + c[2] + c[3]
                out["messages"] += c[4]
            for hour, n in d["hours"].items():
                out["hours"][int(hour)] += n
        # Subagent transcripts share their parent's sessionId, so merge by id.
        for sid, sd in entry["sessions"].items():
            cur = sessions.get(sid)
            if cur:
                cur[0] = min(cur[0], sd[0])
                cur[1] = max(cur[1], sd[1])
                cur[2] += sd[2]
                cur[3] += sd[3]
            else:
                sessions[sid] = list(sd)

    for d in days.values():
        d["sessions"] = len(d["sessions"])

    return {
        "days": days,
        "sessions": [
            {"start": s[0], "end": s[1], "messages": s[2], "tokens": s[3]} for s in sessions.values()
        ],
        "claudeVersion": version,
    }


def fetch_usage(claude_version):
    """Call /api/oauth/usage once and cache the result. Returns an error code or ""."""
    creds = read_json(CREDENTIALS, None)
    oauth = (creds or {}).get("claudeAiOauth") or {}
    token = oauth.get("accessToken")
    if not token:
        return "no_credentials"
    expires = oauth.get("expiresAt") or 0
    if expires and expires / 1000 < time.time():
        # Refreshing would rotate Claude Code's own refresh token; leave that to Claude Code.
        return "token_expired"

    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "claude-code/" + (claude_version or "2.1.0"),
            "anthropic-beta": "oauth-2025-04-20",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        return "http_%d" % e.code
    except (urllib.error.URLError, OSError, ValueError):
        return "network"
    if not isinstance(data, dict) or "five_hour" not in data:
        return "bad_response"

    write_json_atomic(
        USAGE_CACHE,
        {
            "fetchedAt": int(time.time() * 1000),
            "subscriptionType": oauth.get("subscriptionType") or "",
            "rateLimitTier": oauth.get("rateLimitTier") or "",
            "data": data,
        },
    )
    return ""


def main():
    out = scan_local()
    if "--sync" in sys.argv[1:]:
        out["syncError"] = fetch_usage(out["claudeVersion"])
    out["usage"] = read_json(USAGE_CACHE, None)
    out["generatedAt"] = int(time.time() * 1000)
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
