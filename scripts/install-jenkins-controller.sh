#!/usr/bin/env bash
# Install + configure the Jenkins CONTROLLER on its Amazon Linux 2023 EC2 instance.
#
# Run it ON the controller instance after connecting via SSM Session Manager:
#   aws ssm start-session --target <controller-instance-id>
#   sudo JENKINS_ADMIN_PASSWORD='choose-a-strong-one' bash install-jenkins-controller.sh
#
# If JENKINS_ADMIN_PASSWORD is not set, a random password is generated and printed
# at the end. The password is never written to Terraform code or state.
set -euxo pipefail

JNLP_PORT=50000
AGENT_NODE="build-agent-01"
AGENT_WORKDIR="/opt/jenkins-agent"
ADMIN_PW="${JENKINS_ADMIN_PASSWORD:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)}"

dnf -y install java-21-amazon-corretto-headless git unzip

# Jenkins LTS.
curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo -o /etc/yum.repos.d/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf -y install jenkins

# Plugins the Terraform/deploy pipelines need (the setup wizard is skipped, so
# nothing is bundled): Pipeline, Git SCM + polling, and credentials binding.
# The plugin manager resolves all transitive dependencies.
PLUGIN_MGR_VERSION=2.15.0
mkdir -p /var/lib/jenkins/plugins
curl -fsSL -o /opt/jenkins-plugin-manager.jar \
  "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${PLUGIN_MGR_VERSION}/jenkins-plugin-manager-${PLUGIN_MGR_VERSION}.jar"
java -jar /opt/jenkins-plugin-manager.jar \
  --war /usr/share/java/jenkins.war \
  --plugin-download-directory /var/lib/jenkins/plugins \
  --plugins workflow-aggregator git credentials-binding pipeline-stage-view
chown -R jenkins:jenkins /var/lib/jenkins/plugins

# Skip the setup wizard, pin the HTTP port, and force Jenkins to use Java 21
# (Jenkins requires Java 21+, and Java 17 may also be present on the host).
JAVA21="$(ls -d /usr/lib/jvm/java-21-amazon-corretto*/bin/java | head -1)"
mkdir -p /etc/systemd/system/jenkins.service.d
cat >/etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JENKINS_JAVA_CMD=${JAVA21}"
Environment="JENKINS_OPTS=--httpPort=8080"
Environment="JAVA_OPTS=-Djenkins.install.runSetupWizard=false"
EOF

# init.groovy.d: create the admin user, lock down auth, pin the JNLP port, and
# register the inbound (JNLP) build agent node so the agent host can join.
mkdir -p /var/lib/jenkins/init.groovy.d

cat >/var/lib/jenkins/init.groovy.d/01-security.groovy <<EOF
import jenkins.model.*
import hudson.security.*
def inst = Jenkins.get()
def realm = new HudsonPrivateSecurityRealm(false)
realm.createAccount("admin", "${ADMIN_PW}")
inst.setSecurityRealm(realm)
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
inst.setAuthorizationStrategy(strategy)
inst.setSlaveAgentPort(${JNLP_PORT})
inst.save()
EOF

cat >/var/lib/jenkins/init.groovy.d/02-agent-node.groovy <<EOF
import jenkins.model.*
import hudson.model.*
import hudson.slaves.*
def name = "${AGENT_NODE}"
if (Jenkins.get().getNode(name) == null) {
  def node = new DumbSlave(name, "${AGENT_WORKDIR}", new JNLPLauncher(true))
  node.setNumExecutors(2)
  node.setLabelString("build linux")
  node.setMode(Node.Mode.NORMAL)
  node.setRetentionStrategy(new RetentionStrategy.Always())
  Jenkins.get().addNode(node)
}
EOF

chown -R jenkins:jenkins /var/lib/jenkins/init.groovy.d

systemctl daemon-reload
systemctl enable jenkins
# Use restart (not "enable --now") so re-runs pick up config/override changes.
systemctl restart jenkins

echo "Jenkins controller installed."
echo "  UI:       http://<controller-private-ip>:8080 (reach via SSM port-forward)"
echo "  Username: admin"
echo "  Password: ${ADMIN_PW}"
echo "Next: run scripts/install-jenkins-agent.sh on the agent instance with"
echo "      CONTROLLER_URL and the same JENKINS_ADMIN_PASSWORD."
