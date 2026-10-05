#!/usr/bin/env python3
"""Clockify helper for the omarchy-clockify bar plugin.

Every command prints exactly one JSON object on stdout and exits. The panel
never sees the API key: only this process reads it, from a config file that
must be private to the current user.

Commands:
  status [--light]           running entry; full mode adds projects and recents
  cached                     last full status from disk, no network
  start <description> [pid]  stop whatever runs, then start a new entry
  stop                       stop the running entry (no-op when none)
  setup                      interactive: store and verify an API key
"""

import getpass
import json
import os
import re
import stat
import sys
import tempfile
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.request
from datetime import datetime, timezone

# Fixed allowlist: the key header is only ever sent to one of these hosts.
REGIONS = {
    "global": "https://api.clockify.me/api/v1",
    "eu": "https://euc1.clockify.me/api/v1",
    "us": "https://use2.clockify.me/api/v1",
    "uk": "https://euw2.clockify.me/api/v1",
    "au": "https://apse2.clockify.me/api/v1",
}

TIMEOUT_SEC = 10
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_DESCRIPTION = 3000
PROJECTS_TTL_SEC = 3600
RECENT_FETCH = 30
RECENT_LIMIT = 8
USER_AGENT = "omarchy-clockify/1.0"

ID_RE = re.compile(r"^[0-9a-f]{24}$")
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
KEY_RE = re.compile(r"^[A-Za-z0-9+/=_-]{16,128}$")


class ClockifyError(Exception):
    """An error whose message is safe to show (never contains the key)."""

    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind
        self.message = message


# ---------------------------------------------------------------- paths


def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "omarchy", "clockify.json")


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "omarchy-clockify")


# ---------------------------------------------------------------- config


def load_config(path=None):
    path = path or config_path()
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        raise ClockifyError("config", "Not configured")
    except OSError as e:
        raise ClockifyError("config", f"Cannot open config: {e.strerror}")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ClockifyError("config", "Config is not a regular file")
        if st.st_uid != os.getuid():
            raise ClockifyError("config", "Config is not owned by you")
        if st.st_mode & 0o077:
            raise ClockifyError("config", f"Config is readable by others; run: chmod 600 {path}")
        with os.fdopen(fd, "r", encoding="utf-8") as f:
            fd = None
            raw = f.read(64 * 1024)
    finally:
        if fd is not None:
            os.close(fd)

    try:
        data = json.loads(raw)
    except ValueError:
        raise ClockifyError("config", "Config is not valid JSON")
    if not isinstance(data, dict):
        raise ClockifyError("config", "Config must be a JSON object")

    key = data.get("apiKey")
    if not isinstance(key, str) or not KEY_RE.match(key):
        raise ClockifyError("config", "Config has no valid apiKey")
    workspace = data.get("workspaceId") or ""
    if workspace and (not isinstance(workspace, str) or not ID_RE.match(workspace)):
        raise ClockifyError("config", "Config workspaceId is malformed")
    region = data.get("region") or "global"
    if region not in REGIONS:
        raise ClockifyError("config", "Config region must be one of: " + ", ".join(sorted(REGIONS)))
    return {"apiKey": key, "workspaceId": workspace, "region": region, "mtime": st.st_mtime_ns}


def write_private_json(path, data):
    """Atomically write JSON readable only by the current user."""
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    # mkstemp creates the file 0600; no umask juggling, which would not be
    # thread-safe now that status fetches in parallel.
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".clockify.", suffix=".json.tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------- cache


def cache_read(name, max_age=None):
    path = os.path.join(cache_dir(), name)
    try:
        st = os.stat(path)
        if st.st_uid != os.getuid():
            return None
        if max_age is not None and time.time() - st.st_mtime > max_age:
            return None
        with open(path, "r", encoding="utf-8") as f:
            return json.loads(f.read(MAX_RESPONSE_BYTES))
    except (OSError, ValueError):
        return None


def cache_write(name, data):
    try:
        write_private_json(os.path.join(cache_dir(), name), data)
    except OSError:
        pass  # The cache is an optimization; never fail a command over it.


# ---------------------------------------------------------------- http


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ClockifyError("http", f"Unexpected redirect ({code})")


_OPENER = urllib.request.build_opener(_NoRedirect())


def _error_detail(err):
    """Clockify's own explanation for a rejected request, sanitized."""
    try:
        body = json.loads(err.read(4096) or b"null")
    except (OSError, ValueError):
        return ""
    message = body.get("message") if isinstance(body, dict) else None
    return clean_text(message, 200)


