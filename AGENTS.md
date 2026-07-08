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
- `pipelines/cookbook-uploader.Jenkinsfile` — single webhook-driven release
  pipeline for all cookbook repos. Triggered by `bump/major|minor|patch`
  labels (primary; authorization is GitHub-native, triage+) or a
  `!bump <level> [envs=a,b] [chain=name]` comment (fallback; needs write
  access). Runs `bin/cookbook_bumper.rb`, then hands off to the
  environment-bumper job.
- `pipelines/environment-bumper.Jenkinsfile` — parameterized job that pins
  versions in chef-repo `environments/*.json` and opens/updates a PR. Supports
  multi-cookbook pins and chains (`chain=<name>` accumulates several bumps
  into one chef-repo PR on `jenkins/chain-<name>`).
- `lib/` + `bin/` — the Ruby implementation. `lib/` classes are dependency-
  injected and unit-tested; `bin/` wrappers only wire ENV/stdin to them.
- `spec/` — RSpec with webhook payload fixtures in `spec/fixtures/`.

## Conventions and constraints

- **Ruby 3.1** (rvm: `ruby-3.1.7@cookbook-pipelines`). Gems must stay
  resolvable on 3.1 for Cinc 18.x compatibility — don't bump `octokit`/`git`
  to versions requiring newer Ruby.
- **Branch-agnostic**: never hardcode `master`/`main`. Cookbook operations use
  the PR's `base.ref`; chef-repo operations resolve `default_branch` from the
  GitHub API. Specs cover both names.
- Secrets only via env vars (`GITHUB_TOKEN` from Jenkins `withCredentials`) —
  never rendered into files or logged (clone URLs embed the token; don't
  print them).
- Commits: `git commit -s`, concise subject + bullet body.

## Running tests

```
rvm use ruby-3.1.7@cookbook-pipelines
bundle install
bundle exec rake        # rubocop + rspec (same entrypoint CI uses)
```

## How changes ship

Merging to `main` is deployment: Jenkins jobs check out `main` on every run
(the shared library default version and the jobs' SCM config point at it).
There is no release/tag step. CI (GitHub Actions: rubocop + rspec) is required
on PRs to `main`.
