// Shared CI entrypoint for every cookbook repo. Each cookbook's Jenkinsfile is:
//
//   @Library('osl-pipelines') _
//   oslCookbookCI()
//
// Options:
//   label   — Jenkins agent label (default 'built-in'; switch to a docker
//             agent label here once container builds land)
//   command — test command (default 'rake', matching the cookbook Rakefiles)
def call(Map options = [:]) {
  def label = options.get('label', 'built-in')
  def command = options.get('command', 'rake')

  node(label) {
    stage('Checkout') {
      checkout scm
    }
    if (env.CHANGE_ID) {
      stage('Linear history') {
        assertLinearBranch()
      }
    }
    stage('Lint & test') {
      // Berkshelf's cookbook store is keyed by name-version, but our
      // versions only move at release time - so a shared or reused cache
      // routinely holds a stale copy of the same version with different
      // metadata, and ChefSpec then hits impossible constraint conflicts
      // ("percona ~> 4.0 AND ~> 5.0 required by osl-mysql-7.1.3").
      // Every build gets its own store, created and destroyed here.
      withEnv(["BERKSHELF_PATH=${env.WORKSPACE}/.berkshelf"]) {
        sh 'rm -rf "$BERKSHELF_PATH"'
        try {
          sh command
        } finally {
          sh 'rm -rf "$BERKSHELF_PATH"'
        }
      }
    }
  }
}

// Fail a PR whose branch contains merge commits. GitHub has no setting for
// this, and branch protection's "require linear history" would also forbid
// the merge commit we DO want when the PR lands. Combined with protection's
// strict (up-to-date) requirement, this leaves rebase as the only way to
// refresh a stale PR branch.
//
// The PR head is fetched explicitly: this build's workspace HEAD is Jenkins'
// own merge of the PR into the target, so inspecting HEAD would always find a
// merge commit. refs/pull/<id>/head works for forks too.
private void assertLinearBranch() {
  sh """
    set -e
    git fetch --no-tags --force origin \
      'refs/heads/${env.CHANGE_TARGET}:refs/remotes/origin/${env.CHANGE_TARGET}' \
      '+refs/pull/${env.CHANGE_ID}/head:refs/remotes/origin/pr-${env.CHANGE_ID}'
    merges=\$(git log --merges --oneline \
      "refs/remotes/origin/${env.CHANGE_TARGET}..refs/remotes/origin/pr-${env.CHANGE_ID}")
    if [ -n "\$merges" ]; then
      echo 'This PR branch contains merge commits:'
      echo "\$merges"
      echo
      echo 'Rebase onto origin/${env.CHANGE_TARGET} instead of merging it into the branch:'
      echo '  git fetch origin && git rebase origin/${env.CHANGE_TARGET} && git push --force-with-lease'
      exit 1
    fi
  """
}
