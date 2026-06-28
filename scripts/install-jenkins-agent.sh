#!/usr/bin/env bash
# Install the build toolchain (Terraform / AWS CLI / kubectl / Docker) and join
# this host to the Jenkins controller as an inbound (JNLP) agent.
#
# Run it ON the agent instance after connecting via SSM Session Manager:
#   aws ssm start-session --target <agent-instance-id>
#   sudo CONTROLLER_URL='http://<controller-private-ip>:8080' \
#        JENKINS_ADMIN_PASSWORD='same-as-controller' \
#        bash install-jenkins-agent.sh
set -euxo pipefail

CONTROLLER_URL="${CONTROLLER_URL:?set CONTROLLER_URL, e.g. http://10.20.8.10:8080}"
ADMIN_PW="${JENKINS_ADMIN_PASSWORD:?set JENKINS_ADMIN_PASSWORD (same as the controller)}"
AGENT_NODE="${AGENT_NODE:-build-agent-01}"
AGENT_WORKDIR="/opt/jenkins-agent"

dnf -y install java-17-amazon-corretto-headless git unzip docker dnf-plugins-core

# AWS CLI v2.
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update

# Terraform (HashiCorp repo).
dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf -y install terraform

# kubectl (matches the EKS 1.30 control plane).
curl -fsSL "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

systemctl enable --now docker

# Dedicated agent user + workspace.
useradd -m -d "${AGENT_WORKDIR}" jenkins || true
mkdir -p "${AGENT_WORKDIR}"
chown -R jenkins:jenkins "${AGENT_WORKDIR}"
usermod -aG docker jenkins

# Wait for the controller and the agent node, then pull the JNLP descriptor
# (which carries the connection secret).
for i in $(seq 1 60); do
  if curl -fsS -u "admin:${ADMIN_PW}" "${CONTROLLER_URL}/computer/${AGENT_NODE}/jenkins-agent.jnlp" -o /tmp/agent.jnlp; then
    break
  fi
  sleep 10
done

curl -fsSL "${CONTROLLER_URL}/jnlpJars/agent.jar" -o "${AGENT_WORKDIR}/agent.jar"
SECRET=$(sed -n 's:.*<argument>\([a-f0-9]\{64\}\)</argument>.*:\1:p' /tmp/agent.jnlp | head -1)
chown jenkins:jenkins "${AGENT_WORKDIR}/agent.jar"

# Run the inbound agent as a systemd service so it survives reboots.
cat >/etc/systemd/system/jenkins-agent.service <<EOF
[Unit]
Description=Jenkins inbound agent
After=network-online.target
Wants=network-online.target

[Service]
User=jenkins
WorkingDirectory=${AGENT_WORKDIR}
ExecStart=/usr/bin/java -jar ${AGENT_WORKDIR}/agent.jar -url ${CONTROLLER_URL}/ -secret ${SECRET} -name ${AGENT_NODE} -workDir ${AGENT_WORKDIR}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now jenkins-agent
echo "Agent installed and joined the controller as ${AGENT_NODE}."
