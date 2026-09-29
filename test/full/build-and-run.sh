#!/bin/sh
# Full stack from the real image (no bind mounts: the CI docker daemon is remote), then /_info assertions.
set -u
cd "$(dirname "$0")/../.."
export PORT=8080 APP_ORIGIN=http://localhost:8080 SYSTEM=lucos_campaigns \
	APP_KEY="base64:$(head -c 32 /dev/urandom | base64)" DB_PASSWORD=test DB_ROOT_PASSWORD=test \
	MEILI_MASTER_KEY=test-master-key-0123456789 KEY_LUCOS_AITHNE=dummy \
	OAUTH2_PROXY_COOKIE_SECRET=0123456789abcdef0123456789abcdef AITHNE_ORIGIN=http://aithne.invalid
C="docker compose -p campaigns-full -f docker-compose.yml -f test/full/docker-compose.yml"
cleanup() { $C down -v --remove-orphans; }
$C build && $C up -d lucos_campaigns_app || { $C logs; cleanup; exit 1; }
# First start migrates, seeds and indexes, so wait for every check to pass rather than for nginx.
$C run --rm --entrypoint sh client -c 'for i in $(seq 1 90); do curl -s --max-time 5 http://lucos_campaigns_app:8080/_info | jq -e "[.checks[].ok] | all" >/dev/null && exit 0; sleep 5; done; curl -s http://lucos_campaigns_app:8080/_info; exit 1' || { $C logs; cleanup; exit 1; }
rc=0
$C run --rm client up || rc=1
# Kanka's config/mail.php reads the legacy MAIL_DRIVER (default smtp), not MAIL_MAILER: assert what the app really resolves.
mail=$($C exec -T lucos_campaigns_app php artisan config:show mail.driver 2>/dev/null | awk 'NF {v=$NF} END {print v}')
if [ "$mail" = log ]; then echo "ok   - mail.driver resolves to log, so no mail is sent"; else echo "FAIL - mail.driver resolves to '$mail', wanted log"; rc=1; fi
# A wrong-shaped APP_KEY must stop the real image at start, with a message naming APP_KEY and never the key.
# Plain `docker run` of the built image (no deps, volumes or compose service): `compose run` hung on the CI engine.
image=$($C config --images | grep '/lucos_campaigns_app:')
appkey_run() { # key value (or UNSET), then the rest of the docker run arguments
	key=$1; shift
	docker rm -f campaigns-appkey-test >/dev/null 2>&1
	if [ "$key" = UNSET ]; then timeout 90 docker run --rm --name campaigns-appkey-test "$@" </dev/null 2>&1
	else timeout 90 docker run --rm --name campaigns-appkey-test -e "APP_KEY=$key" "$@" </dev/null 2>&1; fi
	code=$?
	docker rm -f campaigns-appkey-test >/dev/null 2>&1
	return $code
}
bad_key() { # description, key value (or UNSET)
	out=$(appkey_run "$2" "$image")
	code=$?
	payload=${2#base64:}
	if [ "$code" = 0 ] || [ "$code" = 124 ]; then echo "FAIL - APP_KEY $1: container did not fail at start (exit $code)"; echo "$out" | head -8; rc=1
	elif ! echo "$out" | grep -q 'APP_KEY'; then echo "FAIL - APP_KEY $1: failed (exit $code) without naming APP_KEY"; echo "$out" | head -8; rc=1
	elif [ "$2" != UNSET ] && [ -n "$payload" ] && echo "$out" | grep -qF -- "$payload"; then echo "FAIL - APP_KEY $1: the message contains the key"; rc=1
	else echo "ok   - APP_KEY $1: container refuses to start (exit $code), message names APP_KEY"; fi
}
bad_key "of 16 bytes" "base64:$(head -c 16 /dev/urandom | base64)"
bad_key "without the base64: prefix" "$(head -c 32 /dev/urandom | base64)"
bad_key "that is not base64" "base64:!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
bad_key "that is empty" ""
bad_key "that is unset" UNSET
# ...but must not reject a key Laravel itself accepts (its base64_decode ignores whitespace and doesn't need padding).
ok_key() { # description, key value
	out=$(appkey_run "$2" --entrypoint sh "$image" -c '(. /etc/entrypoint.d/2-kanka-check-app-key.sh)')
	code=$?
	if [ "$code" = 0 ]; then echo "ok   - APP_KEY $1: accepted, as Laravel would"; else echo "FAIL - APP_KEY $1: rejected (exit $code) but Laravel accepts it"; echo "$out" | head -8; rc=1; fi
}
good32=$(head -c 32 /dev/urandom | base64)
ok_key "with a trailing space" "base64:$good32 "
ok_key "with a trailing newline" "base64:$good32
"
ok_key "with its padding stripped" "base64:$(printf %s "$good32" | tr -d =)"
$C stop lucos_campaigns_search
$C run --rm --no-deps client search-down || rc=1
[ "$rc" = 0 ] || $C logs
cleanup
exit $rc
