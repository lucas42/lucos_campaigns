#!/bin/sh
# Full stack from the real image (no bind mounts: the CI docker daemon is remote), then /_info assertions.
set -u
cd "$(dirname "$0")/../.."
export PORT=8080 APP_ORIGIN=http://localhost:8080 SYSTEM=lucos_campaigns \
	APP_KEY="base64:$(head -c 32 /dev/urandom | base64)" DB_PASSWORD=test DB_ROOT_PASSWORD=test \
	MEILI_MASTER_KEY=test-master-key-0123456789 KEY_LUCOS_AITHNE=dummy \
	OAUTH2_PROXY_COOKIE_SECRET=0123456789abcdef0123456789abcdef AITHNE_ORIGIN=http://aithne.invalid
C="docker compose -p campaigns-full -f docker-compose.yml -f test/full/docker-compose.yml"
cleanup() { $C down -v; }
$C build && $C up -d lucos_campaigns_app || { $C logs; cleanup; exit 1; }
# First start migrates, seeds and indexes, so wait for every check to pass rather than for nginx.
$C run --rm --entrypoint sh client -c 'for i in $(seq 1 90); do curl -s --max-time 5 http://lucos_campaigns_app:8080/_info | jq -e "[.checks[].ok] | all" >/dev/null && exit 0; sleep 5; done; curl -s http://lucos_campaigns_app:8080/_info; exit 1' || { $C logs; cleanup; exit 1; }
rc=0
$C run --rm client up || rc=1
# Kanka's config/mail.php reads the legacy MAIL_DRIVER (default smtp), not MAIL_MAILER: assert what the app really resolves.
mail=$($C exec -T lucos_campaigns_app php artisan config:show mail.driver 2>/dev/null | awk 'NF {v=$NF} END {print v}')
if [ "$mail" = log ]; then echo "ok   - mail.driver resolves to log, so no mail is sent"; else echo "FAIL - mail.driver resolves to '$mail', wanted log"; rc=1; fi
$C stop lucos_campaigns_search
$C run --rm --no-deps client search-down || rc=1
[ "$rc" = 0 ] || $C logs
cleanup
exit $rc
