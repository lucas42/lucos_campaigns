#!/usr/bin/env bash
# Tests for the Kanka upstream watch scripts. No network: a fake `gh` serves canned issues and records every write.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fx=$here/fixtures
accepted=$here/../upstream-audit-accepted.txt
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
expect() { # description, expected, actual
	if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: wanted '$2', got '$3'"; fail=1; fi
}
contains() { # description, haystack, needle
	if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok   - $1"; else echo "FAIL - $1: missing '$3'"; fail=1; fi
}
lacks() { # description, haystack, needle
	if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL - $1: found '$3'"; fail=1; else echo "ok   - $1"; fi
}

echo "# next release: one at a time, never the latest"
next() { "$here/kanka-next-release.sh" "$1" < "$fx/releases.json" | tr '\n' ' '; }
expect "pin 3.12 proposes 3.13, not the latest 3.15" "next=3.13 behind=2 " "$(next 3.12)"
expect "pin 3.15 (the latest) proposes nothing" "next= behind=0 " "$(next 3.15)"
expect "3.10 sorts after 3.9" "next=3.10 behind=4 " "$(next 3.9)"
expect "a pin that is not itself a release still finds the next one" "next=3.15 behind=1 " "$(next 3.14)"
expect "drafts, prereleases and odd tags are never proposed (pin 3.13 -> 3.15)" "next=3.15 behind=1 " "$(next 3.13)"
expect "hostile tag was ignored, not executed" "no" "$([ -e /tmp/pwned ] && echo yes || echo no)"

echo "# pin: read exactly once, validated"
d=$tmp/Dockerfile.good; printf 'ARG KANKA_VERSION=3.15\nARG KANKA_COMMIT=%s\nFROM x\nARG KANKA_VERSION\nARG KANKA_COMMIT\n' "$(printf 'a%.0s' {1..40})" > "$d"
expect "valid Dockerfile" "version=3.15 commit=$(printf 'a%.0s' {1..40}) " "$("$here/kanka-pin.sh" "$d" | tr '\n' ' ')"
printf 'ARG KANKA_VERSION=3.15\nARG KANKA_VERSION=3.16\nARG KANKA_COMMIT=%s\n' "$(printf 'a%.0s' {1..40})" > "$tmp/Dockerfile.dup"
"$here/kanka-pin.sh" "$tmp/Dockerfile.dup" >/dev/null 2>&1; expect "duplicate ARG fails" "1" "$?"
printf 'ARG KANKA_COMMIT=%s\n' "$(printf 'a%.0s' {1..40})" > "$tmp/Dockerfile.missing"
"$here/kanka-pin.sh" "$tmp/Dockerfile.missing" >/dev/null 2>&1; expect "missing ARG fails" "1" "$?"
printf 'ARG KANKA_VERSION=main\nARG KANKA_COMMIT=%s\n' "$(printf 'a%.0s' {1..40})" > "$tmp/Dockerfile.bad"
"$here/kanka-pin.sh" "$tmp/Dockerfile.bad" >/dev/null 2>&1; expect "malformed version fails" "1" "$?"

echo "# audit findings: the real 3.15 output"
o=$tmp/out
"$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$accepted" "$o"
expect "3.15 has 5 distinct advisories, all accepted, so 0 findings" "5 0" "$(jq length "$o/all.json") $(jq length "$o/findings.json")"
expect "no stale accepted entries" "0" "$(grep -c . "$o/stale.txt" || true)"
: > "$tmp/none.txt"; "$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$tmp/none.txt" "$o"
expect "with nothing accepted, the 5 yarn advisories surface (deduped across paths)" "5" "$(jq length "$o/findings.json")"
"$here/kanka-audit-findings.sh" "$fx/composer-finding.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-one.json" "$accepted" "$o"
expect "composer and Kanka advisories surface; accepted yarn ones don't" "GHSA-test-kanka-0001 PKSA-test-0001" "$(jq -r '[.[].id] | sort | join(" ")' "$o/findings.json")"
{ echo 'GHSA-gone-0000-0000  # stale (2026-01-01)'; cat "$accepted"; } > "$tmp/acc-stale.txt"
"$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$tmp/acc-stale.txt" "$o"
expect "a stale accepted entry is reported" "GHSA-gone-0000-0000" "$(cat "$o/stale.txt")"
echo > "$tmp/empty"; "$here/kanka-audit-findings.sh" "$tmp/empty" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$accepted" "$o" >/dev/null 2>&1
expect "an incomplete composer result fails rather than reading as clean" "1" "$?"
"$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$tmp/empty" "$fx/advisories-none.json" "$accepted" "$o" >/dev/null 2>&1
expect "an incomplete yarn result fails" "1" "$?"

