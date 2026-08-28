# AGENTS.md

Shared composite actions for Lazco release pipelines.
`README.md` documents what each action does and how to call it. Read it first.
This file covers the things that are easy to get wrong when changing them.

`CLAUDE.md` is a symlink to this file. Editing either one edits this file.
Cloning on Windows needs `git config --global core.symlinks true`, or the
symlink lands as a one-line text file and the guidance is lost.

## The rule that shapes everything

**This repo is public on purpose.** A private action repo cannot be called from
a public repo, and Lazco has both. Never add anything that assumes a private
repo: no secrets, no internal hostnames, no customer data, no cluster IPs.

Callers pin `@v1`, a floating tag. A bad commit reaches every consumer the
moment the tag moves, so the tag move is the release, not the merge.

## Layout

One directory per action. Each holds `action.yml` plus one bash script of the
same name. `infisical-fetch` is the exception and has no script - it wraps a
vendor action.

`fixtures/` backs the self-test: a fake gitops repo, two npm package states
(unpublished and already-published), and `health-server.py` for
`verify-deployment`.

## Script conventions

Every script is env-var driven. Nothing reads `github.*` directly, and every
`$GITHUB_OUTPUT` / `$GITHUB_STEP_SUMMARY` write is guarded, so each script runs
standalone. Keep that property - it is the whole local-development story.

The header comment block is part of the interface. List every env input with
its default and every output, in the same shape as the existing files.

`set -euo pipefail` is the default. Two scripts use `set -uo pipefail`
deliberately, because they drive their own retry loops and a non-zero probe is
an expected value, not a failure:

- `verify-deployment` polls until the health endpoint matches.
- `assert-promoted-image` probes the registry manifest.

Do not "fix" those two by adding `-e`.

## Output style

Consistency here is load-bearing: an operator reads these logs during a failed
prod release. Follow `README.md` under `Log style conventions` exactly.

The rule that matters most: an `::error title=...::` must say what failed
**and** what to do next. `gitops-writeback` is the model - it names the branch,
the attempt count, and tells the reader to re-run.

Plain ASCII, sentence case.

## Changing an action

1. Change the script and `action.yml` together. An input added to one and not
   the other fails at call time, not here.
2. Run the **Self-test** workflow (`workflow_dispatch`). It calls every action
   through local refs (`uses: ./<action>`) and covers expected-failure paths.
   `infisical-fetch` is excluded - it needs an identity bound to this repo.
3. Only then move `v1`.

Breaking an input or output means minting `v2` and migrating callers. Do not
move `v1` through a breaking change - consumers pinned it precisely so that
cannot happen.

Rollback is pointing `v1` at the previous commit and force-pushing.

## Tooling assumptions

Scripts may use `bash`, `curl`, `jq`, `yq`, and `git`. `docker` is
`assert-promoted-image` only, `npm` is `npm-publish` only. All are preinstalled
on `ubuntu-latest` and Blacksmith images. Adding a new dependency means every
consumer job must provide it, so prefer what is already there.

Composite actions cannot declare `permissions`. When an action needs a token
scope, the calling job must grant it, and that requirement belongs in
`README.md`. Two need `id-token: write`: `infisical-fetch`, and `npm-publish`
when provenance is on.

## License

AGPL-3.0-or-later. Keep it that way.
