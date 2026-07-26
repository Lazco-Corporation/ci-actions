#!/usr/bin/env bash
# assert-promoted-image - assert the exact <version>-<sha> image already exists
# in the registry. Prod never rebuilds: a missing manifest means the version
# never shipped to staging.
#
# Env inputs:
#   IMAGE_REF   full image reference (<org>/<name>:<version>-<sha>)
#   RETRIES     manifest probe attempts (default 3)
#   RETRY_DELAY seconds between attempts (default 3)

set -uo pipefail

RETRIES="${RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-3}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "::group::Promoted image check"
echo "  Image : ${IMAGE_REF}"
echo "  Rule  : prod never rebuilds - the exact <version>-<sha> image must exist from a staging release"
echo "::endgroup::"

for attempt in $(seq 1 "$RETRIES"); do
  if docker manifest inspect "$IMAGE_REF" > /dev/null 2>&1; then
    echo "attempt ${attempt}/${RETRIES}: image found"
    echo "::notice title=Promoted image verified::${IMAGE_REF} exists in the registry"
    {
      echo "### Promoted image check"
      echo ""
      echo "| | |"
      echo "|---|---|"
      echo "| Image | \`${IMAGE_REF}\` |"
      echo "| Result | exists (attempt ${attempt}/${RETRIES}) |"
      echo ""
    } >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
  if [ "$attempt" -lt "$RETRIES" ]; then
    echo "attempt ${attempt}/${RETRIES}: image not found, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
  else
    echo "attempt ${attempt}/${RETRIES}: image not found"
  fi
done

echo "::error title=Image not found::${IMAGE_REF} was never built by a staging release. Prod never rebuilds - ship this version to staging first, then re-tag prod."
{
  echo "### Promoted image check"
  echo ""
  echo "| | |"
  echo "|---|---|"
  echo "| Image | \`${IMAGE_REF}\` |"
  echo "| Result | NOT FOUND after ${RETRIES} attempts - never shipped to staging |"
  echo ""
} >> "$GITHUB_STEP_SUMMARY"
exit 1
