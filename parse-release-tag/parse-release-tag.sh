#!/usr/bin/env bash
# parse-release-tag - split a <svc>/<env>-<version> release tag into its parts,
# validate each, and emit them as step outputs + a run-summary table.
#
# Env inputs:
#   REF_NAME         github.ref_name (the tag, e.g. api/staging-0.63.94)
#   COMMIT_SHA       github.sha (full 40-char sha; the short form tags the image)
#   ALLOWED_SERVICES comma-separated service names (e.g. "api,collector,billing-worker")
#   IMAGE_PREFIX     registry-agnostic image prefix; image name = <prefix>-<svc>
#
# Outputs (GITHUB_OUTPUT): service, env, version, sha, image_name

set -euo pipefail

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

grammar="<svc>/<env>-<version>"

service="${REF_NAME%%/*}"
rest="${REF_NAME#*/}"
env_name="${rest%%-*}"
version="${rest#*-}"
sha="${COMMIT_SHA:0:7}"

first_allowed="${ALLOWED_SERVICES%%,*}"
example="${first_allowed}/staging-1.2.3"

service_ok=false
for candidate in $(printf '%s' "$ALLOWED_SERVICES" | tr ',' ' '); do
  if [ "$service" = "$candidate" ]; then
    service_ok=true
    break
  fi
done
if [ "$service_ok" != true ]; then
  echo "::error title=Invalid release tag::'${REF_NAME}' - unknown service '${service}' (allowed: ${ALLOWED_SERVICES}). Tag grammar: ${grammar}, e.g. ${example}"
  exit 1
fi

case "$env_name" in
  staging | prod) ;;
  *)
    echo "::error title=Invalid release tag::'${REF_NAME}' - unknown env '${env_name}' (expected staging|prod). Tag grammar: ${grammar}, e.g. ${example}"
    exit 1
    ;;
esac

if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  echo "::error title=Invalid release tag::'${REF_NAME}' - '${version}' is not a semver. Tag grammar: ${grammar}, e.g. ${example}"
  exit 1
fi

image_name="${IMAGE_PREFIX}-${service}"

{
  echo "service=$service"
  echo "env=$env_name"
  echo "version=$version"
  echo "sha=$sha"
  echo "image_name=$image_name"
} >> "$GITHUB_OUTPUT"

{
  echo "### Release \`${REF_NAME}\`"
  echo ""
  echo "| | |"
  echo "|---|---|"
  echo "| Service / Env | \`${service}\` / \`${env_name}\` |"
  echo "| Version | \`${version}\` |"
  echo "| Image | \`${image_name}:${version}-${sha}\` |"
  echo ""
} >> "$GITHUB_STEP_SUMMARY"

echo "::notice title=Release tag parsed::${service} ${version} -> ${env_name} (image ${image_name}:${version}-${sha})"
