// Webhook-driven cookbook release pipeline. One job serves every repo in the
// org: the generic-webhook-trigger on the job (configured via JCasC job-dsl in
// the osl-jenkins cookbook) filters for bump/* label events and !bump
// comments, and passes the raw payload in the `payload` env var.
pipeline {
  agent { label 'built-in' }

  options {
    disableConcurrentBuilds()
    timestamps()
  }

  environment {
    RESULT_FILE = 'bump_result.json'
  }

  stages {
    stage('Bump cookbook') {
      steps {
        // A stale result file from a previous build would retrigger the
        // environment bumper even when this run produces none.
        sh 'rm -f "$RESULT_FILE"'
        withCredentials([usernamePassword(
          credentialsId: 'cookbook_uploader',
          usernameVariable: 'GITHUB_USER',
          passwordVariable: 'GITHUB_TOKEN',
        )]) {
          sh 'bundle install --quiet'
          sh 'bundle exec ruby bin/cookbook_bumper.rb'
        }
      }
    }

    stage('Bump environments') {
      when { expression { fileExists(env.RESULT_FILE) } }
      steps {
        script {
          def result = readJSON(file: env.RESULT_FILE)
          build(
            job: 'environment-bumper',
            wait: false,
            parameters: [
              string(name: 'cookbooks', value: result.cookbooks.collect { "${it.name}:${it.version}" }.join(',')),
              string(name: 'envs', value: result.envs),
              string(name: 'chain', value: result.chain ?: ''),
              string(name: 'pr_link', value: result.pr_link ?: ''),
            ],
          )
        }
      }
    }
  }
}
