#!/usr/bin/env bash
# Usage: kanka-audit-findings.sh <composer-audit.json> <composer.lock> <yarn-audit.ndjson> <advisories.json> <accepted.txt> <outdir>
# Writes <outdir>/findings.json (unaccepted findings, one per advisory and package) and <outdir>/stale.txt (accepted IDs no longer found),
# and prints the counts so they show in the run log.
# Fails if an input isn't the output of a complete run, or if an audit checked nothing, so a broken audit can't read as "no findings".
set -euo pipefail
composer=$1 lock=$2 yarn=$3 advisories=$4 accepted=$5 out=$6
mkdir -p "$out"

jq -e 'has("advisories")' "$composer" >/dev/null || { echo "composer audit output is not a complete result" >&2; exit 1; }
grep '^{' "$yarn" | jq -e -s 'any(.[]; .type == "auditSummary")' >/dev/null || { echo "yarn audit output has no auditSummary" >&2; exit 1; }
jq -e 'type == "array"' "$advisories" >/dev/null || { echo "security-advisories output is not a list" >&2; exit 1; }

# A complete result that audited nothing looks exactly like a clean one, so require evidence that something was audited.
deps=$(grep '^{' "$yarn" | jq -s -r '[.[] | select(.type == "auditSummary")] | last | .data.dependencies // 0')
[ "$deps" -gt 0 ] 2>/dev/null || { echo "yarn audit audited zero dependencies (or reported no count), so it can't vouch for anything" >&2; exit 1; }
packages=$(jq -r '(.packages // []) | length' "$lock" 2>/dev/null || echo 0)
[ "$packages" -gt 0 ] 2>/dev/null || { echo "composer.lock lists no packages (or is unreadable), so composer audit checked nothing" >&2; exit 1; }

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

all_n=$(jq length "$out/all.json"); unaccepted_n=$(jq length "$out/findings.json"); accepted_n=$(jq length "$out/accepted-ids.json"); stale_n=$(grep -c . "$out/stale.txt" || true)
echo "audited: $deps yarn dependencies, $packages composer packages"
echo "findings: $all_n before filtering, $unaccepted_n unaccepted, $stale_n stale accepted entries (of $accepted_n accepted)"
[ "$stale_n" = 0 ] || echo "stale accepted: $(paste -sd' ' "$out/stale.txt")"
# Expected after an upgrade fixes everything, but also what a silently empty audit looks like, so make it visible without failing.
if [ "$accepted_n" -gt 0 ] && [ "$stale_n" = "$accepted_n" ]; then echo "::warning::every accepted entry is stale, so nothing on the accepted list was found. Expected if an upgrade fixed them all; otherwise check the audit output."; fi
