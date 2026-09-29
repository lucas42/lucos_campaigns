#!/bin/sh
# Builds images (no bind mounts: the CI docker daemon is remote) and runs both gate phases.
set -u
cd "$(dirname "$0")"
C="docker compose -p campaigns-gate"
$C up -d --build app lucos_campaigns_auth || { $C down -v; exit 1; }
# Wait for nginx to answer; the exempt favicon needs neither sidecar nor Laravel.
$C run --rm --entrypoint sh client -c 'for i in $(seq 1 60); do curl -sf -o /dev/null http://app:8080/favicon.ico && exit 0; sleep 2; done; exit 1' || { $C logs; $C down -v; exit 1; }
rc=0
$C run --rm client up || rc=1
$C stop lucos_campaigns_auth
$C run --rm --no-deps client sidecar-down || rc=1
[ "$rc" = 0 ] || $C logs
$C down -v
exit $rc