class Api:
    def __init__(self, config, opener=None):
        self._key = config["apiKey"]
        self._base = REGIONS[config["region"]]
        self._opener = opener or _OPENER

    def __repr__(self):
        return f"Api(base={self._base!r})"

    def request(self, method, path, body=None, allow_404=False):
        data = None
        headers = {"X-Api-Key": self._key, "Accept": "application/json", "User-Agent": USER_AGENT}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self._base + path, data=data, headers=headers, method=method)
        try:
            with self._opener.open(req, timeout=TIMEOUT_SEC) as resp:
                raw = resp.read(MAX_RESPONSE_BYTES + 1)
        except ClockifyError:
            raise
        except urllib.error.HTTPError as e:
            detail = _error_detail(e)
            e.close()
            if e.code == 404 and allow_404:
                return None
            if e.code in (401, 403):
                raise ClockifyError("auth", "Clockify rejected the API key")
            if e.code == 429:
                raise ClockifyError("rate", "Rate limited by Clockify")
            if e.code in (400, 422) and detail:
                raise ClockifyError("rejected", detail)
            raise ClockifyError("http", f"Clockify returned HTTP {e.code}")
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
            raise ClockifyError("offline", "Cannot reach Clockify")

        if len(raw) > MAX_RESPONSE_BYTES:
            raise ClockifyError("http", "Response too large")
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            raise ClockifyError("http", "Malformed response from Clockify")


# ---------------------------------------------------------------- helpers


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clean_text(value, limit=MAX_DESCRIPTION):
    """Drop control/format characters and collapse whitespace."""
    if not isinstance(value, str):
        return ""
    kept = []
    for ch in value:
        cat = unicodedata.category(ch)
        if cat in ("Cc", "Cf", "Cs", "Co", "Cn"):
            kept.append(" " if ch in "\t\n\r" else "")
        else:
            kept.append(ch)
    return " ".join("".join(kept).split())[:limit]


def safe_id(value):
    return value if isinstance(value, str) and ID_RE.match(value) else ""


def safe_color(value):
    return value if isinstance(value, str) and COLOR_RE.match(value) else ""


def project_view(project):
    if not isinstance(project, dict):
        return None
    pid = safe_id(project.get("id"))
    if not pid:
        return None
    return {
        "id": pid,
        "name": clean_text(project.get("name"), 200),
        "client": clean_text(project.get("clientName"), 200),
        "color": safe_color(project.get("color")),
    }


def entry_view(entry):
    if not isinstance(entry, dict):
        return None
    interval = entry.get("timeInterval") or {}
    start = interval.get("start") if isinstance(interval, dict) else None
    if not isinstance(start, str) or len(start) > 40:
        return None
    project = project_view(entry.get("project")) if isinstance(entry.get("project"), dict) else None
    project_id = safe_id(entry.get("projectId"))
    return {
        "id": safe_id(entry.get("id")),
        "description": clean_text(entry.get("description")),
        "projectId": project_id,
        "project": project if project and project["id"] == project_id else None,
        "start": start,
    }


def attach_projects(entries, project_list):
    """Fill in project details from the project list (recents are fetched unhydrated)."""
    by_id = {p["id"]: p for p in project_list}
    for entry in entries:
        if entry and entry["projectId"] and not entry["project"]:
            entry["project"] = by_id.get(entry["projectId"])
    return entries


def recent_view(entries):
    seen = set()
    out = []
    for raw in entries if isinstance(entries, list) else []:
        entry = entry_view(raw)
        if not entry:
            continue
        key = (entry["description"].lower(), entry["projectId"])
        if key in seen or key == ("", ""):
            continue
        seen.add(key)
        out.append(entry)
        if len(out) >= RECENT_LIMIT:
            break
    return out


# ---------------------------------------------------------------- session


def session(config, api):
    """Return (userId, workspaceId), cached per config revision."""
    cached = cache_read("session.json")
    if (
        isinstance(cached, dict)
        and cached.get("mtime") == config["mtime"]
        and safe_id(cached.get("userId"))
        and safe_id(cached.get("workspaceId"))
    ):
        return cached["userId"], cached["workspaceId"]

    user = api.request("GET", "/user")
    if not isinstance(user, dict):
        raise ClockifyError("http", "Malformed user response")
    user_id = safe_id(user.get("id"))
    workspace = config["workspaceId"] or safe_id(user.get("activeWorkspace")) or safe_id(user.get("defaultWorkspace"))
    if not user_id or not workspace:
        raise ClockifyError("http", "Clockify did not return a user or workspace")
    cache_write("session.json", {"mtime": config["mtime"], "userId": user_id, "workspaceId": workspace})
    return user_id, workspace


