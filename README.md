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
| `prod-actor-guard` | Fail-closed `PROD_RELEASE_ACTORS` allow-list check for prod tags |
| `assert-promoted-image` | Assert the exact `<version>-<sha>` image exists (prod never rebuilds) |
| `gitops-writeback` | Pin `newTag` in a `cloud-infra-gitops` overlay and push (rebase-retry loop) |
| `verify-deployment` | Poll the health endpoint until HTTP 200 + expected version, then confirm stability |
| `npm-publish` | Publish a built package: version-gate, skip if already published, sign with provenance, verify the dist-tag |
| `discord-notify` | Failure notification naming the failed job(s) (from the `needs` context) |

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

Requirements of calling jobs:

- Jobs calling `infisical-fetch` must declare `permissions: id-token: write`
  (OIDC tokens are minted per job; composite actions cannot declare permissions).
- Jobs calling `npm-publish` with the default `provenance: true` need the same
  `permissions: id-token: write`.
- Scripts need `bash`, `curl`, `jq`, `yq`, `git`, `docker` (assert-promoted-image
  only), `npm` (npm-publish only) - all preinstalled on GitHub `ubuntu-latest`
  and Blacksmith images.

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
