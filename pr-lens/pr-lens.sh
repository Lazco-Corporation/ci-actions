#!/usr/bin/env bash
# pr-lens - draw a pull request's architecture and data flow with the PR Lens
# CLI, publish the SVGs to a data branch, push the drawing to a canvas on
# prlens.dev, and keep one comment on the pull request up to date.
#
# The publish and comment steps are adapted from coldteadotai/pr-lens
# packages/action (MIT, see LICENSE-pr-lens). Two changes from upstream:
#   - The CLI and every dependency install from package-lock.json. Upstream
#     runs `npx`, which resolves caret ranges again on every run.
#   - The SVGs are linked through <server>/<repo>/raw/, not
#     raw.githubusercontent.com. A browser sends no GitHub session to
#     raw.githubusercontent.com, so a private repo's images there never load.
#
# Usage: pr-lens.sh <check | install | analyze | render | publish | canvas | comment>
#
# Env inputs:
#   GITHUB_REPOSITORY  owner/repo (set by Actions)
#   GITHUB_SERVER_URL  default https://github.com
#   RUNNER_TEMP        work directory root (default /tmp)
#   PR_NUMBER          pull request number                          (check, analyze, publish, canvas, comment)
#   BASE_SHA           pull request base commit                     (check, analyze)
#   HEAD_SHA           pull request head commit                     (check, analyze, publish, canvas, comment)
#   ACTION_PATH        directory holding package.json + lockfile    (install)
#   PR_LENS_BASE_URL   OpenAI-compatible endpoint base              (analyze)
#   PR_LENS_MODEL      model name on that endpoint                  (analyze)
#   PR_LENS_API_KEY    key for that endpoint                        (analyze)
#   LENS               comma-separated lenses, empty = both         (analyze)
#   DATA_BRANCH        orphan branch for the SVGs (default pr-lens) (publish)
#   GITHUB_TOKEN       contents: write (publish), pull-requests: write (canvas, comment)
#   PR_LENS_TOKEN      PR Lens account token that owns the canvases (canvas)
#   ASSETS_URL         base URL of the published SVGs               (comment)
#   CANVAS_ID          canvas to link, empty = no link              (comment)
#   COMMENT_AUTHOR     login that owns the comment (default github-actions[bot]) (canvas, comment)
#   BRANDING           true | false, the PR Lens footer (default true) (comment)
#
# Outputs (GITHUB_OUTPUT):
#   graph       path of the analyzed graph document  (analyze)
#   assets_url  base URL of the published SVGs        (publish)
#   canvas_id   id of the pushed canvas, empty on failure (canvas)
#   canvas_url  view link of that canvas              (canvas)
#   result      posted | updated | superseded         (comment)

set -euo pipefail

STEP="${1:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
DATA_BRANCH="${DATA_BRANCH:-pr-lens}"
COMMENT_AUTHOR="${COMMENT_AUTHOR:-github-actions[bot]}"
BRANDING="${BRANDING:-true}"

CANVAS_APP="https://prlens.dev"
CANVAS_MARKER="pr-lens-canvas"

WORK="${RUNNER_TEMP}/pr-lens"
CLI_DIR="${RUNNER_TEMP}/pr-lens-cli"
GRAPH="${WORK}/graph.json"
ASSETS="${WORK}/assets"

cli() {
  "${CLI_DIR}/node_modules/.bin/pr-lens" "$@"
}

check() {
  if [ -z "${PR_NUMBER:-}" ]; then
    echo "::error title=PR Lens cannot run::this run has no pull request - trigger on pull_request, or pass pr-number, base-sha, and head-sha"
    exit 1
  fi
  for sha in "${BASE_SHA}" "${HEAD_SHA}"; do
    if ! git cat-file -e "${sha}^{commit}" 2> /dev/null; then
      echo "::error title=PR Lens cannot run::commit ${sha} is not in this checkout - check out with fetch-depth: 0"
      exit 1
    fi
  done
  echo "::group::PR Lens"
  echo "  Repository   : ${GITHUB_REPOSITORY}"
  echo "  Pull request : #${PR_NUMBER}"
  echo "  Base         : ${BASE_SHA}"
  echo "  Head         : ${HEAD_SHA}"
  echo "  Data branch  : ${DATA_BRANCH}"
  echo "::endgroup::"
}

