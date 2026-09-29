#!/usr/bin/env bash
# Issue handling for the Kanka upstream watch. Needs GITHUB_REPOSITORY and a gh token (GH_TOKEN); DRY_RUN=1 only prints the changes.
#   upgrade  <from> <next> <commit> <behind> <published>   open the "Upgrade Kanka" issue unless one exists in any state
#   findings <findings.json> <version>                     create, update or close the single findings issue
#   health   ok|failed <run-url>                           create, update or close the "watch is failing" issue
set -euo pipefail
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

FINDINGS_TITLE="Upstream security findings in pinned Kanka"
HEALTH_TITLE="Kanka upstream watch is failing"

# One JSON object per issue (pull requests excluded), any state.
load_issues() { gh api --paginate "repos/$repo/issues?state=all&per_page=100" --jq '.[] | select(.pull_request | not) | {number, title, state, body}' > "$tmp/issues.ndjson"; }
find_issue() { # title, state ("any" or "open") -> "<number> <state>" of the first match
	jq -s -r --arg t "$1" --arg s "$2" 'map(select(.title == $t and ($s == "any" or .state == $s))) | first // empty | "\(.number) \(.state)"' "$tmp/issues.ndjson"
}
issue_body() { jq -s -r --argjson n "$1" 'map(select(.number == $n)) | first | .body // ""' "$tmp/issues.ndjson"; }
mutate() { # description, then the gh api arguments (JSON payload on stdin)
	local desc=$1; shift
	if [ "${DRY_RUN:-}" = 1 ]; then echo "DRY RUN: $desc"; cat > /dev/null; else gh api --method "$@" --input - > /dev/null; echo "$desc"; fi
}
create_issue() { jq -n --arg t "$1" --rawfile b "$2" '{title: $t, body: $b}' | mutate "created issue: $1" POST "repos/$repo/issues"; }
update_body() { jq -n --rawfile b "$2" '{body: $b}' | mutate "updated the body of #$1" PATCH "repos/$repo/issues/$1"; }
comment_and_close() { # number, comment text
	jq -n --arg b "$2" '{body: $b}' | mutate "commented on #$1" POST "repos/$repo/issues/$1/comments"
	jq -n '{state: "closed", state_reason: "completed"}' | mutate "closed #$1" PATCH "repos/$repo/issues/$1"
}
same_text() { [ "$(printf '%s' "$1" | sed -e 's/[[:space:]]*$//')" = "$(printf '%s' "$2" | sed -e 's/[[:space:]]*$//')" ]; }

cmd_upgrade() {
	local from=$1 next=$2 commit=$3 behind=$4 published=$5
	[[ $from =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && $next =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && $commit =~ ^[0-9a-f]{40}$ && $behind =~ ^[0-9]+$ && $published =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "refusing to build an issue from unexpected values" >&2; exit 1; }
	local title="Upgrade Kanka to $next (from $from)" existing
	load_issues
	existing=$(find_issue "$title" any)
	if [ -n "$existing" ]; then echo "an issue for this upgrade already exists (#${existing% *}, ${existing#* }); nothing to do"; return; fi
	local body; body=$(<"$here/../kanka-upgrade-issue.md")
	body=${body//\{\{from\}\}/$from}; body=${body//\{\{next\}\}/$next}; body=${body//\{\{commit\}\}/$commit}; body=${body//\{\{behind\}\}/$behind}; body=${body//\{\{published\}\}/$published}
	body=${body//\{\{release_url\}\}/https://github.com/owlchester/kanka/releases/tag/$next}
	printf '%s\n' "$body" > "$tmp/body.md"
	create_issue "$title" "$tmp/body.md"
}

cmd_findings() {
	local file=$1 version=$2 n open
	n=$(jq length "$file")
	load_issues
	open=$(find_issue "$FINDINGS_TITLE" open)
	if [ "$n" = 0 ]; then
		if [ -n "$open" ]; then comment_and_close "${open% *}" "No unaccepted upstream findings remain in the pinned Kanka $version, so this is closing itself."; else echo "no unaccepted findings, and no open findings issue"; fi
		return
	fi
	local upgrades; upgrades=$(jq -s -r 'map(select(.state == "open" and (.title | startswith("Upgrade Kanka to ")))) | map("#\(.number)") | join(", ")' "$tmp/issues.ndjson")
	{
		echo "The pinned Kanka ($version) has $n upstream finding(s) that are not in \`.github/upstream-audit-accepted.txt\`."
		echo
		echo "| Advisory | Package | Severity | Source | Details |"
		echo "|---|---|---|---|---|"
		jq -r '.[] | "| \(.id | gsub("[^A-Za-z0-9._-]"; "")) | \(.package | gsub("[^A-Za-z0-9._@/-]"; "")) | \(.severity | gsub("[^a-z]"; "")) | \(.source) | \(if (.url | test("^https://[^ )]+$")) then "[advisory](\(.url))" else "" end) `\(.title | gsub("[`|@\r\n]"; " "))` |"' "$file"
		echo
		echo "The usual fix is upgrading Kanka.${upgrades:+ Open upgrade issue(s): $upgrades.}"
		echo "If a finding is harmless here, add its ID and the reason to \`.github/upstream-audit-accepted.txt\` in a reviewed PR."
		echo
		echo "*Maintained automatically by the Kanka upstream watch workflow: it updates this issue and closes it once no findings remain.*"
	} > "$tmp/body.md"
	if [ -z "$open" ]; then create_issue "$FINDINGS_TITLE" "$tmp/body.md"; return; fi
	if same_text "$(issue_body "${open% *}")" "$(<"$tmp/body.md")"; then echo "findings issue #${open% *} is already up to date"; else update_body "${open% *}" "$tmp/body.md"; fi
}

cmd_health() {
	local state=$1 run_url=$2 open
	[[ $run_url =~ ^https://[^[:space:]]+$ ]] || { echo "refusing an unexpected run URL" >&2; exit 1; }
	load_issues
	open=$(find_issue "$HEALTH_TITLE" open)
	if [ "$state" = ok ]; then
		if [ -n "$open" ]; then comment_and_close "${open% *}" "The Kanka upstream watch is passing again ($run_url), so this is closing itself."; else echo "watch is healthy, and no open failing issue"; fi
		return
	fi
	printf 'The scheduled Kanka upstream watch failed, so new Kanka releases and upstream advisories are not being checked.\n\nLatest failing run: %s\n\n*Maintained automatically: this closes itself when the watch passes again.*\n' "$run_url" > "$tmp/body.md"
	if [ -z "$open" ]; then create_issue "$HEALTH_TITLE" "$tmp/body.md"
	elif same_text "$(issue_body "${open% *}")" "$(<"$tmp/body.md")"; then echo "failing issue #${open% *} is already up to date"
	else update_body "${open% *}" "$tmp/body.md"; fi
}

case "${1:-}" in
	upgrade) shift; cmd_upgrade "$@" ;;
	findings) shift; cmd_findings "$@" ;;
	health) shift; cmd_health "$@" ;;
	*) echo "usage: $0 upgrade|findings|health ..." >&2; exit 2 ;;
esac
