# Max Weather Platform

This repository is the reviewer entry point for the assessment. It brings together environment-level Terraform composition, Kubernetes deployment assets, CI/CD, Postman verification, and the documents that explain the design.

## Repository Responsibilities

- Compose staging and production environments with Terraform.
- Deploy the application into Kubernetes.
- Expose the service through ingress and API Gateway.
- Provide a staged promotion pipeline from staging to production.
- Document the architecture and rationale for the reviewer.

## Repository Layout

- `terraform/` contains environment composition plus shared provider/version snippets.
- `kubernetes/` contains base manifests and environment overlays.
- `jenkins/` contains the Jenkins pipelines: `Jenkinsfile.infra` (Terraform) and `Jenkinsfile.deploy` (deploy + promote). Jenkins is the only CI/CD engine.
- `postman/` contains the API validation collection.
- `docs/` contains the architecture document and diagram (deliverable #1).

## Related Repositories

- `max-weather-app` contains the weather proxy service source.
- `terraform-shared-modules` contains shared Terraform module taxonomy, organized by cloud provider.

## Reviewer Path

The overall submission answer lives in the top-level `SUMMARY.md`. Within this
repository, start with `docs/architecture.md`, then
`terraform/environments/staging/main.tf`.

## Terraform Note

Terraform is executed from each environment directory. The `terraform/globals/` files are retained as shared reference snippets, while each environment keeps its own executable `providers.tf` and `versions.tf` so the structure is clear to reviewers and usable in practice.

## Deployment Flow (production)

Goal: the platform infrastructure is deployed **through Jenkins** (the agent runs
the Terraform pipeline). A small one-time bootstrap from a laptop stands Jenkins
up; Jenkins then owns the rest.

1. **`scripts/bootstrap-backend.sh`** — create the S3 state bucket (Terraform
   cannot create its own backend). State locking uses S3 native locking
   (`use_lockfile`).
2. **From the laptop**, `terraform init -backend-config=backend.hcl` then a
   **targeted apply** of the foundation Jenkins needs: the VPC + the two Jenkins
   EC2 instances (controller + agent). Terraform only creates the plain VMs;
   Jenkins itself is installed in the next step. The API Gateway module is
   intentionally excluded here because it depends on the ingress NLB that does
   not exist yet (see step 5).

   ```bash
   terraform apply \
     -target=module.mw-prd-apse1-vpc-01 \
     -target=module.mw-prd-apse1-ec2-jenkins-ctrl-01 \
     -target=module.mw-prd-apse1-ec2-jenkins-agent-01
   ```
3. **Set up Jenkins** by connecting to each instance with SSM Session Manager and
   running the install scripts (fast, no clicking through the UI):
   - controller: `sudo JENKINS_ADMIN_PASSWORD='...' bash scripts/install-jenkins-controller.sh`
   - agent: `sudo CONTROLLER_URL='http://<controller-ip>:8080' JENKINS_ADMIN_PASSWORD='...' bash scripts/install-jenkins-agent.sh`
4. **From Jenkins** (`Jenkinsfile.infra`), run a targeted apply of the rest of the
   foundation so the cluster exists: EKS, ECR, Cognito, CloudWatch, and the log
   shipper.

   ```bash
   terraform apply \
     -target=module.mw-prd-apse1-eks-01 \
     -target=module.mw-prd-apse1-ecr-01 \
     -target=module.mw-prd-apse1-cognito-01 \
     -target=module.mw-prd-apse1-cw-01 \
     -target=module.mw-prd-apse1-logshipper-01
   ```
5. **Install the cluster add-ons** so the internal ingress NLB is created:
   `ENVIRONMENT=production ./scripts/install-cluster-addons.sh`. This installs
   ingress-nginx (creates the internal NLB the API Gateway VPC Link binds to),
   metrics-server, and aws-for-fluent-bit via Helm.
6. **Full apply** (`Jenkinsfile.infra` with no targets). This wires the API
   Gateway VPC Link to the internal NLB listener that now exists. After this
   one-time bootstrap, day-to-day applies are a single pass.
7. **Application deploys** run through `Jenkinsfile.deploy`: it deploys an
   immutable image tag to staging, smoke-tests it, then promotes the same tag to
   production after manual approval.

### Credentials model

- **OS login to the EC2 instances:** AWS **SSM Session Manager** — no SSH keys,
  no passwords, no open inbound ports (enabled only by the `AmazonSSMManagedInstanceCore`
  policy on the instance role; no extra Terraform/SSM resources needed).
- **Jenkins UI admin password:** chosen at install time (passed as an env var to
  `install-jenkins-controller.sh`, or auto-generated and printed). It is never
  stored in Terraform code or state. Rotate it in the Jenkins UI afterwards.
- **Agent → controller join:** the install script fetches the node's JNLP secret
  from the controller using the admin password; nothing is hard-coded.
- **Terraform state:** the S3 backend is encrypted, and no Jenkins secret is ever
  written to it.

The Jenkins agent role currently has `AdministratorAccess` so it can run the full
infrastructure pipeline. In a real production account this should be scoped to a
least-privilege deploy policy, or replaced with a dedicated assumable deploy role
so the instance profile stays minimal.
