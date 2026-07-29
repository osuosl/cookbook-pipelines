# cookbook-pipelines

Jenkins pipeline tooling for OSUOSL's Chef cookbook automation:

- **oslCookbookCI** (`vars/`) — shared-library CI entrypoint used by every
  cookbook repo's one-line Jenkinsfile; repos are discovered by the
  `osuosl-cookbooks` organization folder on Jenkins.
- **cookbook-uploader** (`pipelines/`, `lib/`, `bin/`) — label-driven cookbook
  release pipeline: apply `bump/patch|minor|major` (plus optional `env/*`
  labels) to a PR and Jenkins merges it, bumps the version, tags, uploads to
  the Chef server/supermarket, and uploads any community cookbook dependencies
  the PR's metadata.rb changes require (already-uploaded versions are
  skipped). Releasing requires GitHub write access. A `Cookbook-Chain:` line
  in the PR description (or a commit message) accumulates related bumps into
  one chef-repo PR; its value is a shared name or, Gerrit `Depends-On` style,
  a reference to the upstream PR (`osl-postfix#123`).
- **environment-bumper** — pins the new versions in chef-repo
  `environments/*.json` and opens (or, for chained bumps, updates) a PR.
  Explicitly named environments also gain missing pins; `all` only updates
  existing ones.
- **github-sync** — scheduled reconciliation (every 30 minutes + on demand)
  of GitHub-side state across the org: seeds the `bump/*`/`env/*` labels,
  manages the uploader webhooks, removes the legacy webhooks from repos that
  have migrated (Jenkinsfile present), and restricts default-branch merges to
  the Jenkins bot so PRs can only land through the bump workflow. Supports
  `DRY_RUN` and a `REPOS` canary list.

The pipelines run against cinc-workstation's embedded ruby on the Jenkins
controller — nothing is installed at release time and bundler is a dev/test
tool only. The Jenkins jobs themselves are managed by the
[osl-jenkins](https://github.com/osuosl-cookbooks/osl-jenkins) cookbook;
GitHub-side state is managed here by github-sync.
See [AGENTS.md](AGENTS.md) for development conventions and how changes ship.

## Testing

```
bundle install
bundle exec rake   # rubocop + rspec
```
