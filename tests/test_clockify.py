import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import clockify  # noqa: E402

KEY = "A" * 48
USER = "a" * 24
WS = "b" * 24
PROJECT = "c" * 24


class TempHome(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        env = {"XDG_CONFIG_HOME": os.path.join(self.tmp.name, "config"),
               "XDG_CACHE_HOME": os.path.join(self.tmp.name, "cache")}
        self.env = mock.patch.dict(os.environ, env)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def write_config(self, data, mode=0o600):
        path = clockify.config_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(data, f)
        os.chmod(path, mode)
        return path


class ConfigTests(TempHome):
    def test_missing_config(self):
        with self.assertRaises(clockify.ClockifyError) as ctx:
            clockify.load_config()
        self.assertEqual(ctx.exception.kind, "config")

    def test_refuses_group_or_world_readable(self):
        for mode in (0o640, 0o604, 0o644):
            self.write_config({"apiKey": KEY}, mode)
            with self.assertRaises(clockify.ClockifyError) as ctx:
                clockify.load_config()
            self.assertIn("chmod 600", ctx.exception.message)
            self.assertNotIn(KEY, ctx.exception.message)

    def test_refuses_symlink(self):
        real = self.write_config({"apiKey": KEY})
        link = real + ".link"
        os.symlink(real, link)
        with self.assertRaises(clockify.ClockifyError):
            clockify.load_config(link)

    def test_validates_fields(self):
        self.write_config({"apiKey": "bad key!"})
        with self.assertRaises(clockify.ClockifyError):
            clockify.load_config()
        self.write_config({"apiKey": KEY, "workspaceId": "../../etc"})
        with self.assertRaises(clockify.ClockifyError):
            clockify.load_config()
        self.write_config({"apiKey": KEY, "region": "evil.example.com"})
        with self.assertRaises(clockify.ClockifyError):
            clockify.load_config()

    def test_loads_valid(self):
        self.write_config({"apiKey": KEY, "workspaceId": WS, "region": "eu"})
        config = clockify.load_config()
        self.assertEqual(config["workspaceId"], WS)
        self.assertEqual(config["region"], "eu")

    def test_private_write_mode(self):
        path = os.path.join(self.tmp.name, "out", "x.json")
        clockify.write_private_json(path, {"a": 1})
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(os.path.dirname(path)).st_mode & 0o777, 0o700)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


class FakeOpener:
    def __init__(self, handler):
        self.handler = handler
        self.requests = []

    def open(self, req, timeout=None):
        self.requests.append(req)
        result = self.handler(req)
        if isinstance(result, Exception):
            raise result
        return FakeResponse(result if isinstance(result, bytes) else json.dumps(result).encode())


def http_error(code):
    return urllib.error.HTTPError("https://x", code, "err", {}, io.BytesIO(b""))