install() {
  rm -rf "${CLI_DIR}"
  mkdir -p "${CLI_DIR}"
  cp "${ACTION_PATH}/package.json" "${ACTION_PATH}/package-lock.json" "${CLI_DIR}/"
  # A dependency install script is code nobody reviewed, so none of them run.
  npm ci --prefix "${CLI_DIR}" --ignore-scripts --no-audit --no-fund --loglevel=error
  echo "installed pr-lens $(cli --version) from the lockfile"
}

analyze() {
  mkdir -p "${WORK}"
  local lens_args=()
  if [ -n "${LENS:-}" ]; then
    lens_args=(--lens "${LENS}")
  fi
  # The CLI reads the key from the variable that --api-key-env names, so the
  # key never appears in a command line.
  cli analyze \
    --base "${BASE_SHA}" \
    --head "${HEAD_SHA}" \
    --pr "${PR_NUMBER}" \
    --provider openai-compatible \
    --base-url "${PR_LENS_BASE_URL}" \
    --model "${PR_LENS_MODEL}" \
    --api-key-env PR_LENS_API_KEY \
    ${lens_args[@]+"${lens_args[@]}"} \
    --out "${GRAPH}"
  echo "graph=${GRAPH}" >> "$GITHUB_OUTPUT"
}

render() {
  cli render "${GRAPH}" --out "${ASSETS}"
}