echo "# audit: counts in the log, and an audit that audited nothing fails"
out=$("$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$accepted" "$tmp/counts" 2>&1); code=$?
expect "real 3.15 fixtures exit 0" "0" "$code"
contains "the log says how much was audited" "$out" "audited: 505 yarn dependencies, 2 composer packages"
contains "the log shows the three counts" "$out" "findings: 5 before filtering, 0 unaccepted, 0 stale accepted entries (of 5 accepted)"
lacks "no warning when the accepted entries are still found" "$out" "::warning::"
out=$("$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-zero-deps.ndjson" "$fx/advisories-none.json" "$accepted" "$tmp/z1" 2>&1); code=$?
expect "yarn audit of zero dependencies fails" "1" "$code"
contains "...and says why" "$out" "audited zero dependencies"
"$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-no-count.ndjson" "$fx/advisories-none.json" "$accepted" "$tmp/z2" >/dev/null 2>&1
expect "a yarn summary with no dependency count fails" "1" "$?"
out=$("$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock-empty.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$accepted" "$tmp/z3" 2>&1); code=$?
expect "a composer.lock with no packages fails (dev-only packages don't count)" "1" "$code"
contains "...and says why" "$out" "composer.lock lists no packages"
"$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$tmp/no-such-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$accepted" "$tmp/z4" >/dev/null 2>&1
expect "a missing composer.lock fails" "1" "$?"
printf 'GHSA-gone-0001  # x (2026-01-01)\nGHSA-gone-0002  # y (2026-01-01)\n' > "$tmp/all-stale.txt"
out=$("$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$tmp/all-stale.txt" "$tmp/s1" 2>&1); code=$?
expect "every accepted entry stale: exits 0, not a failure" "0" "$code"
contains "...but warns" "$out" "::warning::every accepted entry is stale"
contains "...and names them" "$out" "stale accepted: GHSA-gone-0001 GHSA-gone-0002"
out=$("$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$tmp/acc-stale.txt" "$tmp/s2" 2>&1)
contains "one stale entry among live ones is listed" "$out" "stale accepted: GHSA-gone-0000-0000"
lacks "...without the all-stale warning" "$out" "::warning::"

