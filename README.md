# ci-actions

Shared composite actions for Lazco's tag-driven release pipelines
(`cloud-backend`, `cloud-frontend`, npm packages). One directory per action;
each wraps a plain bash script so the logic is reviewable, shellcheck-able, and
runnable locally.

## Actions

| Action | Purpose |
|---|---|
| `infisical-fetch` | Export Infisical `/ci` secrets as masked env vars (OIDC), with fail-fast `required-keys` validation |
| `parse-release-tag` | Split `<svc>/<env>-<version>` into `(service, env, version, sha, image_name)` with validation |
| `require-tag-on-main` | Fail-closed check that the release branch contains the tagged commit |
| `prod-actor-guard` | Fail-closed `PROD_RELEASE_ACTORS` allow-list check for prod tags |
| `assert-promoted-image` | Assert the exact `<version>-<sha>` image exists (prod never rebuilds) |
| `gitops-writeback` | Pin `newTag` in a `cloud-infra-gitops` overlay and push (rebase-retry loop) |
| `verify-deployment` | Poll the health endpoint until HTTP 200 + expected version, then confirm stability |
| `npm-publish` | Publish a built package: version-gate, skip if already published, sign with provenance, verify the dist-tag |
| `discord-notify` | Failure notification naming the failed job(s) (from the `needs` context) |
| `pr-lens` | Describe a pull request in Traditional Chinese, draw the flows it changes, and keep one comment up to date |

## Usage

Consumers pin the floating major tag:

```yaml
- uses: Lazco-Corporation/ci-actions/verify-deployment@v1
  with:
    service: api
    env-name: prod
    url: ${{ env.DEPLOY_CHECK_URL }}
    expected-version: ${{ needs.parse.outputs.version }}
```

The repo is public, so any Lazco repo can call these actions, public or private.
A private action repo cannot be called from a public repo, which is why this one
is public.

Every tag-triggered release must call `require-tag-on-main` before it builds or
ships anything. A tag can point at any commit, including one that no branch
holds, and neither a branch filter nor `prod-actor-guard` catches that:

```yaml
- uses: Lazco-Corporation/ci-actions/require-tag-on-main@v1
  with:
    repository: ${{ github.repository }}
    sha: ${{ github.sha }}
    ref-name: ${{ github.ref_name }}
    token: ${{ github.token }}
```

It reads the compare API, so it needs no checkout and no git history. Put it in
the first job the release depends on.

To roll this action back, move `v1` back to the previous good commit and force-push the tag, as `Releasing a change` shows.
Callers pin `@v1`, so the rollback reaches every caller repo at the same time.
It also rolls back every other action changed since that commit.

Requirements of calling jobs:

- Jobs calling `infisical-fetch` must declare `permissions: id-token: write`
  (OIDC tokens are minted per job; composite actions cannot declare permissions).
- Jobs calling `npm-publish` with the default `provenance: true` need the same
  `permissions: id-token: write`.
- Jobs calling `require-tag-on-main` need `contents: read` on `GITHUB_TOKEN`.
  A job-level `permissions:` block that lists only `id-token: write` drops it,
  the compare API then answers 404, and the guard refuses every release.
  The reverse also holds for a private repo that exists, with the default `branch` and `sha: ${{ github.sha }}`.
  There, `GitHub answered HTTP 404` means the calling job lost `contents: read`.
- Jobs calling `pr-lens` need `contents: write`, `pull-requests: write`, and
  `id-token: write`, and a checkout with `fetch-depth: 0`.
- Scripts need `bash`, `curl`, `jq`, `git`, `docker` (assert-promoted-image
  only), `npm` (npm-publish and pr-lens only), `gh` (pr-lens only).
  All are preinstalled on GitHub `ubuntu-latest`, on Blacksmith runners and on Boat runners.
  `gitops-writeback` installs its own `yq`, pinned by version and checksum, because a Boat runner has none.

### npm-publish

The action only publishes. The calling job installs dependencies and builds
first, and passes the npm token from Infisical `/ci`:

