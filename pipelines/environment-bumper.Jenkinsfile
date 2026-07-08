// Pins cookbook versions in chef-repo environments and opens/updates a PR.
// Normally triggered by the cookbook-uploader pipeline; the parameters make
// manual runs possible from the Jenkins UI.
pipeline {
  agent { label 'built-in' }

  options {
    // Chain bumps stack commits on a shared branch — serialize builds.
    disableConcurrentBuilds()
    timestamps()
  }

  parameters {
    string(name: 'cookbooks', defaultValue: '',
           description: "Comma list of name:version pins, e.g. 'osl-postfix:2.1.0,postfix:6.1.8'.")
    string(name: 'envs', defaultValue: '',
           description: "Comma list of chef environments; 'all' bumps every environment, " +
                        "'default' expands to the default set.")
    string(name: 'chain', defaultValue: '',
           description: 'Optional chain name: bumps sharing a chain accumulate in one chef-repo PR.')
    string(name: 'pr_link', defaultValue: '',
           description: 'Optional link to the PR that triggered this bump.')
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
