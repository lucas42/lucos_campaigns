#!/usr/bin/env bash
# Usage: kanka-next-release.sh <current-version> < releases.json
# Reads GitHub's list-releases JSON on stdin. Prints next=<tag> (empty if none) and behind=<n>.
# "next" is the first published release strictly after the current one, never the latest: upgrades go one release at a time.
set -euo pipefail
current=${1:?usage: kanka-next-release.sh <current-version>}
# Tags come from upstream, so only well-formed version numbers may go any further.
tags=$(jq -r '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name' | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)
after=$({ printf '%s\n' "$tags"; printf '%s\n' "$current"; } | grep . | sort -V -u | awk -v c="$current" 'found { print } $0 == c { found = 1 }')
echo "next=$(printf '%s\n' "$after" | head -n 1)"
echo "behind=$(printf '%s\n' "$after" | grep -c . || true)"
