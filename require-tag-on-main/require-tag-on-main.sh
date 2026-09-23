#!/usr/bin/env bash
# require-tag-on-main - refuse a release tag whose commit the release branch
# does not contain.
#
# A tag can point at any commit, including one that no branch holds. A
# t4-collector prod tag already did: it named a commit that survived only as a
# pre-squash PR head, so the pipeline that shipped it was 67 lines behind main.
# The built artifact matched that time by luck.
#
# The check reads the compare API, so it needs no checkout and no git history.
#
# Env inputs:
#   REPOSITORY  owner/repo                        (github.repository)
#   SHA         commit the tag points at          (github.sha)
#   BRANCH      branch that must contain SHA      (default main)
#   REF_NAME    tag name, used only in messages   (github.ref_name)
#   TOKEN       GitHub token with contents: read
#   API_URL     GitHub API base                   (github.api_url)

set -euo pipefail

GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
API_URL="${API_URL:-https://api.github.com}"
BRANCH="${BRANCH:-main}"
REF_NAME="${REF_NAME:-the tag}"

fail() {
  echo "::error title=${1}::${2}"
  echo "| Tag on ${BRANCH} | BLOCKED - ${3} |" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}

for required in REPOSITORY SHA TOKEN; do
  if [ -z "${!required:-}" ]; then
    fail "Missing input" \
      "${required} is empty - refusing the release (fail-closed)" \
      "\`${required}\` was empty"
  fi
done

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# compare/BASE...HEAD answers from HEAD's side:
#   identical  HEAD is the tip of BASE
#   behind     BASE contains HEAD, so the commit is merged
#   ahead      HEAD carries commits BASE lacks
#   diverged   both carry commits the other lacks
code="$(curl -sS -o "$body" --max-time 15 -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${API_URL}/repos/${REPOSITORY}/compare/${BRANCH}...${SHA}" 2> /dev/null || echo "000")"

if [ "$code" != "200" ]; then
  fail "Cannot verify the tag" \
    "GitHub answered HTTP ${code} for compare ${BRANCH}...${SHA} - refusing the release (fail-closed)" \
    "compare API returned HTTP \`${code}\`"
fi

status="$(jq -r '.status // empty' "$body")"

case "$status" in
  identical | behind)
    echo "::notice title=Tag is on ${BRANCH}::${REF_NAME} points at ${SHA}, which ${BRANCH} contains (${status})"
    echo "| Tag on ${BRANCH} | ok - \`${REF_NAME}\` (${status}) |" >> "$GITHUB_STEP_SUMMARY"
    ;;
  ahead | diverged)
    fail "Tag is not on ${BRANCH}" \
      "${REF_NAME} points at ${SHA}, which ${BRANCH} does not contain (compare says '${status}'). Releases run from ${BRANCH} only. Merge first, then tag the commit on ${BRANCH}." \
      "\`${REF_NAME}\` is not on \`${BRANCH}\` (${status})"
    ;;
  *)
    fail "Cannot verify the tag" \
      "compare returned an unexpected status '${status}' - refusing the release (fail-closed)" \
      "unexpected compare status \`${status}\`"
    ;;
esac