class ApiTests(unittest.TestCase):
    def api(self, handler):
        opener = FakeOpener(handler)
        return clockify.Api({"apiKey": KEY, "region": "global"}, opener), opener

    def test_sends_key_only_to_allowlisted_host(self):
        api, opener = self.api(lambda r: {"id": USER})
        api.request("GET", "/user")
        req = opener.requests[0]
        self.assertTrue(req.full_url.startswith("https://api.clockify.me/api/v1/"))
        self.assertEqual(req.get_header("X-api-key"), KEY)

    def test_errors_never_contain_key(self):
        for code, kind in ((401, "auth"), (403, "auth"), (429, "rate"), (500, "http")):
            api, _ = self.api(lambda r, c=code: http_error(c))
            with self.assertRaises(clockify.ClockifyError) as ctx:
                api.request("GET", "/user")
            self.assertEqual(ctx.exception.kind, kind)
            self.assertNotIn(KEY, ctx.exception.message)
        self.assertNotIn(KEY, repr(api))

    def test_offline(self):
        api, _ = self.api(lambda r: urllib.error.URLError("down"))
        with self.assertRaises(clockify.ClockifyError) as ctx:
            api.request("GET", "/user")
        self.assertEqual(ctx.exception.kind, "offline")

    def test_size_cap(self):
        big = b"[" + b"0," * (clockify.MAX_RESPONSE_BYTES // 2) + b"0]"
        api, _ = self.api(lambda r: big)
        with self.assertRaises(clockify.ClockifyError):
            api.request("GET", "/user")

    def test_malformed_json(self):
        api, _ = self.api(lambda r: b"<html>")
        with self.assertRaises(clockify.ClockifyError):
            api.request("GET", "/user")

    def test_rejection_detail_is_sanitized(self):
        body = json.dumps({"message": "Project is required\u202e<b>x</b>" + "y" * 500}).encode()
        err = urllib.error.HTTPError("https://x", 400, "bad", {}, io.BytesIO(body))
        api, _ = self.api(lambda r: err)
        with self.assertRaises(clockify.ClockifyError) as ctx:
            api.request("PATCH", "/x", {})
        self.assertEqual(ctx.exception.kind, "rejected")
        self.assertTrue(ctx.exception.message.startswith("Project is required<b>"))
        self.assertLessEqual(len(ctx.exception.message), 200)

    def test_404_allowed(self):
        api, _ = self.api(lambda r: http_error(404))
        self.assertIsNone(api.request("PATCH", "/x", {}, allow_404=True))

    def test_redirects_are_refused(self):
        handler = clockify._NoRedirect()
        with self.assertRaises(clockify.ClockifyError):
            handler.redirect_request(None, None, 302, "Found", {}, "https://evil.example.com/")


class SanitizeTests(unittest.TestCase):
    def test_clean_text(self):
        self.assertEqual(clockify.clean_text("a\x00b‮c\nd\te"), "abc d e")
        self.assertEqual(len(clockify.clean_text("x" * 5000)), clockify.MAX_DESCRIPTION)
        self.assertEqual(clockify.clean_text(None), "")

    def test_ids_and_colors(self):
        self.assertEqual(clockify.safe_id(PROJECT), PROJECT)
        self.assertEqual(clockify.safe_id("../" + PROJECT), "")
        self.assertEqual(clockify.safe_color("#03A9F4"), "#03A9F4")
        self.assertEqual(clockify.safe_color("red; x"), "")

    def test_recent_dedupes(self):
        e = lambda d, p: {"id": USER, "description": d, "projectId": p, "timeInterval": {"start": "2026-01-01T00:00:00Z"}}
        out = clockify.recent_view([e("A", PROJECT), e("a", PROJECT), e("B", ""), e("", ""), "junk"])
        self.assertEqual([x["description"] for x in out], ["A", "B"])


class CommandTests(TempHome):
    def setUp(self):
        super().setUp()
        self.write_config({"apiKey": KEY})
        self.calls = []
        self.settings = {}
        self.recent = []
        self.projects_payload = [{"id": PROJECT, "name": "P", "color": "#ff0000"}]

    def handler(self, req):
        self.calls.append((req.get_method(), req.full_url.split("/api/v1", 1)[1], req.data))
        path = self.calls[-1][1]
        if path == "/user":
            return {"id": USER, "activeWorkspace": WS}
        if "in-progress=true" in path:
            return [{"id": USER, "description": "Work", "projectId": PROJECT,
                     "project": {"id": PROJECT, "name": "P", "color": "#ff0000"},
                     "timeInterval": {"start": "2026-01-01T00:00:00Z"}}]
        if path == f"/workspaces/{WS}":
            return {"id": WS, "workspaceSettings": self.settings}
        if "/projects" in path:
            return self.projects_payload
        if req.get_method() == "PATCH":
            return http_error(404)
        if req.get_method() == "POST":
            body = json.loads(req.data)
            return {"id": USER, "description": body["description"], "projectId": body.get("projectId"),
                    "timeInterval": {"start": body["start"]}}
        if "/time-entries" in path:
            return self.recent
        return []

    def run_cmd(self, *argv):
        opener = FakeOpener(self.handler)
        return clockify.run(list(argv), api_factory=lambda c: clockify.Api(c, opener))

    def test_light_status_is_one_request_once_session_cached(self):
        self.run_cmd("status", "--light")
        self.calls.clear()
        out = self.run_cmd("status", "--light")
        self.assertTrue(out["ok"])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(out["running"]["project"]["name"], "P")
        self.assertNotIn("projects", out)

    def test_full_status(self):
        out = self.run_cmd("status")
        self.assertEqual(out["projects"][0]["id"], PROJECT)
        self.assertIn("recent", out)

    def test_start_stops_previous_then_creates(self):
        out = self.run_cmd("start", "Write\x00 code", PROJECT)
        methods = [m for m, _, _ in self.calls if m != "GET"]
        self.assertEqual(methods, ["PATCH", "POST"])
        self.assertEqual(out["running"]["description"], "Write code")
        self.assertEqual(out["running"]["project"]["name"], "P")

    def test_full_status_fetches_in_parallel_and_attaches_projects(self):
        self.recent = [{"id": USER, "description": "Docs", "projectId": PROJECT,
                        "timeInterval": {"start": "2026-01-01T00:00:00Z"}}]
        self.run_cmd("status")  # warm the session cache
        self.calls.clear()
        out = self.run_cmd("status")
        paths = sorted(p.split("?")[0] for _, p, _ in self.calls)
        self.assertEqual(len(paths), 2)  # running + recent; projects and rules are cached
        self.assertEqual(out["recent"][0]["project"]["name"], "P")

    def test_unknown_project_refetches_projects_once(self):
        self.run_cmd("status")  # caches projects without NEW
        new = "d" * 24
        self.projects_payload = [{"id": PROJECT, "name": "P"}, {"id": new, "name": "New one"}]
        self.recent = [{"id": USER, "description": "x", "projectId": new,
                        "timeInterval": {"start": "2026-01-01T00:00:00Z"}}]
        self.calls.clear()
        out = self.run_cmd("status")
        self.assertEqual(sum("/projects" in p for _, p, _ in self.calls), 1)
        self.assertEqual(out["recent"][0]["project"]["name"], "New one")

    def test_cached_returns_snapshot_without_network(self):
        self.assertTrue(self.run_cmd("cached").get("empty"))
        self.run_cmd("status")
        self.calls.clear()
        out = self.run_cmd("cached")
        self.assertEqual(self.calls, [])
        self.assertTrue(out["cached"])
        self.assertEqual(out["projects"][0]["id"], PROJECT)
        self.assertNotIn("running", out)  # never claim a possibly stale timer
        state = os.path.join(clockify.cache_dir(), "state.json")
        self.assertEqual(os.stat(state).st_mode & 0o777, 0o600)
        with open(state) as f:
            self.assertNotIn(KEY, f.read())

    def test_cached_ignores_snapshot_from_other_config(self):
        self.run_cmd("status")
        path = clockify.config_path()
        st = os.stat(path)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 10**9))  # key or account changed
        self.assertTrue(self.run_cmd("cached").get("empty"))

    def test_start_rejects_bad_project(self):
        out = self.run_cmd("start", "x", "1; rm -rf /")
        self.assertFalse(out["ok"])
        self.assertEqual(out["kind"], "input")
        self.assertFalse([c for c in self.calls if c[0] == "POST"])

    def test_start_refuses_what_workspace_requires(self):
        self.settings = {"forceProjects": True, "forceDescription": True}
        out = self.run_cmd("start", "x")
        self.assertEqual((out["kind"], out["error"]), ("input", "This workspace requires a project"))
        out = self.run_cmd("start", "", PROJECT)
        self.assertEqual(out["error"], "This workspace requires a description")
        self.assertFalse([c for c in self.calls if c[0] in ("POST", "PATCH")])
        out = self.run_cmd("start", "x", PROJECT)
        self.assertTrue(out["ok"])

    def test_full_status_reports_rules(self):
        self.settings = {"forceProjects": True}
        out = self.run_cmd("status")
        self.assertEqual(out["rules"], {"projectRequired": True, "descriptionRequired": False})

    def test_stop_without_running_is_ok(self):
        out = self.run_cmd("stop")
        self.assertTrue(out["ok"])
        self.assertIsNone(out["running"])

    def test_internal_errors_are_opaque(self):
        def boom(c):
            raise RuntimeError("secret " + KEY)
        out = clockify.run(["status"], api_factory=boom)
        self.assertEqual(out["kind"], "internal")
        self.assertNotIn(KEY, json.dumps(out))


if __name__ == "__main__":
    unittest.main()
