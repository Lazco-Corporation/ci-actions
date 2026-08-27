#!/usr/bin/env bash
# npm-publish - publish an already-built package to an npm registry.
#
# The caller installs dependencies and builds; this script only gates the
# version, packs, publishes, and verifies. Packing runs through the project's
# own package manager (pnpm rewrites `workspace:` ranges); publishing always
# runs the packed tarball through npm, so auth and provenance have one code
# path. A tarball publish runs prepack/prepare (during pack) but not
# prepublishOnly/publish/postpublish - put release side effects in the workflow,
# not in package.json lifecycle scripts.
#
# Env inputs:
#   NPM_TOKEN         automation token with publish rights (empty only in dry runs)
#   PACKAGE_DIR       directory holding the package.json to publish (default .)
#   EXPECTED_VERSION  version package.json must declare; empty = trust package.json
#   DIST_TAG          dist-tag to move to this version (default latest)
#   ACCESS            public | restricted (default public)
#   PROVENANCE        "true" = sign the publish with a provenance attestation
#   REGISTRY          registry URL (default https://registry.npmjs.org)
#   PACKAGE_MANAGER   auto | npm | pnpm (default auto)
#   DRY_RUN           "true" = pack and validate without publishing
#
# Outputs (GITHUB_OUTPUT): result = published | already-published | dry-run,
#                          name, version

set -euo pipefail

PACKAGE_DIR="${PACKAGE_DIR:-.}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
DIST_TAG="${DIST_TAG:-latest}"
ACCESS="${ACCESS:-public}"
PROVENANCE="${PROVENANCE:-true}"
REGISTRY="${REGISTRY:-https://registry.npmjs.org}"
PACKAGE_MANAGER="${PACKAGE_MANAGER:-auto}"
DRY_RUN="${DRY_RUN:-false}"
NPM_TOKEN="${NPM_TOKEN:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ -n "$NPM_TOKEN" ]; then
  echo "::add-mask::${NPM_TOKEN}"
fi

work_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/npm-publish.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

pkg_name=""
pkg_version=""
file_count=""
size_kb=""

