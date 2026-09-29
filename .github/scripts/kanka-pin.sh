#!/usr/bin/env bash
# Prints version=<KANKA_VERSION> and commit=<KANKA_COMMIT> from a Dockerfile. Fails unless each ARG is set exactly once.
set -euo pipefail
dockerfile=${1:-Dockerfile}
pin() { # ARG name, validation regex
	local lines
	lines=$(grep -E "^ARG $1=" "$dockerfile" || true)
	if [ "$(printf '%s' "$lines" | grep -c .)" != 1 ]; then echo "$dockerfile must set 'ARG $1=' exactly once" >&2; exit 1; fi
	local value=${lines#ARG "$1"=}
	if ! [[ $value =~ $2 ]]; then echo "ARG $1 has an unexpected value" >&2; exit 1; fi
	printf '%s\n' "$value"
}
# Assign first: an exit inside $(...) only ends the subshell, so echoing it directly would swallow the failure.
version=$(pin KANKA_VERSION '^[0-9]+\.[0-9]+(\.[0-9]+)?$')
commit=$(pin KANKA_COMMIT '^[0-9a-f]{40}$')
echo "version=$version"
echo "commit=$commit"
