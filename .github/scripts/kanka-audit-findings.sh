#!/usr/bin/env bash
# Usage: kanka-audit-findings.sh <composer-audit.json> <yarn-audit.ndjson> <advisories.json> <accepted.txt> <outdir>
# Writes <outdir>/findings.json (unaccepted findings, one per advisory and package) and <outdir>/stale.txt (accepted IDs no longer found).
# Fails if an input isn't the output of a complete run, so a broken audit can't read as "no findings".
set -euo pipefail
composer=$1 yarn=$2 advisories=$3 accepted=$4 out=$5
mkdir -p "$out"

jq -e 'has("advisories")' "$composer" >/dev/null || { echo "composer audit output is not a complete result" >&2; exit 1; }
grep '^{' "$yarn" | jq -e -s 'any(.[]; .type == "auditSummary")' >/dev/null || { echo "yarn audit output has no auditSummary" >&2; exit 1; }
jq -e 'type == "array"' "$advisories" >/dev/null || { echo "security-advisories output is not a list" >&2; exit 1; }

# Composer's advisories is [] when clean and {package: [advisory]} otherwise.
{
	jq -c '.advisories | (if type == "array" then . else [.[][]] end) | .[] | {id: .advisoryId, package: .packageName, severity: (.severity // "unknown"), source: "composer audit", url: (.link // ""), title: (.title // "")}' "$composer"
	grep '^{' "$yarn" | jq -c 'select(.type == "auditAdvisory") | .data.advisory | {id: .github_advisory_id, package: .module_name, severity: .severity, source: "yarn audit", url: .url, title: (.title // "")}'
	jq -c '.[] | {id: .ghsa_id, package: "owlchester/kanka", severity: (.severity // "unknown"), source: "Kanka security advisory", url: .html_url, title: (.summary // "")}' "$advisories"
} | jq -s -c 'unique_by([.id, .package])' > "$out/all.json"

ids=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$accepted" | awk 'NF { print $1 }' | sort -u)
printf '%s\n' "$ids" | grep . | jq -R . | jq -s -c . > "$out/accepted-ids.json" || echo '[]' > "$out/accepted-ids.json"
jq -c --slurpfile a "$out/accepted-ids.json" '[.[] | select(.id as $i | ($a[0] | index($i)) | not)]' "$out/all.json" > "$out/findings.json"
jq -r --slurpfile f "$out/all.json" '.[] | select(. as $i | ($f[0] | map(.id) | index($i)) | not)' "$out/accepted-ids.json" > "$out/stale.txt"
