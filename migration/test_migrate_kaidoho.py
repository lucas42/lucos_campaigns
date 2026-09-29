import http.server
import os
import pty
import select
import shutil
import tempfile
import threading
import time
import unittest
from unittest import mock

import migrate_kaidoho as m


class Gate(http.server.BaseHTTPRequestHandler):
    """Stand-in for the aithne gate + Kanka: 302 unless the session cookie is right, then JSON."""
    log = []
    status = 502
    fails = 0
    mode = "gate"  # "gate": redirect without a good cookie; "html": 200 HTML without one; "open": never gate

    def _serve(self):
        self.log.append((self.command, self.path, self.headers.get("Cookie")))
        if self.path.startswith("/leak"):
            return self._send(200, b"leaked", "text/plain")
        good = "_oauth2_proxy=good" in (self.headers.get("Cookie") or "")
        if self.mode == "flaky":
            Gate.fails -= 1
            if Gate.fails >= 0:
                return self._send(503, b"<html>restarting</html>", "text/html")
        if self.mode == "bad-gateway":
            return self._send(self.status, b"<html>error</html>", "text/html")
        if self.path == "/api/1.0/bad-token":
            return self._send(401, b'{"message":"Unauthenticated."}', "application/json")
        if not good and self.mode != "open":
            if self.mode == "html":
                return self._send(200, b"<html>login</html>", "text/html")
            self.send_response(302)
            self.send_header("Location", "/leak")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send(200, b'{"data": {"id": 1}}', "application/json")

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = _serve

    def log_message(self, *a):
        pass


class GateTest(unittest.TestCase):
    def setUp(self):
        Gate.log = []
        Gate.mode = "gate"
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gate)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)

    def kanka(self, cookie="_oauth2_proxy=good"):
        k = m.KankaApi(self.base, "tok")
        k.s.cookies.set(*cookie.split("=", 1), domain="127.0.0.1")
        return k

    def test_cookie_filter_keeps_only_gate_session_cookies(self):
        got = m.parse_gate_cookies("Cookie: _oauth2_proxy_0=a; _oauth2_proxy_1=b; _oauth2_proxy=c; "
                                   "_oauth2_proxy_csrf=x; kanka_session=y; foo_oauth2_proxy=z")
        self.assertEqual(got, {"_oauth2_proxy_0": "a", "_oauth2_proxy_1": "b", "_oauth2_proxy": "c"})
        self.assertEqual(m.parse_gate_cookies("a=b; c"), {})

    def test_good_cookie_passes(self):
        self.assertEqual(self.kanka().json("GET", "/api/1.0/x"), {"data": {"id": 1}})

    def test_redirect_is_never_followed_and_triggers_reprompt_and_retry(self):
        k = self.kanka("_oauth2_proxy=stale")
        with mock.patch.object(m, "ask", return_value="_oauth2_proxy=good; kanka_session=drop") as ask:
            self.assertEqual(k.json("POST", "/api/1.0/campaigns/1/notes", json={"a": 1}), {"data": {"id": 1}})
        ask.assert_called_once()
        self.assertFalse([e for e in Gate.log if e[1].startswith("/leak")], "the redirect target was fetched")
        self.assertEqual([e[0] for e in Gate.log], ["POST", "POST"])  # the retry is the same call, once
        self.assertNotIn("kanka_session", Gate.log[-1][2])

    def test_non_redirect_html_is_not_expiry_and_is_never_retried(self):
        Gate.mode = "html"
        with mock.patch.object(m, "ask") as ask:
            with self.assertRaises(ValueError):  # 200 HTML: not JSON; and, crucially, no re-prompt or resend
                self.kanka("_oauth2_proxy=stale").json("POST", "/api/1.0/x")
        ask.assert_not_called()
        self.assertEqual([e[0] for e in Gate.log], ["POST"])

    def test_html_errors_from_behind_the_gate_are_errors_not_expiry(self):
        Gate.mode = "bad-gateway"
        for status in (413, 502, 504):
            Gate.status, Gate.log = status, []
            with mock.patch.object(m, "ask") as ask:
                with self.assertRaisesRegex(RuntimeError, str(status)):
                    self.kanka().json("POST", "/api/1.0/x")
            ask.assert_not_called()
            self.assertEqual(len(Gate.log), 1, "the request must not be resent")

    def test_json_error_is_an_error_not_expiry(self):
        with mock.patch.object(m, "ask") as ask:
            with self.assertRaisesRegex(RuntimeError, "401"):
                self.kanka().json("GET", "/api/1.0/bad-token")
        ask.assert_not_called()

    def test_gives_up_when_fresh_cookies_keep_failing(self):
        with mock.patch.object(m, "ask", return_value="_oauth2_proxy=still-bad"):
            with self.assertRaisesRegex(RuntimeError, "still refusing"):
                self.kanka("_oauth2_proxy=stale").json("GET", "/api/1.0/x")

    def test_reprompt_rejects_input_with_no_gate_cookie(self):
        k = self.kanka("_oauth2_proxy=stale")
        with mock.patch.object(m, "ask", side_effect=["kanka_session=x", "_oauth2_proxy=good"]):
            self.assertEqual(k.json("GET", "/api/1.0/x"), {"data": {"id": 1}})

    def test_reads_are_retried_through_a_restart_but_writes_are_not(self):
        Gate.mode, Gate.fails = "flaky", 2
        with mock.patch.object(m, "RETRY_WAITS", (0, 0, 0)):
            self.assertEqual(self.kanka().json("GET", "/api/1.0/x"), {"data": {"id": 1}})
            self.assertEqual(len(Gate.log), 3)
            Gate.log, Gate.fails = [], 2
            with self.assertRaisesRegex(RuntimeError, "503"):
                self.kanka().json("POST", "/api/1.0/x")
            self.assertEqual(len(Gate.log), 1, "a write must not be resent")

    def test_read_gives_up_when_the_server_stays_down(self):
        Gate.mode, Gate.fails = "flaky", 99
        with mock.patch.object(m, "RETRY_WAITS", (0, 0)):
            with self.assertRaisesRegex(RuntimeError, "503"):
                self.kanka().json("GET", "/api/1.0/x")
        self.assertEqual(len(Gate.log), 3)

    def test_non_kanka_redirect_is_an_error(self):
        with self.assertRaisesRegex(RuntimeError, "unexpected redirect"):
            m.Api(self.base, {}).json("GET", "/api/1.0/x")

    def test_preflight_requires_a_gate_redirect_for_cookieless_request(self):
        with mock.patch.object(m, "KANKA_ORIGIN", self.base):
            m.preflight("tok")  # redirected: fine
            Gate.mode = "open"
            with self.assertRaises(SystemExit):
                m.preflight("tok")
        self.assertTrue(all(e[2] is None for e in Gate.log), "the preflight must send no cookie")


class CacheTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.root = os.path.join(self.dir, "c")

    def test_page_is_reused_only_while_updated_at_matches(self):
        c = m.Cache(self.root)
        c.put_page(7, "2026-09-01T10:00:00Z", {"name": "P", "html": "<p>x</p>"})
        self.assertEqual(c.page(7, "2026-09-01T10:00:00Z")["name"], "P")
        self.assertIsNone(c.page(7, "2026-09-02T10:00:00Z"))
        self.assertIsNone(c.page(7, None), "no timestamp from BookStack means no reuse")
        self.assertIsNone(c.page(8, "2026-09-01T10:00:00Z"))

    def test_image_is_fetched_once(self):
        c, calls = m.Cache(self.root), []
        fetch = lambda: calls.append(1) or b"png"  # noqa: E731
        self.assertEqual(c.image("/uploads/a.png", fetch), b"png")
        self.assertEqual(m.Cache(self.root).image("/uploads/a.png", fetch), b"png")
        self.assertEqual(len(calls), 1)

    def test_refresh_discards_the_cache_and_files_are_private(self):
        c = m.Cache(self.root)
        c.put_page(1, "s", {"name": "P"})
        c.image("/uploads/a.png", lambda: b"x")
        for path, mode in ((self.root, 0o700), (os.path.join(self.root, "pages", "1.json"), 0o600)):
            self.assertEqual(os.stat(path).st_mode & 0o777, mode)
        self.assertIsNone(m.Cache(self.root, refresh=True).page(1, "s"))
        self.assertEqual(os.listdir(os.path.join(self.root, "images")), [])

    def test_refresh_leaves_unrelated_files_in_the_cache_dir_alone(self):
        c = m.Cache(self.root)
        c.put_page(1, "s", {"name": "P"})
        keep = os.path.join(self.root, "notes.txt")
        open(keep, "w").write("mine")
        m.Cache(self.root, refresh=True)
        self.assertTrue(os.path.exists(keep))
        self.assertIsNone(m.Cache(self.root).page(1, "s"))

    def test_load_pages_uses_the_cache(self):
        class BS:
            calls = 0
            def json(self, method, path, **kw):
                BS.calls += 1
                if path.startswith("/api/pages/"):
                    return {"id": 1, "name": "N", "slug": "n", "html": "<p>x</p>"}
                return {"data": [{"name": "att.txt"}]}
        c = m.Cache(self.root)
        refs = [("People", {"id": 1, "updated_at": "t1"})]
        first = m.load_pages(BS(), refs, c)
        self.assertEqual(BS.calls, 2)
        self.assertEqual(m.load_pages(BS(), refs, c), first)
        self.assertEqual(BS.calls, 2, "the second run must not call BookStack")
        m.load_pages(BS(), [("People", {"id": 1, "updated_at": "t2"})], c)
        self.assertEqual(BS.calls, 4, "a changed page is downloaded again")


class PromptTest(unittest.TestCase):
    def read_until(self, fd, marker, timeout=10):
        out, deadline = bytearray(), time.time() + timeout
        while marker not in out and time.time() < deadline:
            if select.select([fd], [], [], 0.2)[0]:
                out.extend(os.read(fd, 65536))
        return bytes(out)

    def test_hidden_prompt_accepts_a_line_longer_than_the_canonical_limit(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        secret = "_oauth2_proxy_0=" + "A" * 9000 + "; _oauth2_proxy_1=" + "B" * 3000
        result = []
        with mock.patch.object(m, "TTY_PATH", os.ttyname(slave)):
            t = threading.Thread(target=lambda: result.append(m.ask("Gate cookie")), daemon=True)
            t.start()
            # ask() prints the prompt only once the terminal is in raw mode, so typing now can't be flushed or truncated.
            self.assertIn(b"Gate cookie: ", self.read_until(master, b"Gate cookie: "))
            os.write(master, (secret + "\n").encode())
            shown = self.read_until(master, b"\n")
            t.join(10)
        self.assertFalse(t.is_alive(), "ask() is still blocked")
        self.assertEqual(result, [secret])
        self.assertNotIn(b"AAAA", shown, "the pasted value must not be echoed")


if __name__ == "__main__":
    unittest.main()
