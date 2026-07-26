#!/usr/bin/env bash
# gitops-writeback - pin a new image tag into a cloud-infra-gitops overlay and
# push it, with a rebase-retry loop for simultaneous release runs.
#
# Runs with cwd = the gitops repo checkout (the action checks it out into gitops/).
#
# Env inputs:
#   SERVICE        service directory under apps/ (e.g. api, frontend)
#   ENV_NAME       overlay environment (staging | prod)
#   IMAGE_NAME     full image name incl. registry org (<org>/<name>)
#   NEW_TAG        tag to pin (<version>-<sha>)
#   GITOPS_REPO    owner/repo, used for the summary commit link
#   TARGET_BRANCH  branch to push to (default main)
#   OVERLAY_PATH   override the derived apps/<svc>/overlays/<env>/kustomization.yaml
#
# Outputs (GITHUB_OUTPUT): result = pushed | already-up-to-date, commit_sha

set -euo pipefail

TARGET_BRANCH="${TARGET_BRANCH:-main}"
OVERLAY_PATH="${OVERLAY_PATH:-apps/${SERVICE}/overlays/${ENV_NAME}/kustomization.yaml}"
GITOPS_REPO="${GITOPS_REPO:-Lazco-Corporation/cloud-infra-gitops}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ ! -f "$OVERLAY_PATH" ]; then
  echo "::error title=GitOps write-back failed::overlay ${OVERLAY_PATH} does not exist in ${GITOPS_REPO}"
  exit 1
fi

if ! yq -e '.images[] | select(.name == strenv(IMAGE_NAME))' "$OVERLAY_PATH" > /dev/null 2>&1; then
  echo "::error title=GitOps write-back failed::no image entry named '${IMAGE_NAME}' in ${OVERLAY_PATH}"
  exit 1
fi

old_tag="$(yq '.images[] | select(.name == strenv(IMAGE_NAME)) | .newTag' "$OVERLAY_PATH")"

echo "::group::GitOps write-back"
echo "  Service     : ${SERVICE}"
echo "  Environment : ${ENV_NAME}"
echo "  Overlay     : ${OVERLAY_PATH}"
echo "  Image       : ${IMAGE_NAME}"
echo "  Tag         : ${old_tag} -> ${NEW_TAG}"
echo "  Target      : ${TARGET_BRANCH}"
echo "::endgroup::"

yq -i '(.images[] | select(.name == strenv(IMAGE_NAME)) | .newTag) = strenv(NEW_TAG)' "$OVERLAY_PATH"

applied="$(yq '.images[] | select(.name == strenv(IMAGE_NAME)) | .newTag' "$OVERLAY_PATH")"
if [ "$applied" != "$NEW_TAG" ]; then
  echo "::error title=GitOps write-back failed::newTag not applied (got '${applied}', expected '${NEW_TAG}')"
  exit 1
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if git diff --quiet; then
  echo "::notice title=GitOps already up to date::${OVERLAY_PATH} already pins ${NEW_TAG} - nothing to write back"
  echo "result=already-up-to-date" >> "$GITHUB_OUTPUT"
  {
    echo "### GitOps write-back"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Overlay | \`${OVERLAY_PATH}\` |"
    echo "| Result | already pinned to \`${NEW_TAG}\` - no-op |"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

echo "::group::Overlay diff"
git diff
echo "::endgroup::"

git add -A
git commit -m "chore(${SERVICE}): ${ENV_NAME} ${NEW_TAG} [ci]"

for attempt in 1 2 3 4 5; do
  if git push origin "HEAD:${TARGET_BRANCH}"; then
    commit_sha="$(git rev-parse --short HEAD)"
    echo "push succeeded (attempt ${attempt}/5)"
    echo "::notice title=GitOps write-back pushed::${SERVICE} ${ENV_NAME}: ${old_tag} -> ${NEW_TAG} (${GITOPS_REPO}@${commit_sha}, attempt ${attempt})"
    echo "result=pushed" >> "$GITHUB_OUTPUT"
    echo "commit_sha=$commit_sha" >> "$GITHUB_OUTPUT"
    {
      echo "### GitOps write-back"
      echo ""
      echo "| | |"
      echo "|---|---|"
      echo "| Overlay | \`${OVERLAY_PATH}\` |"
      echo "| Tag | \`${old_tag}\` -> \`${NEW_TAG}\` |"
      echo "| Commit | [\`${commit_sha}\`](https://github.com/${GITOPS_REPO}/commit/${commit_sha}) (attempt ${attempt}) |"
      echo ""
    } >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
  echo "push rejected (attempt ${attempt}/5) - rebasing on origin/${TARGET_BRANCH} and retrying..."
  git fetch origin "${TARGET_BRANCH}"
  git rebase "origin/${TARGET_BRANCH}"
done

echo "::error title=GitOps write-back failed::could not push to ${TARGET_BRANCH} after 5 attempts (rebase-retry exhausted) - re-run the workflow"
exit 1
