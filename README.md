# cookbook-pipelines

Jenkins pipeline tooling for OSUOSL's Chef cookbook automation:

- **oslCookbookCI** (`vars/`) — shared-library CI entrypoint used by every
  cookbook repo's one-line Jenkinsfile; repos are discovered by the
  `osuosl-cookbooks` organization folder on Jenkins.
- **cookbook-uploader** (`pipelines/`, `lib/`, `bin/`) — label-driven cookbook
  release pipeline: apply `bump/patch|minor|major` (plus optional `env/*`
  labels, or `bump/skip` to merge with no release) to a PR and Jenkins merges
  it, bumps the version, tags, uploads to
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
- **github-sync** — scheduled reconciliation (every 4 hours + on demand)
  of GitHub-side state across the org: seeds the `bump/*`/`env/*` labels,
  manages the uploader webhooks, removes the legacy webhooks from repos that
  have migrated (Jenkinsfile present), grants the standing team permissions,
  enables auto-delete of merged branches, and restricts default-branch merges
  to the Jenkins bot so PRs can only land through the bump workflow (repo
  admins stay exempt as an escape hatch), with one approving review required
  wherever a branch has no review rule yet. Supports `DRY_RUN` and a `REPOS`
  canary list.

The pipelines run against cinc-workstation's embedded ruby on the Jenkins
controller — nothing is installed at release time and bundler is a dev/test
tool only. The Jenkins jobs themselves are managed by the
[osl-jenkins](https://github.com/osuosl-cookbooks/osl-jenkins) cookbook;
GitHub-side state is managed here by github-sync.
See [AGENTS.md](AGENTS.md) for development conventions and how changes ship.

## Recovering a failed release

A release that fails before the merge leaves the PR untouched: fix the cause
and apply the `bump/*` label again. One that fails after the merge can't be
retried that way, because the bumper refuses a merged PR. Finish the
remaining steps by hand, in order, skipping any that already happened. The
failure comment and the build log show where it stopped.

1. **Bump commit and tag.** Check the base branch for `Automatic
   <level>-level version bump to vX.Y.Z by Jenkins` and the tag for it:

   ```sh
   gh api repos/osuosl-cookbooks/<cookbook>/git/ref/tags/vX.Y.Z
   ```

   - Neither there: a repo admin (exempt from the bot-only push rule) bumps
     `version` in `metadata.rb`, adds the CHANGELOG entry from the PR title,
     commits with that message, tags `vX.Y.Z` and runs
     `git push --atomic origin <base> refs/tags/vX.Y.Z`.
   - Commit there, tag missing:

     ```sh
     gh api -X POST repos/osuosl-cookbooks/<cookbook>/git/refs \
       -f ref=refs/tags/vX.Y.Z -f sha=<full bump commit sha>
     ```

2. **Upload.** If `knife cookbook show <cookbook> X.Y.Z` doesn't list it,
   upload it from a checkout of the tag in a directory named after the
   cookbook:

   ```sh
   git clone -b vX.Y.Z https://github.com/osuosl-cookbooks/<cookbook>.git ~/tmp/rel/<cookbook>
   knife cookbook upload <cookbook> --freeze -o ~/tmp/rel
   knife supermarket share <cookbook> Other -m https://supermarket.osuosl.org -o ~/tmp/rel
   ```

   Community dependencies were uploaded before the merge. The build log's
   `Uploading community cookbook <name> <version>` lines name them for the
   next step.

3. **Environments.** Unless the release had no `env/*` label to act on, run
   the `environment-bumper` job with:

   | Parameter | Value |
   |---|---|
   | `cookbooks` | `<cookbook>:X.Y.Z`, plus `,<community>:<version>` for each community upload |
   | `envs` | the PR's `env/*` label names, comma-separated (`default` when it had none) |
   | `chain` | the PR's `Cookbook-Chain:` value, or empty; a PR reference goes in as `<repo>-<number>` (`osl-postfix#123` is `osl-postfix-123`) |
   | `pr_link` | the cookbook PR's URL |

   It opens or updates the chef-repo PR as a normal release would.

## Testing

```
bundle install
bundle exec rake   # rubocop + rspec
```