```yaml
publish:
  runs-on: ubuntu-latest
  permissions:
    contents: read
    id-token: write # provenance
  steps:
    - uses: actions/checkout@v4
    - uses: pnpm/action-setup@v4
    - uses: actions/setup-node@v4
      with:
        node-version: "22"
        cache: pnpm
    - uses: Lazco-Corporation/ci-actions/infisical-fetch@v1
      with:
        project-slug: lazco-<package>
        env-slug: prod
        identity-id: ${{ vars.INFISICAL_IDENTITY_ID }}
        required-keys: NPM_TOKEN
    - run: pnpm install --frozen-lockfile
    - run: pnpm build
    - uses: Lazco-Corporation/ci-actions/npm-publish@v1
      with:
        token: ${{ env.NPM_TOKEN }}
        expected-version: ${{ github.ref_name }}
```

Behavior worth knowing:

- `expected-version` gates package.json against the release tag (a leading `v`
  is stripped). The run fails when the two disagree.
- A version already on the registry is a no-op (`result=already-published`),
  so a re-run of the same tag is safe.
- The action refuses to move `latest` backwards, and refuses `latest` for a
  prerelease version. Use `dist-tag` for those releases.
- It packs with the project's package manager (pnpm rewrites `workspace:`
  ranges) and publishes the tarball with `npm`.
- A tarball publish runs `prepack`/`prepare` but not `prepublishOnly`,
  `publish`, or `postpublish`. Put release side effects in the workflow.

### pr-lens