def running_entry(api, user_id, workspace):
    entries = api.request(
        "GET",
        f"/workspaces/{workspace}/user/{user_id}/time-entries?in-progress=true&hydrated=true&page-size=1",
    )
    if isinstance(entries, list) and entries:
        return entry_view(entries[0])
    return None


def projects(api, workspace, fresh=False):
    cached = None if fresh else cache_read("projects.json", PROJECTS_TTL_SEC)
    if isinstance(cached, dict) and cached.get("workspaceId") == workspace and isinstance(cached.get("projects"), list):
        return cached["projects"]
    raw = api.request("GET", f"/workspaces/{workspace}/projects?archived=false&page-size=500&sort-column=NAME")
    out = [p for p in (project_view(p) for p in (raw if isinstance(raw, list) else [])) if p]
    cache_write("projects.json", {"workspaceId": workspace, "projects": out})
    return out


def workspace_rules(api, workspace):
    """Fields the workspace insists on; Clockify refuses to stop entries without them."""
    cached = cache_read("rules.json", PROJECTS_TTL_SEC)
    if isinstance(cached, dict) and cached.get("workspaceId") == workspace and isinstance(cached.get("rules"), dict):
        return cached["rules"]
    raw = api.request("GET", f"/workspaces/{workspace}")
    settings = raw.get("workspaceSettings") if isinstance(raw, dict) else None
    settings = settings if isinstance(settings, dict) else {}
    rules = {
        "projectRequired": settings.get("forceProjects") is True,
        "descriptionRequired": settings.get("forceDescription") is True,
    }
    cache_write("rules.json", {"workspaceId": workspace, "rules": rules})
    return rules


# ---------------------------------------------------------------- commands


def cmd_status(api, config, light):
    user_id, workspace = session(config, api)
    if light:
        return {"ok": True, "running": running_entry(api, user_id, workspace)}

    # Every call is a full round trip to Clockify, so issue them together:
    # the wait is the slowest request instead of the sum of all of them.
    with ThreadPoolExecutor(max_workers=4) as pool:
        running_f = pool.submit(running_entry, api, user_id, workspace)
        recent_f = pool.submit(
            api.request, "GET", f"/workspaces/{workspace}/user/{user_id}/time-entries?page-size={RECENT_FETCH}"
        )
        projects_f = pool.submit(projects, api, workspace)
        rules_f = pool.submit(workspace_rules, api, workspace)
        running, recent_raw = running_f.result(), recent_f.result()
        project_list, rules = projects_f.result(), rules_f.result()

    recent = recent_view(recent_raw)
    known = {p["id"] for p in project_list}
    if any(e["projectId"] and e["projectId"] not in known for e in recent):
        project_list = projects(api, workspace, fresh=True)  # a project newer than the cache
    attach_projects(recent, project_list)

    result = {"ok": True, "running": running, "recent": recent, "projects": project_list, "rules": rules}
    cache_write("state.json", dict(result, configMtime=config["mtime"], savedAt=int(time.time())))
    return result


def cmd_cached(config):
    """The last full status, without touching the network.

    Tied to the config revision so another account's data is never shown.
    The running entry is left out: it may be stale, and the bar must not
    claim a timer that is no longer running.
    """
    state = cache_read("state.json")
    if not isinstance(state, dict) or state.get("configMtime") != config["mtime"]:
        return {"ok": True, "empty": True}
    out = {"ok": True, "cached": True, "savedAt": state.get("savedAt")}
    for key, kind in (("recent", list), ("projects", list), ("rules", dict)):
        if isinstance(state.get(key), kind):
            out[key] = state[key]
    return out