write_summary() {
  {
    echo "### npm publish"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Package | \`${pkg_name:-unknown}@${pkg_version:-unknown}\` |"
    echo "| Registry | ${REGISTRY} |"
    echo "| Dist-tag | \`${DIST_TAG}\` |"
    echo "| Result | $1 |"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
}

fail() {
  echo "::error title=$1::$2"
  write_summary "$3"
  exit 1
}

# --- read the manifest -------------------------------------------------------

manifest="${PACKAGE_DIR%/}/package.json"
if [ ! -f "$manifest" ]; then
  fail "npm publish failed" \
    "no package.json at ${manifest} - set package-dir to the directory that holds the package to publish" \
    "FAILED - no package.json at \`${manifest}\`"
fi

pkg_name="$(jq -r '.name // empty' "$manifest")"
pkg_version="$(jq -r '.version // empty' "$manifest")"

if [ -z "$pkg_name" ] || [ -z "$pkg_version" ]; then
  fail "npm publish failed" \
    "${manifest} has no 'name' or 'version' field - both are required to publish" \
    "FAILED - package.json has no name or version"
fi
if [ "$(jq -r '.private // false' "$manifest")" = "true" ]; then
  fail "npm publish failed" \
    "${pkg_name} is marked \"private\": true in package.json - remove the flag, or drop this action from the pipeline" \
    "FAILED - package is marked private"
fi

publish_registry="$(jq -r '.publishConfig.registry // empty' "$manifest")"
if [ -n "$publish_registry" ]; then
  REGISTRY="$publish_registry"
fi

# --- gate the version --------------------------------------------------------

wanted="${EXPECTED_VERSION#v}"
if [ -n "$wanted" ] && [ "$wanted" != "$pkg_version" ]; then
  fail "Version mismatch" \
    "the release asks for ${wanted} but ${manifest} declares ${pkg_version} - bump package.json to ${wanted}, then re-tag" \
    "FAILED - package.json says \`${pkg_version}\`, release asks for \`${wanted}\`"
fi

if ! printf '%s' "$pkg_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.+-]+)?$'; then
  fail "npm publish failed" \
    "'${pkg_version}' in ${manifest} is not a semver - fix the version field" \
    "FAILED - \`${pkg_version}\` is not a semver"
fi

is_prerelease=false
if printf '%s' "$pkg_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-'; then
  is_prerelease=true
fi
if [ "$is_prerelease" = true ] && [ "$DIST_TAG" = "latest" ]; then
  fail "npm publish failed" \
    "${pkg_version} is a prerelease, so it must not take the 'latest' dist-tag - set dist-tag to 'next' or 'beta'" \
    "FAILED - prerelease \`${pkg_version}\` may not take \`latest\`"
fi

# --- pick the package manager ------------------------------------------------

case "$PACKAGE_MANAGER" in
  npm | pnpm) pack_pm="$PACKAGE_MANAGER" ;;
  auto)
    declared="$(jq -r '.packageManager // empty' "$manifest")"
    if [ "${declared%%@*}" = "pnpm" ] || [ -f "${PACKAGE_DIR%/}/pnpm-lock.yaml" ] || [ -f "pnpm-lock.yaml" ]; then
      pack_pm="pnpm"
    else
      pack_pm="npm"
    fi
    ;;
  *)
    fail "npm publish failed" \
      "package-manager must be 'auto', 'npm' or 'pnpm' (got '${PACKAGE_MANAGER}')" \
      "FAILED - bad package-manager input"
    ;;
esac

if ! command -v "$pack_pm" > /dev/null 2>&1; then
  fail "npm publish failed" \
    "'${pack_pm}' is not on PATH - add the matching setup step (pnpm/action-setup or actions/setup-node) before this action" \
    "FAILED - \`${pack_pm}\` not on PATH"
fi

echo "::group::npm publish"
echo "  Package     : ${pkg_name}@${pkg_version}"
echo "  Registry    : ${REGISTRY}"
echo "  Dist-tag    : ${DIST_TAG}"
echo "  Access      : ${ACCESS}"
echo "  Provenance  : ${PROVENANCE}"
echo "  Pack with   : ${pack_pm} ($(${pack_pm} --version))"
echo "  Publish with: npm ($(npm --version))"
echo "  Dry run     : ${DRY_RUN}"
echo "::endgroup::"

# --- auth and provenance prerequisites ---------------------------------------

if [ "$DRY_RUN" != "true" ]; then
  if [ -z "$NPM_TOKEN" ]; then
    fail "Missing npm token" \
      "the token input is empty - add NPM_TOKEN to Infisical /ci and list it in the infisical-fetch required-keys" \
      "FAILED - npm token is empty"
  fi
  if [ "$PROVENANCE" = "true" ] && [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    fail "Missing OIDC permission" \
      "provenance needs an OIDC token - add 'permissions: id-token: write' to the calling job, or set provenance: false" \
      "FAILED - calling job lacks \`id-token: write\`"
  fi
fi

if [ -n "$NPM_TOKEN" ]; then
  registry_host="${REGISTRY#*://}"
  npmrc="${work_dir}/npmrc"
  (
    umask 077
    {
      echo "registry=${REGISTRY}"
      echo "//${registry_host%/}/:_authToken=${NPM_TOKEN}"
    } > "$npmrc"
  )
  export NPM_CONFIG_USERCONFIG="$npmrc"
fi

# --- skip when this version is already on the registry -----------------------

view_log="${work_dir}/view.log"
if npm view "${pkg_name}@${pkg_version}" version --registry "$REGISTRY" > "$view_log" 2>&1; then
  echo "registry check: ${pkg_name}@${pkg_version} is already published"
  echo "::notice title=npm publish skipped::${pkg_name}@${pkg_version} is already on ${REGISTRY} - npm versions are immutable, so this run is a no-op"
  {
    echo "result=already-published"
    echo "name=${pkg_name}"
    echo "version=${pkg_version}"
  } >> "$GITHUB_OUTPUT"
  write_summary "already published - no-op"
  exit 0
fi

if ! grep -q "E404" "$view_log"; then
  echo "::group::npm view output"
  cat "$view_log"
  echo "::endgroup::"
  fail "Registry check failed" \
    "could not ask ${REGISTRY} about ${pkg_name}@${pkg_version}, and the answer was not a 404 - check the npm token scope and that the registry is reachable, then re-run" \
    "FAILED - registry check errored before publishing"
fi
echo "registry check: ${pkg_name}@${pkg_version} is not published yet"

# --- refuse to move `latest` backwards ---------------------------------------

# `sort -V` orders 1.0.0-rc.1 above 1.0.0, so compare release cores only.
release_core() { printf '%s' "${1%%-*}"; }

if [ "$DIST_TAG" = "latest" ]; then
  live_latest="$(npm view "${pkg_name}@latest" version --registry "$REGISTRY" 2> /dev/null || true)"
  if [ -n "$live_latest" ] && [ "$live_latest" != "$pkg_version" ]; then
    newest="$(printf '%s\n%s\n' "$(release_core "$live_latest")" "$(release_core "$pkg_version")" | sort -V | tail -n 1)"
    if [ "$newest" != "$(release_core "$pkg_version")" ]; then
      fail "npm publish refused" \
        "'latest' is ${live_latest}, which is newer than ${pkg_version} - publishing would downgrade every plain 'npm install ${pkg_name}'. Set dist-tag to a side tag (e.g. 'hotfix') for this back-version release." \
        "FAILED - would move \`latest\` back from \`${live_latest}\` to \`${pkg_version}\`"
    fi
  fi
fi

# --- pack --------------------------------------------------------------------

pack_dir="${work_dir}/pack"
mkdir -p "$pack_dir"
if ! (cd "$PACKAGE_DIR" && "$pack_pm" pack --pack-destination "$pack_dir" > "${work_dir}/pack.log" 2>&1); then
  echo "::group::${pack_pm} pack output"
  cat "${work_dir}/pack.log"
  echo "::endgroup::"
  fail "npm pack failed" \
    "${pack_pm} could not pack ${pkg_name}@${pkg_version} - run '${pack_pm} pack' locally to reproduce (a failing prepack or prepare script is the usual cause)" \
    "FAILED - pack step"
fi

tarball="$(find "$pack_dir" -maxdepth 1 -name '*.tgz' | head -n 1)"
if [ -z "$tarball" ]; then
  fail "npm pack failed" \
    "${pack_pm} pack produced no .tgz in ${pack_dir} - check the 'files' field in package.json" \
    "FAILED - pack produced no tarball"
fi

file_count="$(tar -tzf "$tarball" | grep -cv '/$' || true)"
size_kb="$(( ($(wc -c < "$tarball") + 1023) / 1024 ))"
echo "packed ${pkg_name}@${pkg_version}: ${file_count} files, ${size_kb} KB"
echo "::group::Tarball contents"
tar -tzf "$tarball"
echo "::endgroup::"

# npm always packs package.json plus any README/LICENSE/CHANGELOG it finds, so
# count only the files a consumer can actually require.
code_files="$(tar -tzf "$tarball" \
  | grep -cviE '(/$|^package/(package\.json|readme([.-][^/]*)?|license([.-][^/]*)?|licence([.-][^/]*)?|changelog([.-][^/]*)?|notice)$)' || true)"
if [ "$code_files" -eq 0 ]; then
  fail "npm pack failed" \
    "the tarball for ${pkg_name}@${pkg_version} holds no code - the build step produced nothing, or the 'files' field excludes the build output" \
    "FAILED - tarball holds no code"
fi

# --- publish -----------------------------------------------------------------

publish_args=(publish "$tarball" --registry "$REGISTRY" --tag "$DIST_TAG" --access "$ACCESS")
if [ "$DRY_RUN" = "true" ]; then
  publish_args+=(--dry-run)
elif [ "$PROVENANCE" = "true" ]; then
  publish_args+=(--provenance)
fi

if ! npm "${publish_args[@]}"; then
  if [ "$PROVENANCE" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    hint="if the log names provenance, set provenance: false to isolate it; otherwise check that the npm token may publish ${pkg_name}"
  else
    hint="check that the npm token may publish ${pkg_name}"
  fi
  fail "npm publish failed" \
    "could not publish ${pkg_name}@${pkg_version} to ${REGISTRY} - ${hint}" \
    "FAILED - publish step"
fi

{
  echo "name=${pkg_name}"
  echo "version=${pkg_version}"
} >> "$GITHUB_OUTPUT"

if [ "$DRY_RUN" = "true" ]; then
  echo "dry run: publish validated, nothing was sent to ${REGISTRY}"
  echo "::notice title=npm publish dry run::${pkg_name}@${pkg_version} packed and validated, not published"
  echo "result=dry-run" >> "$GITHUB_OUTPUT"
  write_summary "dry run - packed and validated only"
  exit 0
fi

# --- verify ------------------------------------------------------------------

echo "result=published" >> "$GITHUB_OUTPUT"

verified=false
for attempt in 1 2 3 4 5; do
  live_tag="$(npm view "${pkg_name}@${DIST_TAG}" version --registry "$REGISTRY" 2> /dev/null || true)"
  if [ "$live_tag" = "$pkg_version" ]; then
    echo "attempt ${attempt}/5: ${DIST_TAG} -> ${pkg_version}"
    verified=true
    break
  fi
  echo "attempt ${attempt}/5: ${DIST_TAG} -> ${live_tag:-(none)}, waiting for the registry to catch up..."
  sleep 3
done

if [ "$verified" != true ]; then
  fail "npm publish unverified" \
    "${pkg_name}@${pkg_version} was published but the '${DIST_TAG}' tag still points elsewhere - run 'npm dist-tag add ${pkg_name}@${pkg_version} ${DIST_TAG}' once the registry catches up" \
    "published, but the \`${DIST_TAG}\` tag did not move"
fi

echo "::notice title=npm package published::${pkg_name}@${pkg_version} is live on ${REGISTRY} (${DIST_TAG}, ${file_count} files, ${size_kb} KB)"
write_summary "published - ${file_count} files, ${size_kb} KB"
