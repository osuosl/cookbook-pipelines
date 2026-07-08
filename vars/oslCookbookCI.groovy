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
    stage('Lint & test') {
      sh command
    }
  }
}