Describes a pull request in Traditional Chinese and draws the flows it changes
with the [PR Lens](https://github.com/coldteadotai/pr-lens) renderer.
It asks a model about the diff and the pull request description, renders dark
SVGs, pushes them to an orphan `pr-lens` branch, pushes the drawing to a canvas
on prlens.dev, and posts one comment that later runs update in place. The
comment links the canvas, the interactive view: zoom and pan.

Call it through the reusable workflow `.github/workflows/reusable-pr-lens.yml`.
It picks the pull requests, skips the ones PR Lens cannot draw, and sets the
concurrency group per pull request:

```yaml
name: PR Lens

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  pr-lens:
    uses: Lazco-Corporation/ci-actions/.github/workflows/reusable-pr-lens.yml@v1
    permissions:
      contents: write
      pull-requests: write
      id-token: write
    with:
      identity-id: <infisical-identity-id>
```

Do not add a workflow-level `concurrency` block to the caller. The reusable
workflow sets one per pull request, at the job level.

Every job runs on `boat-small` by default.
Boat refuses the jobs of a public repo, so a public caller passes `runs-on: blacksmith-2vcpu-ubuntu-2404` under `with:`.

Behavior worth knowing:

- A `pull_request` run draws that pull request. A manual run
  (`workflow_dispatch`) draws every open pull request at its current head,
  4 at a time. Each one costs a model call and posts or updates a comment.
- Both runs skip a draft, a fork, and a Dependabot pull request. A fork gets no
  OIDC token, so Infisical would refuse it.
- The config comes from Infisical, project `lazco-pr-lens-ci-shared`, env
  `prod`, path `/`: `PR_LENS_BASE_URL`, `PR_LENS_MODEL`, `PR_LENS_API_KEY`,
  and `PR_LENS_TOKEN`, a PR Lens account token (`prl_u_...`). The endpoint must
  speak OpenAI `/chat/completions`, stream with `stream: true`, and accept
  `max_tokens`. Set any reasoning effort in `PR_LENS_MODEL`, in the form the
  endpoint accepts.
- The request streams, because a proxy in front of a model endpoint cuts a
  request that sends nothing for about two minutes. A failed request is
  retried twice, and the whole analysis stops after 10 minutes.
- What the comment shows is decided from the diff, not by the model:
  - a change of fewer than 20 lines, not counting tests and docs, gets text
    only. Tests and docs are files under a `test/`, `tests/`, `__tests__/`,
    `e2e/`, `spec/`, `testdata/`, `fixtures/`, `doc/`, or `docs/` directory,
    files named `*.test.*`, `*.spec.*`, `*_test.*`, or `test_*.py`, and
    `.md`, `.mdx`, `.rst`, and `.adoc` files. `isRuntimeFile` in
    `pr-lens/lib.mjs` holds the same list;
  - otherwise each flow of 3 steps or more gets its own diagram, at most 2;
  - with no such flow, an architecture view of at least 3 boxes and 2 lines
    gets one diagram;
  - anything less gets text only.
  The `drawing` output says which one, and a text-only run publishes nothing
  and pushes no canvas.
- The comment is Traditional Chinese only. `pr-lens/prompt.md` holds the
  instructions and the glossary of product terms the model must use. Change
  the wording there.
- The identity pins the org by its immutable id in the subject, and each
  calling repo by its immutable id in the `repository_id` claim. A new repo
  must be added to that claim before its first run. The subject cannot list
  the repos itself: Infisical stores it in 255 characters.
- Each pull request gets one canvas. The comment carries its id in a hidden
  `<!-- pr-lens-canvas <id> -->` line, and every later run pushes a new
  revision of that canvas. The account token owns every canvas it mints, which
  is what lets a fresh runner push to one. List them with
  `pr-lens canvas list --remote`.
- A canvas holds the drawn graph document, not the code: component names, file
  paths, descriptions, and payload samples. A new canvas is open: anyone with
  its link can open it. prlens.dev keeps it in the EU until it is deleted.
- The owner can make a canvas private in the app. The action keeps pushing to
  it, but then only the owner account can open it.
- The canvas step calls the canvas API with `curl`, as the account, instead of
  the CLI. `pr-lens canvas pull` never sends the account token, so it cannot
  read a private canvas and would take it for a deleted one.
- The comment shows dark diagrams only. A light and dark `<picture>` pair
  follows the reader's operating system, not their GitHub theme, so it showed
  light diagrams on a dark GitHub page. The canvas has its own theme toggle,
  kept per browser, and defaults to the operating system.
- A canvas push is retried 3 times when a retry can fix it: no answer, a
  server error, a rate limit, or a moved revision.
- A canvas push that fails is a warning. The comment goes out without the
  link, and the next run mints or updates the canvas again.
- The CLI, the schema, and every dependency install from
  `pr-lens/package-lock.json`. Keep the schema version equal to the one the
  CLI depends on. To upgrade, change the versions in `pr-lens/package.json` and run
  `npm install --package-lock-only --ignore-scripts` in that directory.
- The comment links the SVGs through `github.com/<repo>/raw/`. A private
  repo's images never load from `raw.githubusercontent.com`, because the
  browser sends no GitHub session there.
- The action itself takes `pr-number`, `base-sha`, and `head-sha`. They
  default to the `pull_request` event's. Any other event must pass all three
  and check out `head-sha` with `fetch-depth: 0`.
- A repo can commit `.github/pr-lens.yml` to correct the diagrams. See the
  upstream schema README for the format. The renderer applies its renames,
  exclusions, lane pins, and groups. Its `lenses` field is not read: the action
  decides what to draw.

## Log style conventions

All actions follow the same output language:

- One `::group::` header per action with aligned `key : value` context lines.
- One labeled line per unit of work (`[  3s] waiting http=200 version=...`).
- `::notice title=...::...` for every successful outcome (visible on the run
  summary page without opening logs).
- `::error title=...::<what> - <diagnosis + next action>` for failures.
- A markdown table appended to `$GITHUB_STEP_SUMMARY` per action.
- Plain ASCII; sentence case.

## Releasing a change

1. PR/commit to `main`.
2. Run the **Self-test** workflow (`workflow_dispatch`) - it exercises every
   action via local refs, including expected-failure paths. `infisical-fetch`
   is excluded (needs an Infisical identity bound to this repo).
3. Only then move the consumer-facing tag:

   ```sh
   git tag -f v1 && git push -f origin v1
   ```

4. For breaking input/output changes, mint `v2` instead of moving `v1`, and
   migrate callers deliberately.

Rollback = point `v1` back at the previous commit and force-push the tag.

## Local development

Every script is env-var driven and guards its `$GITHUB_*` writes, so it runs
standalone:

```sh
SERVICE=api ENV_NAME=staging EXPECTED_VERSION=0.63.94 \
  CHECK_URL=https://api-staging.lazco.tw/v1/health \
  bash verify-deployment/verify-deployment.sh

PACKAGE_DIR=fixtures/npm-package DRY_RUN=true PACKAGE_MANAGER=npm \
  bash npm-publish/npm-publish.sh
```

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
