// Pins cookbook versions in chef-repo environments and opens/updates a PR.
// Normally triggered by the cookbook-uploader pipeline, but it can be run
// manually from the Jenkins UI.
//
// All parameters (cookbooks/envs/chain/pr_link plus the CHEF_REPO and
// DEFAULT_ENVIRONMENTS site config) are defined on the job by the osl-jenkins
// cookbook's job-dsl, NOT here — a parameters directive in this file would
// fight the chef-managed definitions on every run.
pipeline {
  agent { label 'built-in' }

  options {
    // Chain bumps stack commits on a shared branch — serialize builds.
    disableConcurrentBuilds()
    timestamps()
  }

  stages {
    stage('Bump environments') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: 'cookbook_uploader',
          usernameVariable: 'GITHUB_USER',
          passwordVariable: 'GITHUB_TOKEN',
        )]) {
          sh 'bundle install --quiet'
          sh 'bundle exec ruby bin/environment_bumper.rb'
        }
      }
    }
  }
}
