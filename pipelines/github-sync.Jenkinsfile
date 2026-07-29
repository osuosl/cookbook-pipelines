// Reconciles GitHub-side state for the bump workflow (bump/* and env/*
// labels, uploader webhooks) across the whole org. Scheduled every 30
// minutes (offset from the chef-client interval) and runnable on demand;
// deliberately NOT part of the chef converge, so converge time stays
// independent of org size.
//
// Requires two out-of-band Jenkins credentials (never created via JCasC):
//   cookbook_uploader         - username/password, GitHub API token
//   cookbook_uploader_trigger - secret text, the generic-webhook-trigger token
pipeline {
  agent { label 'built-in' }

  options {
    disableConcurrentBuilds()
    timestamps()
  }

  environment {
    // The cinc-workstation omnibus already ships ruby and every gem this
    // needs; nothing is installed at run time.
    RUBY = '/opt/cinc-workstation/embedded/bin/ruby'
  }

  stages {
    stage('Sync GitHub state') {
      steps {
        withCredentials([
          usernamePassword(
            credentialsId: 'cookbook_uploader',
            usernameVariable: 'GITHUB_USER',
            passwordVariable: 'GITHUB_TOKEN',
          ),
          string(credentialsId: 'cookbook_uploader_trigger', variable: 'TRIGGER_TOKEN'),
        ]) {
          script {
            def status = sh(script: '"$RUBY" bin/github_sync.rb', returnStatus: true)
            if (status == 2) {
              unstable('Some repos failed to sync - see the log for details')
            } else if (status != 0) {
              error("github-sync failed with exit code ${status}")
            }
          }
        }
      }
    }
  }
}
