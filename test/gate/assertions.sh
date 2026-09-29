#!/bin/sh
# Usage: assertions.sh up|sidecar-down. Unauthenticated requests only: nothing here can ever be logged in.
BASE=http://app:8080
fail=0
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
expect() { # description, expected-code-regex, actual
	if echo "$3" | grep -Eq "^($2)\$"; then echo "ok   - $1 ($3)"; else echo "FAIL - $1: got $3, wanted $2"; fail=1; fi
}

case "$1" in
up)
	for p in / /login /register /api/1.0/campaigns /storage/a.png /index.php /favicon.ico/x; do
		expect "GET $p is redirected to the login flow" 302 "$(status "$BASE$p")"
	done
	expect "POST /register is redirected to the login flow" 302 "$(status -X POST -d x=1 "$BASE/register")"
	expect "POST /api/1.0/campaigns is redirected to the login flow" 302 "$(status -X POST "$BASE/api/1.0/campaigns")"
	expect "redirect points at the OIDC login URL" 1 "$(curl -s -o /dev/null -D - "$BASE/" | grep -ci '^location: http://aithne.invalid/oauth2/authorize')"
	expect "GET /favicon.ico is served ungated" 200 "$(status "$BASE/favicon.ico")"
	expect "GET /_info is ungated" 200 "$(status "$BASE/_info")"
	info=$(curl -s --max-time 15 "$BASE/_info")
	expect "/_info is JSON with object checks and metrics" true "$(echo "$info" | jq '(.checks|type)=="object" and (.metrics|type)=="object" and .system=="lucos_campaigns"')"
	expect "/_info auth-gate check passes with the sidecar up" true "$(echo "$info" | jq '.checks["auth-gate"].ok')"
	expect "/_info reports the app as failed (no Kanka in the stub), still HTTP 200" false "$(echo "$info" | jq '.checks.app.ok')"
	expect "/_info exposes only an exception class" RuntimeException "$(echo "$info" | jq -r '.checks.app.debug')"
	expect "/_info database and search are not checked when the app fails" 2 "$(echo "$info" | jq '[.checks.database, .checks.search | select(.ok==false and .debug=="not checked: app failed to boot")] | length')"
	expect "/_info ignores a Host header" true "$(curl -s --max-time 15 -H 'Host: evil.invalid' "$BASE/_info" | jq '.checks["auth-gate"].ok')"
	for p in /_info/ /_info.php/x /_info/x; do
		expect "GET $p is gated" 302 "$(status "$BASE$p")"
	done
	expect "GET /_info.php is not served" '302|404' "$(status "$BASE/_info.php")"
	expect "GET /_info.php body is not the endpoint" 0 "$(curl -s --max-time 15 "$BASE/_info.php" | grep -c '"checks"')"
	if nc -z -w 3 app 9000; then echo "FAIL - PHP-FPM is reachable from a sibling container on :9000"; fail=1; else echo "ok   - PHP-FPM is not reachable from a sibling container on :9000"; fi
	limited=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ "$(status "$BASE/_info")" = 429 ] && limited=1; done
	expect "GET /_info is rate limited under a burst" 1 "$limited"
	expect "GET /oauth2/auth is not externally reachable" 404 "$(status "$BASE/oauth2/auth")"
	expect "uploaded-style .php is never executed" 404 "$(status "$BASE/storage/a.php")"
	;;
sidecar-down)
	for p in / /api/1.0/campaigns /register; do
		expect "GET $p fails closed with the sidecar down" '5[0-9][0-9]' "$(status "$BASE$p")"
	done
	expect "POST /register fails closed with the sidecar down" '5[0-9][0-9]' "$(status -X POST -d x=1 "$BASE/register")"
	expect "GET /_info still answers 200 with the sidecar down" 200 "$(status "$BASE/_info")"
	expect "/_info auth-gate check fails with the sidecar down" false "$(curl -s --max-time 15 "$BASE/_info" | jq '.checks["auth-gate"].ok')"
	;;
*)
	echo "unknown phase" >&2; exit 2 ;;
esac
exit $fail
