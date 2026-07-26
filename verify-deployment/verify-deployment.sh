#!/usr/bin/env bash
# verify-deployment - poll a health endpoint until it serves HTTP 200 with the
# expected version, then confirm the match is stable (rolling-update flap guard).
#
# Env inputs:
#   SERVICE             service label used in messages (e.g. api, frontend)
#   ENV_NAME            environment label (staging | prod)
#   CHECK_URL           health endpoint URL; empty = skip verification
#   EXPECTED_VERSION    version string the endpoint must report
#   TIMEOUT             max seconds to wait for a match (default 300)
#   INTERVAL            seconds between probes (default 3)
#   VERSION_JQ_PATH     jq path to the version field (default .version)
#   STABILITY_CHECKS    consecutive matches required (default 3)
#   STABILITY_INTERVAL  seconds between stability probes (default 2)
#
# Output (GITHUB_OUTPUT): conclusion = verified | skipped | failed

set -uo pipefail

SERVICE="${SERVICE:-deployment}"
ENV_NAME="${ENV_NAME:-unknown}"
CHECK_URL="${CHECK_URL:-}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
TIMEOUT="${TIMEOUT:-300}"
INTERVAL="${INTERVAL:-3}"
VERSION_JQ_PATH="${VERSION_JQ_PATH:-.version}"
STABILITY_CHECKS="${STABILITY_CHECKS:-3}"
STABILITY_INTERVAL="${STABILITY_INTERVAL:-2}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

write_summary() {
  {
    echo "### Deployment verification"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Service / Env | \`${SERVICE}\` / \`${ENV_NAME}\` |"
    echo "| Health URL | ${CHECK_URL:-(not configured)} |"
    echo "| Expected | HTTP 200, version \`${EXPECTED_VERSION}\` |"
    echo "| Result | $1 |"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
}

if [ -z "$CHECK_URL" ]; then
  echo "::notice title=Deployment verification skipped::no health check URL configured for ${SERVICE} (${ENV_NAME})"
  echo "conclusion=skipped" >> "$GITHUB_OUTPUT"
  write_summary "skipped - no health URL configured"
  exit 0
fi

echo "::group::Deployment verification"
echo "  Service     : ${SERVICE}"
echo "  Environment : ${ENV_NAME}"
echo "  Health URL  : ${CHECK_URL}"
echo "  Waiting for : HTTP 200 and ${VERSION_JQ_PATH} == ${EXPECTED_VERSION}"
echo "  Stability   : ${STABILITY_CHECKS} consecutive matches, ${STABILITY_INTERVAL}s apart"
echo "  Timeout     : ${TIMEOUT}s, polling every ${INTERVAL}s"
echo "::endgroup::"

probe() {
  local body code ver
  body=$(mktemp)
  code=$(curl -s -o "$body" --max-time 10 -w '%{http_code}' "$CHECK_URL" 2>/dev/null || echo "000")
  ver=$(jq -r "$VERSION_JQ_PATH" "$body" 2>/dev/null || echo "")
  rm -f "$body"
  if [ -z "$ver" ] || [ "$ver" = "null" ]; then
    ver="(none)"
  fi
  echo "$code $ver"
}

diagnose() {
  if [ "$1" = "000" ]; then
    echo "no response"
  elif [ "$2" != "$EXPECTED_VERSION" ]; then
    echo "old version still live"
  else
    echo "new version, not healthy yet"
  fi
}

start_time=$(date +%s)
probes=0
last_code="000"
last_ver="(none)"
saw_expected_version=false

while true; do
  elapsed=$(( $(date +%s) - start_time ))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    printf '[%3ds] failed      giving up after %d probes\n' "$elapsed" "$probes"
    if [ "$saw_expected_version" = true ]; then
      reason="the new version answered but never became healthy (last: http=${last_code}) - check pod logs and required env keys"
    else
      reason="the old version is still live (last: http=${last_code} version=${last_ver}) - the rollout may be stuck, check Flux and pod status"
    fi
    echo "::error title=Deployment verification failed::${SERVICE} ${ENV_NAME} never served HTTP 200 + version ${EXPECTED_VERSION} within ${TIMEOUT}s (${probes} probes). ${reason}"
    echo "conclusion=failed" >> "$GITHUB_OUTPUT"
    write_summary "FAILED after ${elapsed}s (${probes} probes) - ${reason}"
    exit 1
  fi

  read -r code actual <<< "$(probe)"
  probes=$((probes + 1))
  last_code="$code"
  last_ver="$actual"
  if [ "$actual" = "$EXPECTED_VERSION" ]; then
    saw_expected_version=true
  fi

  if [ "$code" = "200" ] && [ "$actual" = "$EXPECTED_VERSION" ]; then
    printf '[%3ds] matched     http=%s version=%s   checking stability...\n' "$elapsed" "$code" "$actual"

    stable=true
    for i in $(seq 1 "$STABILITY_CHECKS"); do
      sleep "$STABILITY_INTERVAL"
      elapsed=$(( $(date +%s) - start_time ))
      read -r c v <<< "$(probe)"
      probes=$((probes + 1))
      if [ "$c" != "200" ] || [ "$v" != "$EXPECTED_VERSION" ]; then
        if [ "$v" != "$EXPECTED_VERSION" ]; then
          detail="version flapped back to ${v} - an old replica is still serving"
        else
          detail="health dropped (http=${c})"
        fi
        printf '[%3ds] stable %d/%d http=%s version=%s   FAILED - %s\n' "$elapsed" "$i" "$STABILITY_CHECKS" "$c" "$v" "$detail"
        stable=false
        break
      fi
      printf '[%3ds] stable %d/%d http=%s version=%s\n' "$elapsed" "$i" "$STABILITY_CHECKS" "$c" "$v"
    done

    if [ "$stable" = true ]; then
      echo "::notice title=Deployment verified::${SERVICE} ${EXPECTED_VERSION} is live and healthy in ${ENV_NAME} (${elapsed}s, ${probes} probes)"
      echo "conclusion=verified" >> "$GITHUB_OUTPUT"
      write_summary "verified in ${elapsed}s (${probes} probes, ${STABILITY_CHECKS}/${STABILITY_CHECKS} stable)"
      exit 0
    fi
    # Stability failed - resume polling until the version matches again or we time out.
  else
    printf '[%3ds] waiting     http=%s version=%s   %s\n' "$elapsed" "$code" "$actual" "$(diagnose "$code" "$actual")"
    sleep "$INTERVAL"
  fi
done
