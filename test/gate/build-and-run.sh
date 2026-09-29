#!/bin/sh
# Builds images (no bind mounts: the CI docker daemon is remote) and runs both gate phases.
set -u
cd "$(dirname "$0")"
C="docker compose -p campaigns-gate"
$C build client && $C up -d --build app lucos_campaigns_auth app_authed auth_stub || { $C down -v; exit 1; }
# Wait for nginx to answer; the exempt favicon needs neither sidecar nor Laravel.
$C run --rm --entrypoint sh client -c 'for i in $(seq 1 60); do curl -sf -o /dev/null http://app:8080/favicon.ico && curl -sf -o /dev/null http://app_authed:8080/favicon.ico && exit 0; sleep 2; done; exit 1' || { $C logs; $C down -v; exit 1; }
rc=0
servers=$($C exec -T app nginx -T 2>/dev/null | grep -c '^[[:space:]]*server {')
if [ "$servers" = 1 ]; then echo "ok   - nginx has exactly one server block"; else echo "FAIL - nginx has $servers server blocks, want 1"; rc=1; fi
$C run --rm client up || rc=1
$C run --rm client authed || rc=1
$C stop lucos_campaigns_auth
$C run --rm --no-deps client sidecar-down || rc=1
[ "$rc" = 0 ] || $C logs
$C down -v
exit $rc
