#!/usr/bin/env bash
# prod-actor-guard - fail-closed allow-list check for prod release tags.
#
# Env inputs:
#   ACTOR          github.actor (who pushed the tag)
#   ALLOWED_ACTORS comma-separated GitHub logins (PROD_RELEASE_ACTORS)

set -euo pipefail

GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ -z "${ALLOWED_ACTORS:-}" ]; then
  echo "::error title=Missing CI config::PROD_RELEASE_ACTORS is not set in Infisical /ci (prod) - refusing the prod release (fail-closed)"
  exit 1
fi

actor_lc="$(printf '%s' "$ACTOR" | tr '[:upper:]' '[:lower:]')"
for candidate in $(printf '%s' "$ALLOWED_ACTORS" | tr ',' ' '); do
  if [ "$actor_lc" = "$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "::notice title=Prod release authorized::${ACTOR} is on the prod allow-list"
    echo "| Prod guard | authorized (\`${ACTOR}\`) |" >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
done

echo "::error title=Unauthorized prod release::actor '${ACTOR}' is not on PROD_RELEASE_ACTORS (allowed: ${ALLOWED_ACTORS}). The tag exists but the pipeline refused to act on it."
echo "| Prod guard | BLOCKED - \`${ACTOR}\` not on the allow-list |" >> "$GITHUB_STEP_SUMMARY"
exit 1