echo "# issues: create, dedupe, update, close (fake gh)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fake gh: `api [--paginate] [--method M] ENDPOINT [--jq F] [--input -]`. GET serves $FAKE_ISSUES; writes are appended to $FAKE_LOG.
shift; method=GET jq_filter=. endpoint="" input=""
while [ $# -gt 0 ]; do case $1 in --paginate) ;; --method) method=$2; shift ;; --jq) jq_filter=$2; shift ;; --input) input=$2; shift ;; *) endpoint=$1 ;; esac; shift; done
if [ "$method" = GET ]; then
	[ "$endpoint" = "repos/o/r/issues?state=all&per_page=100" ] || { echo "unexpected GET $endpoint" >&2; exit 1; }
	jq -c "map(.user //= {login: \"github-actions[bot]\"} | .author_association //= \"NONE\") | $jq_filter" "$FAKE_ISSUES"
else
	echo "$method $endpoint $(cat | jq -c .)" >> "$FAKE_LOG"; echo '{}'
fi
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r FAKE_ISSUES=$tmp/issues.json FAKE_LOG=$tmp/log
run() { : > "$FAKE_LOG"; "$here/kanka-watch-issues.sh" "$@" > "$tmp/stdout" 2>&1; echo $?; }
writes() { grep -c . "$FAKE_LOG" || true; }
sha=$(printf 'b%.0s' {1..40})
echo '[]' > "$FAKE_ISSUES"
expect "upgrade: created when no issue exists" "0 1" "$(run upgrade 3.12 3.13 "$sha" 2 2026-06-30) $(writes)"
body=$(sed 's/^POST [^ ]* //' "$FAKE_LOG" | jq -r .body)
expect "upgrade: title" "Upgrade Kanka to 3.13 (from 3.12)" "$(sed 's/^POST [^ ]* //' "$FAKE_LOG" | jq -r .title)"
contains "upgrade: names the release, date and how far behind" "$body" "Kanka 3.13 was released on 2026-06-30. This repo is on 3.12, 2 release(s) behind"
contains "upgrade: links the release notes rather than pasting them" "$body" "https://github.com/owlchester/kanka/releases/tag/3.13"
contains "upgrade: two-line bump with the resolved commit" "$body" "ARG KANKA_COMMIT=$sha"
contains "upgrade: backup file is named for the current version" "$body" "kanka-3.12-"
lacks "upgrade: no unfilled placeholder" "$body" "{{"
echo '[{"number":4,"title":"Upgrade Kanka to 3.13 (from 3.12)","state":"open","body":""}]' > "$FAKE_ISSUES"
expect "upgrade: skipped when an open issue has the title" "0 0" "$(run upgrade 3.12 3.13 "$sha" 2 2026-06-30) $(writes)"
echo '[{"number":4,"title":"Upgrade Kanka to 3.13 (from 3.12)","state":"closed","body":""}]' > "$FAKE_ISSUES"
expect "upgrade: skipped when a closed issue (say, closed as not planned) has the title" "0 0" "$(run upgrade 3.12 3.13 "$sha" 2 2026-06-30) $(writes)"
echo '[{"number":4,"title":"Upgrade Kanka to 3.12 (from 3.10)","state":"closed","body":""}]' > "$FAKE_ISSUES"
expect "upgrade: a different version pair still gets its issue" "0 1" "$(run upgrade 3.12 3.13 "$sha" 2 2026-06-30) $(writes)"
expect "upgrade: unexpected values are refused" "1 0" "$(run upgrade 3.12 '3.13"; x' "$sha" 2 2026-06-30) $(writes)"

echo "# issues: an untrusted author can't squat a title"
echo '[{"number":4,"title":"Upgrade Kanka to 3.13 (from 3.12)","state":"open","body":"","user":{"login":"stranger"},"author_association":"NONE"}]' > "$FAKE_ISSUES"
expect "squat: a stranger's issue with the upgrade title doesn't suppress the real one" "0 1" "$(run upgrade 3.12 3.13 "$sha" 2 2026-06-30) $(writes)"
echo '[{"number":4,"title":"Upgrade Kanka to 3.13 (from 3.12)","state":"closed","body":"","user":{"login":"lucas42"},"author_association":"OWNER"}]' > "$FAKE_ISSUES"
expect "squat: a collaborator's issue (closed as not planned, say) still suppresses it" "0 0" "$(run upgrade 3.12 3.13 "$sha" 2 2026-06-30) $(writes)"
echo '[{"number":9,"title":"Upstream security findings in pinned Kanka","state":"open","body":"stranger text","user":{"login":"stranger"},"author_association":"NONE"}]' > "$FAKE_ISSUES"
"$here/kanka-audit-findings.sh" "$fx/composer-finding.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-one.json" "$accepted" "$tmp/two"
res=$(run findings "$tmp/two/findings.json" 3.15)
expect "squat: a stranger's issue with the findings title is not adopted or edited" "0 POST repos/o/r/issues" "$res $(cut -d' ' -f1-2 "$FAKE_LOG")"

echo '[{"number":7,"title":"Upgrade Kanka to 3.16 (from 3.15)","state":"open","body":""}]' > "$FAKE_ISSUES"
"$here/kanka-audit-findings.sh" "$fx/composer-finding.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-one.json" "$accepted" "$tmp/two"
expect "findings: created when there are findings and no open issue" "0 1" "$(run findings "$tmp/two/findings.json" 3.15) $(writes)"
fbody=$(sed 's/^POST [^ ]* //' "$FAKE_LOG" | jq -r .body); ftitle=$(sed 's/^POST [^ ]* //' "$FAKE_LOG" | jq -r .title)
expect "findings: single fixed title" "Upstream security findings in pinned Kanka" "$ftitle"
contains "findings: lists the advisory with its link" "$fbody" "| PKSA-test-0001 | \`laravel/framework\` | high | composer audit | [advisory](https://example.invalid/advisory/1)"
contains "findings: links an open upgrade issue" "$fbody" "#7"
lacks "findings: upstream text cannot mention anyone" "$fbody" "@someone"
lacks "findings: upstream text cannot break out of its code span" "$fbody" "with \`backticks\`"
echo "# findings: hostile upstream text (newlines, mentions, backticks, pipes, odd URLs)"
"$here/kanka-audit-findings.sh" "$fx/composer-hostile.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$accepted" "$tmp/hostile"
echo '[]' > "$FAKE_ISSUES"; run findings "$tmp/hostile/findings.json" 3.15 > /dev/null
hbody=$(sed 's/^POST [^ ]* //' "$FAKE_LOG" | jq -r .body)
rows=$(printf '%s\n' "$hbody" | grep -c '^| [A-Za-z]' || true)
expect "hostile: 4 findings give exactly 4 table rows plus the header (no injected rows)" "5" "$rows"
expect "hostile: every table line stays a single well-formed row" "0" "$(printf '%s\n' "$hbody" | grep '^|' | grep -vcE '^\|.*\|$' || true)"
# shellcheck disable=SC2016 # the backticks are literal: they strip markdown code spans
outside=$(printf '%s\n' "$hbody" | sed 's/`[^`]*`//g')
lacks "hostile: no mention survives outside a code span" "$outside" "@"
# shellcheck disable=SC2016 # literal backticks
contains "hostile: a scoped package is shown in a code span" "$hbody" '`@babel/core`'
lacks "hostile: a URL with a newline is not linked" "$hbody" "a.invalid/x"
lacks "hostile: a trailing-newline URL is not linked" "$hbody" "a.invalid/ok"
lacks "hostile: a non-https URL is not linked" "$hbody" "insecure.invalid"
lacks "hostile: a URL that breaks out of the link is not linked" "$hbody" "evil.invalid"
longtitle=$(printf 'x%.0s' {1..500})
jq -n --arg t "$longtitle" '{advisories: {"p/q": [{advisoryId: "PKSA-long", packageName: "p/q", title: $t, link: "https://a.invalid/x", severity: "low"}]}, abandoned: [], filter: []}' > "$tmp/composer-long.json"
"$here/kanka-audit-findings.sh" "$tmp/composer-long.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$accepted" "$tmp/long"
echo '[]' > "$FAKE_ISSUES"; run findings "$tmp/long/findings.json" 3.15 > /dev/null
lbody=$(sed 's/^POST [^ ]* //' "$FAKE_LOG" | jq -r .body)
expect "hostile: a 500-character title is capped at 200" "200" "$(printf '%s' "$lbody" | grep -o 'x\{1,\}' | awk '{ print length($0) }' | sort -n | tail -1)"
jq -n --arg b "$fbody" '[{"number":9,"title":"Upstream security findings in pinned Kanka","state":"open","body":$b},{"number":7,"title":"Upgrade Kanka to 3.16 (from 3.15)","state":"open","body":""}]' > "$FAKE_ISSUES"
expect "findings: an up-to-date open issue is left alone" "0 0" "$(run findings "$tmp/two/findings.json" 3.15) $(writes)"
jq -n '[{"number":9,"title":"Upstream security findings in pinned Kanka","state":"open","body":"old"}]' > "$FAKE_ISSUES"
res=$(run findings "$tmp/two/findings.json" 3.15)
expect "findings: an out-of-date open issue is updated, not duplicated" "0 PATCH repos/o/r/issues/9" "$res $(cut -d' ' -f1-2 "$FAKE_LOG")"
"$here/kanka-audit-findings.sh" "$fx/composer-clean.json" "$fx/composer-lock.json" "$fx/yarn-3.15.ndjson" "$fx/advisories-none.json" "$accepted" "$tmp/zero"
res=$(run findings "$tmp/zero/findings.json" 3.15)
expect "findings: closes itself once nothing remains" "0 POST repos/o/r/issues/9/comments|PATCH repos/o/r/issues/9" "$res $(cut -d' ' -f1-2 "$FAKE_LOG" | paste -sd'|')"
contains "findings: the close is 'completed'" "$(cat "$FAKE_LOG")" '"state":"closed","state_reason":"completed"'
echo '[]' > "$FAKE_ISSUES"
expect "findings: nothing to do when clean and no open issue" "0 0" "$(run findings "$tmp/zero/findings.json" 3.15) $(writes)"
echo '[{"number":9,"title":"Upstream security findings in pinned Kanka","state":"closed","body":"old"}]' > "$FAKE_ISSUES"
expect "findings: a closed issue is not reopened, a new one is created" "0 1" "$(run findings "$tmp/two/findings.json" 3.15) $(writes)"

echo '[]' > "$FAKE_ISSUES"
expect "health: failure opens the issue with the run URL" "0 1" "$(run health failed https://github.com/o/r/actions/runs/1) $(writes)"
contains "health: body carries the run URL" "$(cat "$FAKE_LOG")" "https://github.com/o/r/actions/runs/1"
hbody=$(sed 's/^POST [^ ]* //' "$FAKE_LOG" | jq -r .body)
jq -n --arg b "$hbody" '[{"number":3,"title":"Kanka upstream watch is failing","state":"open","body":$b}]' > "$FAKE_ISSUES"
expect "health: the same failing run is not re-written" "0 0" "$(run health failed https://github.com/o/r/actions/runs/1) $(writes)"
expect "health: a newer failing run updates the URL" "0 PATCH" "$(run health failed https://github.com/o/r/actions/runs/2) $(cut -d' ' -f1 "$FAKE_LOG")"
expect "health: success closes the failing issue" "0 2" "$(run health ok https://github.com/o/r/actions/runs/3) $(writes)"
echo '[]' > "$FAKE_ISSUES"
expect "health: success with no open issue does nothing" "0 0" "$(run health ok https://github.com/o/r/actions/runs/3) $(writes)"
expect "health: an unexpected run URL is refused" "1" "$(run health failed 'javascript:alert(1)')"
exit $fail
