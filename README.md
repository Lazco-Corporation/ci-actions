# ci-actions

Shared composite actions for Lazco's tag-driven release pipelines
(`cloud-backend`, `cloud-frontend`). One directory per action; each wraps a
plain bash script so the logic is reviewable, shellcheck-able, and runnable
locally.

## Actions

| Action | Purpose |
|---|---|
| `infisical-fetch` | Export Infisical `/ci` secrets as masked env vars (OIDC), with fail-fast `required-keys` validation |
| `parse-release-tag` | Split `<svc>/<env>-<version>` into `(service, env, version, sha, image_name)` with validation |
| `prod-actor-guard` | Fail-closed `PROD_RELEASE_ACTORS` allow-list check for prod tags |
| `assert-promoted-image` | Assert the exact `<version>-<sha>` image exists (prod never rebuilds) |
| `gitops-writeback` | Pin `newTag` in a `cloud-infra-gitops` overlay and push (rebase-retry loop) |
| `verify-deployment` | Poll the health endpoint until HTTP 200 + expected version, then confirm stability |
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

The repo is private; org access is granted via Settings > Actions > General >
Access = "Accessible from repositories in the organization".

Requirements of calling jobs:

- Jobs calling `infisical-fetch` must declare `permissions: id-token: write`
  (OIDC tokens are minted per job; composite actions cannot declare permissions).
- Scripts need `bash`, `curl`, `jq`, `yq`, `git`, `docker` (assert-promoted-image
  only) - all preinstalled on GitHub `ubuntu-latest` and Blacksmith images.

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
```
