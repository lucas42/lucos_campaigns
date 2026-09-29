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
	expect "GET /_info is ungated (404 until the endpoint ships)" '200|404' "$(status "$BASE/_info")"
	expect "GET /oauth2/auth is not externally reachable" 404 "$(status "$BASE/oauth2/auth")"
	expect "uploaded-style .php is never executed" 404 "$(status "$BASE/storage/a.php")"
	;;
sidecar-down)
	for p in / /api/1.0/campaigns /register; do
		expect "GET $p fails closed with the sidecar down" '5[0-9][0-9]' "$(status "$BASE$p")"
	done
	expect "POST /register fails closed with the sidecar down" '5[0-9][0-9]' "$(status -X POST -d x=1 "$BASE/register")"
	;;
*)
	echo "unknown phase" >&2; exit 2 ;;
esac
exit $fail