def cmd_start(api, config, description, project_id):
    description = clean_text(description)
    if project_id and not ID_RE.match(project_id):
        raise ClockifyError("input", "Invalid project id")
    user_id, workspace = session(config, api)
    # Refuse up front what Clockify would only reject at stop time, so we
    # never leave behind a timer that cannot be stopped.
    rules = workspace_rules(api, workspace)
    if rules["projectRequired"] and not project_id:
        raise ClockifyError("input", "This workspace requires a project")
    if rules["descriptionRequired"] and not description:
        raise ClockifyError("input", "This workspace requires a description")
    stamp = now_iso()
    # Close the running entry at the same instant the new one starts so the
    # two never overlap, whatever the server's own switching behavior is.
    api.request("PATCH", f"/workspaces/{workspace}/user/{user_id}/time-entries", {"end": stamp}, allow_404=True)
    body = {"start": stamp, "description": description}
    if project_id:
        body["projectId"] = project_id
    created = api.request("POST", f"/workspaces/{workspace}/time-entries", body)
    entry = entry_view(created)
    if entry and entry["projectId"] and not entry["project"]:
        for project in projects(api, workspace):
            if project["id"] == entry["projectId"]:
                entry["project"] = project
                break
    return {"ok": True, "running": entry}


def cmd_stop(api, config):
    user_id, workspace = session(config, api)
    api.request("PATCH", f"/workspaces/{workspace}/user/{user_id}/time-entries", {"end": now_iso()}, allow_404=True)
    return {"ok": True, "running": None}


def cmd_setup():
    if not sys.stdin.isatty():
        print("setup must be run in a terminal", file=sys.stderr)
        return 2
    print("Clockify API key: create one at https://app.clockify.me/manage-api-keys")
    print("(Profile settings -> API). Input is hidden.\n")
    key = getpass.getpass("API key: ").strip()
    if not KEY_RE.match(key):
        print("That does not look like a Clockify API key.", file=sys.stderr)
        return 1
    region = input("Region [global/eu/us/uk/au] (default global): ").strip().lower() or "global"
    if region not in REGIONS:
        print("Unknown region.", file=sys.stderr)
        return 1

    api = Api({"apiKey": key, "region": region})
    try:
        user = api.request("GET", "/user")
        workspaces = api.request("GET", "/workspaces")
    except ClockifyError as e:
        print(f"Could not verify the key: {e.message}", file=sys.stderr)
        return 1

    choices = [w for w in (workspaces if isinstance(workspaces, list) else []) if safe_id(w.get("id"))]
    workspace = safe_id(user.get("activeWorkspace")) if isinstance(user, dict) else ""
    if len(choices) > 1:
        print("\nWorkspaces:")
        for i, w in enumerate(choices, 1):
            mark = " (active)" if w["id"] == workspace else ""
            print(f"  {i}. {clean_text(w.get('name'), 80)}{mark}")
        pick = input("Pick a workspace number (Enter keeps the active one): ").strip()
        if pick:
            if not pick.isdigit() or not 1 <= int(pick) <= len(choices):
                print("Invalid choice.", file=sys.stderr)
                return 1
            workspace = choices[int(pick) - 1]["id"]
    elif choices:
        workspace = choices[0]["id"]

    path = config_path()
    write_private_json(path, {"apiKey": key, "workspaceId": workspace, "region": region})
    name = clean_text(user.get("name"), 80) if isinstance(user, dict) else ""
    print(f"\nSaved to {path} (mode 600). Signed in as {name or 'unknown user'}.")
    return 0


def run(argv, config_loader=load_config, api_factory=Api):
    if not argv or argv[0] in ("-h", "--help"):
        return {"ok": False, "kind": "usage", "error": "usage: clockify.py status|cached|start|stop|setup"}
    command, args = argv[0], argv[1:]
    try:
        config = config_loader()
        if command == "cached":
            return cmd_cached(config)
        api = api_factory(config)
        if command == "status":
            return cmd_status(api, config, light="--light" in args)
        if command == "start":
            if not args or len(args) > 2:
                raise ClockifyError("usage", "usage: clockify.py start <description> [projectId]")
            return cmd_start(api, config, args[0], args[1] if len(args) > 1 else "")
        if command == "stop":
            return cmd_stop(api, config)
        raise ClockifyError("usage", f"Unknown command: {clean_text(command, 40)}")
    except ClockifyError as e:
        return {"ok": False, "kind": e.kind, "error": e.message}
    except Exception:
        # Never echo internals: a traceback could carry request details.
        return {"ok": False, "kind": "internal", "error": "Unexpected error"}


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["setup"]:
        try:
            return cmd_setup()
        except (KeyboardInterrupt, EOFError):
            print("\nCancelled.", file=sys.stderr)
            return 130
    sys.stdout.write(json.dumps(run(argv), ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
