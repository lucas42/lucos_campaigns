#!/bin/sh
# Usage: assertions.sh up|search-down. Runs against the real Kanka image, unauthenticated only.
BASE=http://lucos_campaigns_app:8080
fail=0
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
expect() { # description, expected-code-regex, actual
	if echo "$3" | grep -Eq "^($2)\$"; then echo "ok   - $1 ($3)"; else echo "FAIL - $1: got $3, wanted $2"; fail=1; fi
}
info() { curl -s --max-time 15 "$BASE/_info"; }

case "$1" in
up)
	body=$(info)
	expect "GET /_info is ungated" 200 "$(status "$BASE/_info")"
	expect "/_info checks and metrics are objects" true "$(echo "$body" | jq '(.checks|type)=="object" and (.metrics|type)=="object"')"
	for c in app database search auth-gate; do
		expect "/_info check $c passes" true "$(echo "$body" | jq --arg c "$c" '.checks[$c].ok')"
	done
	for p in / /api/health; do
		expect "GET $p is not served unauthenticated" '30[0-9]|4[0-9][0-9]' "$(status "$BASE$p")"
	done
	;;
search-down)
	sleep 4 # drain the /_info rate limiter (2r/s)
	expect "GET /_info still answers 200 with search down" 200 "$(status "$BASE/_info")"
	body=$(info)
	expect "/_info search check fails with search down" false "$(echo "$body" | jq '.checks.search.ok')"
	expect "/_info database check is unaffected" true "$(echo "$body" | jq '.checks.database.ok')"
	;;
*)
	echo "unknown phase" >&2; exit 2 ;;
esac
exit $fail