# GitHub proxies comment images through a cache that never revalidates, so a
# changed diagram must arrive at a new URL. The renderer names each file after
# the hash of its contents, and each run writes its own directory once.
publish() {
  local directory="pr/${PR_NUMBER}/${HEAD_SHA}"
  local workspace="${RUNNER_TEMP}/pr-lens-publish"
  local basic_auth
  local pushed=""
  basic_auth="$(printf 'x-access-token:%s' "${GITHUB_TOKEN}" | base64 | tr -d '\n')"

  # Every run of every pull request shares this branch, so a lost push race is
  # ordinary: fetch the tip again and replay onto it. Two runs never write the
  # same path, so a retry only has to catch up. Only the push is allowed to
  # fail. Any other failure stops the script.
  for attempt in 1 2 3 4 5; do
    rm -rf "${workspace}"
    mkdir -p "${workspace}"
    git -C "${workspace}" init --quiet
    git -C "${workspace}" config user.name "github-actions[bot]"
    git -C "${workspace}" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git -C "${workspace}" config "http.${GITHUB_SERVER_URL}/.extraheader" "AUTHORIZATION: basic ${basic_auth}"
    git -C "${workspace}" remote add origin "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"

    if git -C "${workspace}" fetch --quiet --depth=1 origin "${DATA_BRANCH}" 2> /dev/null; then
      git -C "${workspace}" checkout --quiet -b "${DATA_BRANCH}" FETCH_HEAD
    else
      git -C "${workspace}" checkout --quiet --orphan "${DATA_BRANCH}"
    fi

    mkdir -p "${workspace}/${directory}"
    cp "${ASSETS}"/*.svg "${workspace}/${directory}/"
    git -C "${workspace}" add "${directory}"

    if git -C "${workspace}" diff --quiet --cached; then
      pushed="already"
      break
    fi

    git -C "${workspace}" commit --quiet -m "PR Lens: #${PR_NUMBER} at ${HEAD_SHA}"

    if git -C "${workspace}" push --quiet origin "${DATA_BRANCH}"; then
      pushed="yes"
      break
    fi

    echo "push rejected (attempt ${attempt}/5) - ${DATA_BRANCH} moved, fetching it again..."
    sleep "$((attempt * 3))"
  done

  if [ -z "${pushed}" ]; then
    echo "::error title=PR Lens publish failed::could not push to ${DATA_BRANCH} after 5 attempts - give the workflow a per-pull-request concurrency group, then re-run"
    exit 1
  fi

  if [ "${pushed}" = "already" ]; then
    echo "this render is already published at ${DATA_BRANCH}:${directory}"
  else
    echo "published to ${DATA_BRANCH}:${directory} (attempt ${attempt}/5)"
  fi
  echo "assets_url=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/raw/${DATA_BRANCH}/${directory}" >> "$GITHUB_OUTPUT"
}

# Whether this run still draws the pull request's current head. A run that was
# overtaken while it drew must not replace a newer diagram with an older one.
# Only GitHub knows the current head, and not knowing is a failure, never a
# reason to stay quiet. `set -e` does not apply inside a function used as an
# `if` condition, so a failed lookup exits here by hand.
overtaken() {
  local current
  if ! current="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq .head.sha)"; then
    echo "::error title=PR Lens failed::could not read the head commit of #${PR_NUMBER} from GitHub - re-run the workflow"
    exit 1
  fi
  if [ -z "${current}" ]; then
    echo "::error title=PR Lens failed::GitHub named no head commit for #${PR_NUMBER} - re-run the workflow"
    exit 1
  fi
  if [ "${current}" = "${HEAD_SHA}" ]; then
    return 1
  fi
  echo "::notice title=PR Lens skipped::#${PR_NUMBER} moved on to ${current} - the run for that commit draws it"
  echo "result=superseded" >> "$GITHUB_OUTPUT"
  return 0
}

# The PR Lens comment on the pull request, as one JSON line, or nothing.
# Anyone can post the marker, so the marker alone does not make a comment
# ours. Only a comment that COMMENT_AUTHOR wrote counts.
own_comment() {
  local marker
  marker="$(cli comment --print-marker)" || return 1
  gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --paginate --jq '.[]' \
    > "${WORK}/comments.jsonl" || return 1
  jq -c --arg author "${COMMENT_AUTHOR}" --arg marker "${marker}" \
    'select(.user.login == $author) | select(.body | startswith($marker))' \
    "${WORK}/comments.jsonl" | head -n 1
}

# Pushes the drawing and writes the canvas id to ${WORK}/canvas-id. The last
# run left its canvas id in the comment, so every run pushes a new revision of
# one canvas per pull request. The account token owns every canvas it mints,
# which is what lets a fresh runner push to one without its write token.
# The CLI keeps a registry under .pr-lens/ and edits .gitignore, so it runs in
# a scratch repo, never in the pull request's checkout. `set -e` does not
# apply here, because canvas() calls this as an `if` condition, so every
# command checks its own status.
push_canvas() {
  local scratch="${RUNNER_TEMP}/pr-lens-canvas"
  local mine
  local id=""
  rm -rf "${scratch}" || return 1
  mkdir -p "${scratch}" || return 1
  git -C "${scratch}" init --quiet || return 1
  cd "${scratch}" || return 1

  mine="$(own_comment)" || return 1
  if [ -n "${mine}" ]; then
    id="$(jq -r '.body' <<< "${mine}" |
      sed -nE "s/^<!-- ${CANVAS_MARKER} ([A-Za-z0-9_-]{22}) -->\$/\1/p" | head -n 1)"
  fi

  if [ -n "${id}" ]; then
    if cli canvas pull "${id}" -o "${scratch}/previous.graph.json" 2> "${scratch}/pull.err"; then
      cli canvas push "${ASSETS}/drawn.graph.json" --canvas "${id}" || return 1
    elif grep -q '\[CANVAS_UNKNOWN\]' "${scratch}/pull.err"; then
      echo "canvas ${id} no longer exists - minting a new one"
      id=""
    else
      cat "${scratch}/pull.err" >&2
      return 1
    fi
  fi

  if [ -z "${id}" ]; then
    cli canvas push "${ASSETS}/drawn.graph.json" --name "${GITHUB_REPOSITORY}#${PR_NUMBER}" || return 1
    id="$(cli canvas list --json | jq -r '.canvases[0].id // empty')" || return 1
  fi

  if ! [[ "${id}" =~ ^[A-Za-z0-9_-]{22}$ ]]; then
    echo "the CLI named no canvas id (got '${id}')" >&2
    return 1
  fi
  printf '%s' "${id}" > "${WORK}/canvas-id"
}

# A failure here costs the canvas link, never the comment: the diagrams in
# the comment come from the data branch, not from prlens.dev.
canvas() {
  export GH_TOKEN="${GITHUB_TOKEN}"
  if overtaken; then
    return 0
  fi

  rm -f "${WORK}/canvas-id"
  if ! push_canvas; then
    echo "::warning title=PR Lens canvas skipped::could not push #${PR_NUMBER} to ${CANVAS_APP} - the comment goes out without the canvas link, and the next run tries again"
    return 0
  fi

  local id
  id="$(cat "${WORK}/canvas-id")"
  echo "canvas_id=${id}" >> "$GITHUB_OUTPUT"
  echo "canvas_url=${CANVAS_APP}/c/${id}" >> "$GITHUB_OUTPUT"
  echo "::notice title=PR Lens canvas pushed::#${PR_NUMBER} at ${CANVAS_APP}/c/${id}"
}

comment() {
  export GH_TOKEN="${GITHUB_TOKEN}"
  local body="${WORK}/comment.md"
  local branding_args=()
  if [ "${BRANDING}" = "false" ]; then
    branding_args=(--no-branding)
  fi

  if overtaken; then
    return 0
  fi

  cli comment \
    --graph "${ASSETS}/drawn.graph.json" \
    --manifest "${ASSETS}/manifest.json" \
    --asset-base-url "${ASSETS_URL}" \
    ${branding_args[@]+"${branding_args[@]}"} \
    --out "${body}"

  # The link goes right under the marker, which must stay the first line. The
  # id rides in its own hidden line, where the next run's canvas step reads it.
  local canvas_url=""
  if [ -n "${CANVAS_ID:-}" ]; then
    canvas_url="${CANVAS_APP}/c/${CANVAS_ID}"
    {
      head -n 1 "${body}"
      echo "<!-- ${CANVAS_MARKER} ${CANVAS_ID} -->"
      echo ""
      echo "<p><a href=\"${canvas_url}\"><b>Open the interactive canvas</b></a> · zoom and pan, click an arrow for its payload, or play the walkthrough</p>"
      tail -n +2 "${body}"
    } > "${body}.canvas"
    mv "${body}.canvas" "${body}"
  fi

  local mine
  mine="$(own_comment)"

  # Checked again, because composing the body and listing the comments take
  # seconds, and this check guards the write.
  if overtaken; then
    return 0
  fi

  local result
  if [ -n "${mine}" ]; then
    jq -Rs '{body: .}' < "${body}" |
      gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/$(printf '%s' "${mine}" | jq -r '.id')" \
        --input - --silent
    result="updated"
  else
    jq -Rs '{body: .}' < "${body}" |
      gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --input - --silent
    result="posted"
  fi

  echo "::notice title=PR Lens comment ${result}::#${PR_NUMBER} at ${HEAD_SHA}"
  echo "result=${result}" >> "$GITHUB_OUTPUT"
  {
    echo "### PR Lens"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| Pull request | #${PR_NUMBER} |"
    echo "| Head | \`${HEAD_SHA}\` |"
    echo "| Comment | ${result} |"
    echo "| Diagrams | [\`${DATA_BRANCH}\`](${ASSETS_URL}) |"
    echo "| Canvas | ${canvas_url:-none} |"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
}

case "${STEP}" in
  check | install | analyze | render | publish | canvas | comment) "${STEP}" ;;
  *)
    echo "::error title=PR Lens misconfigured::unknown step '${STEP}' - use check, install, analyze, render, publish, canvas, or comment"
    exit 1
    ;;
esac
