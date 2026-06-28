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

dnf -y install java-17-amazon-corretto-headless git unzip

# Jenkins LTS.
curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo -o /etc/yum.repos.d/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf -y install jenkins

# Skip the setup wizard and pin the HTTP port.
mkdir -p /etc/systemd/system/jenkins.service.d
cat >/etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
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
systemctl enable --now jenkins

echo "Jenkins controller installed."
echo "  UI:       http://<controller-private-ip>:8080 (reach via SSM port-forward)"
echo "  Username: admin"
echo "  Password: ${ADMIN_PW}"
echo "Next: run scripts/install-jenkins-agent.sh on the agent instance with"
echo "      CONTROLLER_URL and the same JENKINS_ADMIN_PASSWORD."
