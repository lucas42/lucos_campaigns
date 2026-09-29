import http.server
import threading
import unittest
from unittest import mock

import migrate_kaidoho as m


class Gate(http.server.BaseHTTPRequestHandler):
    """Stand-in for the aithne gate + Kanka: 302 unless the session cookie is right, then JSON."""
    log = []
    mode = "gate"  # "gate": redirect without a good cookie; "html": 200 HTML without one; "open": never gate

    def _serve(self):
        self.log.append((self.command, self.path, self.headers.get("Cookie")))
        if self.path.startswith("/leak"):
            return self._send(200, b"leaked", "text/plain")
        good = "_oauth2_proxy=good" in (self.headers.get("Cookie") or "")
        if self.mode == "bad-gateway":
            return self._send(502, b"<html>bad gateway</html>", "text/html")
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

    def test_post_gate_5xx_is_an_error_not_expiry(self):
        Gate.mode = "bad-gateway"
        with mock.patch.object(m, "ask") as ask:
            with self.assertRaisesRegex(RuntimeError, "502"):
                self.kanka().json("POST", "/api/1.0/x")
        ask.assert_not_called()
        self.assertEqual(len(Gate.log), 1)

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


if __name__ == "__main__":
    unittest.main()
