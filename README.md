# cookbook-pipelines

Jenkins pipeline tooling for OSUOSL's Chef cookbook automation:

- **oslCookbookCI** (`vars/`) — shared-library CI entrypoint used by every
  cookbook repo's one-line Jenkinsfile.
- **cookbook-uploader** (`pipelines/`, `lib/`, `bin/`) — label-driven cookbook
  release pipeline: apply `bump/patch|minor|major` (plus optional `env/*` and
  `chain/*` labels) to a PR and Jenkins merges it, bumps the version, tags,
  uploads to the Chef server/supermarket, and uploads any community cookbook
  dependencies the PR's metadata.rb changes require.
- **environment-bumper** — pins the new versions in chef-repo
  `environments/*.json` and opens (or, for chained bumps, updates) a PR.

The Jenkins jobs, webhooks, and labels are managed by the
[osl-jenkins](https://github.com/osuosl-cookbooks/osl-jenkins) cookbook.
See [AGENTS.md](AGENTS.md) for development conventions and how changes ship.

## Testing

```
bundle install
bundle exec rake   # rubocop + rspec
```
