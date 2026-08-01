# cookbook-pipelines

Jenkins pipeline tooling for OSUOSL's Chef cookbook automation. This repo is
checked out by Jenkins jobs on jenkins.osuosl.org; the jobs themselves (and
the webhooks/labels that trigger them) are managed by the `osl-jenkins`
cookbook via JCasC job-dsl.

## Layout

- `vars/oslCookbookCI.groovy` — shared-library entrypoint for per-cookbook CI.
  Every cookbook repo carries a one-line Jenkinsfile calling `oslCookbookCI()`;
  a GitHub Organization Folder on the Jenkins side discovers them. The agent
  label lives here — switch it in one place to move CI into Docker agents.
  On PRs it also fails the build if the branch contains merge commits: GitHub
  can't forbid merge-updates without also forbidding the merge commit we want
  when the PR lands, so this check plus `strict` protection leaves rebase as
  the only way to refresh a stale branch. It inspects `refs/pull/<id>/head`,
  not the workspace HEAD, which is Jenkins' own merge of PR into target.
- `pipelines/cookbook-uploader.Jenkinsfile` — single webhook-driven release
  pipeline for all cookbook repos. Triggered by `bump/major|minor|patch`
  labels only; releasing requires GitHub write access (checked via the API,
  since triage users can label but must not release). A PR with no `env/*`
  label defaults to `env/default` and gets that label added for the record.
  Runs `bin/cookbook_bumper.rb`, then hands off to the environment-bumper
  job.
- Chained bumps: a `Cookbook-Chain: <value>` line in the PR description
  (preferred) or a commit message accumulates several related releases into
  one chef-repo PR on `jenkins/chain-<key>`. The value is either a free-form
  name shared by every PR in the series, or — Gerrit `Depends-On` style — a
  reference to the upstream PR (`osl-postfix#123` or its full URL), which all
  canonicalize to the same key (`osl-postfix-123`). The upstream PR
  self-references to join its own chain. Grouping only: nothing enforces
  merge order or co-tests the PRs. There are deliberately no `chain/*`
  labels — GitHub labels are per-repo, so free-form names would mean endless
  label churn.
- `pipelines/environment-bumper.Jenkinsfile` — parameterized job that pins
  versions in chef-repo `environments/*.json` and opens/updates a PR. Supports
  multi-cookbook pins and chains via its `chain` parameter.
- `pipelines/github-sync.Jenkinsfile` + `lib/github_sync.rb` — scheduled
  (every 30 min + on-demand) reconciliation of GitHub-side state: seeds `bump/*`
  (incl. `bump/skip`) and `env/*` labels and the uploader webhook in every
  non-archived org repo, removes the legacy webhooks (per-repo uploader hook,
  GHPRB `/ghprbhook/`) from repos that have a Jenkinsfile, grants the standing
  team permissions (chefs/staff write, ci/core admin), keeps the repo merge
  settings in sync, and requires up-to-date branches (`strict`) against the
  org folder's PR check — which also retires the legacy `chef-ci-linter-*`
  required context automatically.
  Deliberately not part of the chef converge. Supports `DRY_RUN` and a `REPOS`
  canary list; also restricts default-branch merges to the bot account
  (PROTECT_BRANCHES) so PRs cannot be merged manually. `enforce_admins` is
  deliberately false, leaving repo admins a manual escape hatch — the bot holds
  admin too, so `cookbook_bumper` checks `mergeable_state` itself and refuses
  to merge anything branch protection would block for a normal user. Per-repo failures mark
  the build UNSTABLE, not failed. Needs the out-of-band
  `cookbook_uploader_trigger` secret-text credential.
- `lib/` + `bin/` — the Ruby implementation. `lib/` classes are dependency-
  injected and unit-tested; `bin/` wrappers only wire ENV/stdin to them.
- `spec/` — RSpec with webhook payload fixtures in `spec/fixtures/`.

## Conventions and constraints

- **Ruby comes from cinc-workstation, not bundler.** The pipelines run
  `/opt/cinc-workstation/embedded/bin/ruby` on the Jenkins controller. That
  omnibus already ships ruby 3.4, `octokit`, `git` and `faraday-http-cache`,
  and it is where `knife` comes from — so nothing is installed at release
  time and there is no `bundle install` in any pipeline.
- The Gemfile pins those three gems to the exact versions cinc-workstation
  ships so CI exercises what production runs. Bump them only when
  cinc-workstation itself moves, and update `.ruby-version` / rubocop's
  `TargetRubyVersion` / the CI matrix together.
- Local dev uses rvm (`ruby-3.4.5@cookbook-pipelines`) purely to run the
  tests; bundler is a dev/test tool here, never a runtime one.
- **Branch-agnostic**: never hardcode `master`/`main`. Cookbook operations use
  the PR's `base.ref`; chef-repo operations resolve `default_branch` from the
  GitHub API. Specs cover both names.
- Secrets only via env vars (`GITHUB_TOKEN` from Jenkins `withCredentials`) —
  never rendered into files or logged (clone URLs embed the token; don't
  print them).
- Commits: `git commit -s`, concise subject + bullet body.

## Running tests

```sh
rvm use ruby-3.4.5@cookbook-pipelines --create
bundle install
bundle exec rake        # rubocop + rspec (same entrypoint CI uses)
```

To smoke-test against the ruby production actually uses:

```sh
/opt/cinc-workstation/embedded/bin/ruby -Ilib -e 'require "cookbook_bumper"'
```

## How changes ship

Merging to `main` is deployment: Jenkins jobs check out `main` on every run
(the shared library default version and the jobs' SCM config point at it).
There is no release/tag step. CI (GitHub Actions: rubocop + rspec) is required
on PRs to `main`.
