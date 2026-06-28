# Architecture Overview

## Delivery Target

The delivery target for the assessment is AWS with Kubernetes (EKS) as the
container orchestration platform. All infrastructure is provisioned with
Terraform; the application is deployed with Kubernetes manifests and promoted
with a Jenkins pipeline.

## Component Diagram

```text
                                  ╭──────────────────────╮
                                  │   Client / Postman   │
                                  ╰──────────┬───────────╯
                                             │ HTTPS + Bearer (JWT)
                                             ▼
                           ╭─────────────────────────────────────╮
                           │  AWS API Gateway (HTTP API)          │
                           │  - ONLY public entry point           │
                           │  - JWT authorizer (Amazon Cognito)   │
                           │  - VPC Link -> internal NLB          │
                           │  - access logs -> CloudWatch         │
                           ╰──────────────────┬──────────────────╯
                                              │
            ╭─────────────────────────╮      │ token validation (issuer + audience + scope)
            │     Amazon Cognito      │◀─────╯
            │  user pool / resource   │
            │  server / app client    │  OAuth2 client_credentials -> access token
            ╰─────────────────────────╯
                                              │ VPC Link (private, no public IP)
                                              ▼
                           ╭─────────────────────────────────────╮
                           │ Internal NLB -> NGINX Ingress (L7)   │
                           │ (private subnets, no public exposure)│
                           ╰──────────────────┬──────────────────╯
                                              ▼
   ╭───────────────────────────── EKS cluster (VPC, multi-AZ) ──────────────────────────────╮
   │                                                                                          │
   │   ╭───────────────╮      ╭──────────────────────╮      ╭──────────────────────────╮     │
   │   │ Service       │────▶ │ weather-api pods      │      │ HorizontalPodAutoscaler  │     │
   │   │ (ClusterIP)   │      │ replicas: 2 (probes)  │◀──── │ min 2 / max 8, CPU 70%   │     │
   │   ╰───────────────╯      ╰───────────┬──────────╯      ╰──────────────────────────╯     │
   │                                      │ stdout JSON logs                                  │
   │   ╭──────────────────────────────╮  │                                                   │
   │   │ aws-for-fluent-bit DaemonSet │◀─╯  (IRSA service account)                            │
   │   ╰───────────────┬──────────────╯                                                       │
   │  managed node group: private subnets across multiple availability zones                  │
   ╰──────────────────┼───────────────────────────────────────────────────────────────────╯
                       │ logs:PutLogEvents (IRSA role)        │ outbound (NAT)
                       ▼                                      ▼
            ╭────────────────────╮               ╭──────────────────────────────╮
            │ Amazon CloudWatch  │               │ External weather provider     │
            │ Logs (app+cluster) │               │ (Open-Meteo geocoding/forecast)│
            ╰────────────────────╯               ╰──────────────────────────────╯
```

## Request And Authorization Flow

1. A client obtains an OAuth2 access token from Amazon Cognito using the
   `client_credentials` grant against the Cognito token endpoint.
2. The client calls AWS API Gateway with the token in the `Authorization`
   header.
3. API Gateway validates the token with its **JWT authorizer** (issuer,
   audience, and the configured API scope). The assessment allows a custom
   Lambda authorizer; a Cognito-backed JWT authorizer is used instead because
   it is a managed OAuth2 implementation with no custom code to maintain.
4. API Gateway forwards the request through a **VPC Link** private integration to
   the **internal NLB** that fronts ingress-nginx. API Gateway is the only public
   entry point; the NLB and cluster have no public exposure.
5. The NGINX Ingress Controller routes to the `weather-api` Service, which
   load-balances across the pods.
6. The pods call the external weather provider and return the response.

## Availability And Scaling

- The managed node group runs across private subnets in multiple availability
  zones (see the network module's subnet distribution).
- The application Deployment runs `replicas: 2` with readiness and liveness
  probes on `/health`.
- The HorizontalPodAutoscaler scales pods between 2 and 8 based on CPU
  utilization (target 70%).
- The node group is parameterized with desired/min/max sizes per environment.
- The Ingress Controller and API Gateway provide stable external entry points.
- Jenkins promotes the same immutable image tag from staging to production.

## Logging And Observability

- The application writes structured JSON logs to stdout.
- The `aws-for-fluent-bit` DaemonSet (deployed via Helm, see
  `kubernetes/logging/`) ships pod logs to CloudWatch using an IRSA service
  account.
- Terraform provisions the CloudWatch log groups (application and cluster) and
  the IRSA IAM role consumed by that service account.
- EKS control-plane log types are enabled on the cluster.
- API Gateway access logs are written to a dedicated CloudWatch log group.

## Network Topology

```text
                       Internet                 AWS API Gateway (managed,
                          │                      the ONLY public entry point)
                          ▼                              │ VPC Link
                ╭──────────────────╮                    │ (private)
   Public       │   NAT GW per AZ  │   (only the NAT Gateway is in public        │
   subnets      │                  │    subnets; nothing else is public)         │
                ╰─────────┬────────╯                    ▼
          ┌───────────────┼─────────────┐      ╭──────────────────╮
   Private (app tier)  Private (mgmt)  Private │  Internal NLB    │
   ╭───────────────╮   ╭────────────╮  (data)  │  (ingress-nginx) │
   │ EKS nodes     │   │ Jenkins EC2│  ╭──────╮ ╰────────┬─────────╯
   │ (workloads)   │◀──┤ (ctrl +    │  │ RDS  │          │
   │               │   │  agent)    │  │ (opt)│          ▼ routes to EKS Service
   ╰───────┬───────╯   ╰─────┬──────╯  ╰──────╯
           └─────────────────┘
       each private subnet ──▶ NAT GW in its OWN AZ ──▶ Internet (egress only)
       (AZ failure does not cut egress for the surviving AZs)
```

- **API Gateway is the only public entry point.** It is a managed regional
  service (not in any subnet) and reaches the cluster privately via a VPC Link to
  the internal NLB.
- No load balancer or compute is publicly exposed: the ingress NLB is internal,
  and all compute (EKS, Jenkins, any future RDS) sits in private subnets with
  outbound access through a NAT Gateway (a **Regional NAT Gateway** in production
  for 24/7 egress availability across all AZs; a single zonal NAT in staging for
  cost).
- This app uses an external weather provider and has **no database**, so RDS is
  shown only to illustrate where a data tier would sit.

## Architecture Decisions

These record deliberate trade-offs made for the assessment, and what a
production enterprise setup would do differently.

- **Jenkins location — in the application VPC (simple) vs Shared Services VPC
  (enterprise):** For simplicity, Jenkins is deployed within the application VPC.
  In a production enterprise environment, Jenkins would typically reside in a
  dedicated **Shared Services VPC** (connected via VPC peering or Transit
  Gateway), or be replaced by a **managed CI/CD service** (AWS
  CodePipeline/CodeBuild, GitLab CI, GitHub Actions). It would deploy to multiple
  Kubernetes clusters across accounts using **cross-account IAM roles** and
  private network connectivity.

- **Jenkins agent model — static EC2 (now) vs Kubernetes dynamic agents
  (target):** This submission uses a controller plus a static EC2 build/deploy
  agent, which is the quickest path to a working pipeline. The modern target is
  the **Jenkins Kubernetes plugin**, where the controller spawns **ephemeral pod
  agents on EKS** (no idle agent VM, isolation per build, elastic scaling). That
  model requires image builds without Docker-in-Docker (use **Kaniko/BuildKit**)
  and ideally a **dedicated build node group** (taints/tolerations) to isolate CI
  workloads from application workloads.

- **NAT Gateway — Regional (production) vs single zonal (staging):** The VPC
  module exposes a `nat_gateway_mode` with three options:
  - `regional` — a single **Regional NAT Gateway** (AWS, Nov 2025) that
    automatically expands/contracts across the AZs where workloads exist. It
    provides 24/7 HA with no per-AZ NAT or public-subnet management and a single
    route target. **Production uses this.** Requires AWS provider >= 6.24 (repo
    pins >= 6.50 to avoid the early zonal-NAT perpetual-diff issue).
  - `single` — one zonal NAT Gateway shared by all private subnets (cheapest, an
    AZ-level single point of failure for egress). **Staging uses this** for cost.
  - `per_az` — the classic one zonal NAT per AZ with per-AZ route tables (HA
    without the new Regional feature); retained for environments on older
    providers.

  Note: with Regional NAT, public subnets are no longer needed to host the NAT.
  Because the only public entry point is API Gateway (AWS-managed, outside the
  VPC) reaching an internal NLB via VPC Link, **production defines no public
  subnets at all** — every subnet is private. The IGW still exists (the Regional
  NAT egresses through it via its AWS-managed route table). Staging still keeps
  public subnets because its `single` zonal NAT must be hosted in one.

- **Ingress load balancer — NLB + ingress-nginx (chosen) vs ALB (alternative):**
  The cluster exposes traffic through `ingress-nginx` (`Service` of `type:
  LoadBalancer` with the `aws-load-balancer-type: nlb` annotation), so AWS
  provisions a **Network Load Balancer (L4)**. The NLB simply forwards TCP and
  lets nginx do all L7 routing — avoiding a redundant second L7 layer — while
  preserving the client source IP and exposing static IPs (which also pairs well
  with an API Gateway VPC Link, see below). A true Layer-7 **Application Load
  Balancer** would instead use the **AWS Load Balancer Controller** with
  `ingressClassName: alb` and replace ingress-nginx entirely. **Gateway Load
  Balancer (GLB)** is not applicable here — it is for inline security appliances
  (firewalls, IDS/IPS), not application traffic.

- **Ingress exposure — internal NLB + API Gateway VPC Link (implemented):** The
  ingress NLB is **internal** (private subnets, `aws-load-balancer-internal:
  "true"`) and API Gateway connects to it through a **VPC Link** private
  integration, so **API Gateway is the only public entry point** — the NLB and
  cluster have no public exposure. **Both environments use this same design**
  (`private_integration = true`); there is no per-environment toggle. Because the
  NLB is created by Kubernetes at deploy time (not Terraform), the VPC Link
  integration is wired from a tag-based `aws_lb` / `aws_lb_listener` data source,
  so the cluster must be **bootstrapped in order**:

  1. Targeted apply to provision the foundation first, e.g.
     `terraform apply -target=module.<vpc> -target=module.<eks>` → creates the
     VPC, EKS, etc.
  2. Deploy ingress-nginx (creates the internal NLB).
  3. Full `terraform apply` → the `aws_lb` data source resolves the NLB listener
     ARN and wires the VPC Link to it.

  Because both environments share one AWS account, the `aws_lb` lookup is scoped
  to its own cluster with the `kubernetes.io/cluster/<cluster-name> = owned` tag
  (in addition to the `kubernetes.io/service-name` tag), so staging and
  production never resolve each other's NLB.

  After the first bootstrap, day-to-day `terraform apply` runs in a single pass
  because the NLB already exists. A deploy-time caveat: depending on how
  ingress-nginx targets nodes, the EKS-managed node security group may also need
  the NodePort range opened to the VPC Link security group.

- **TLS termination — at API Gateway now (HTTP/80 internal) vs end-to-end TLS
  (HTTPS/443 internal) as a hardening step:** Clients always reach the platform
  over **HTTPS/443**; **TLS is terminated at API Gateway** (the only public
  entry point, with an AWS-managed certificate). The hop from API Gateway →
  VPC Link → internal NLB → ingress-nginx is **entirely inside the VPC** (private
  subnets, no public IP), so it currently runs over **HTTP/80** — the
  `aws_lb_listener` data source resolves the NLB's port-80 listener. This keeps
  the design simple while no traffic ever crosses the internet unencrypted.

  For a stricter posture (end-to-end / in-transit encryption, e.g. PCI-DSS or
  HIPAA), terminate TLS again on the internal leg (HTTPS/443). The code change is
  small — switch the `aws_lb_listener` lookup to `port = 443`, add a
  `tls_config { server_name_to_verify = ... }` block to the API Gateway
  integration, and add a `tls:` section to the Ingress. The real cost is the
  **certificate**: API Gateway HTTP APIs only trust certificates from a public CA
  (the Amazon trust store), and the internal NLB has an AWS-generated DNS name, so
  a self-signed certificate will not pass verification. A production rollout would
  therefore use **ACM Private CA + cert-manager** (note: Private CA is ~$400/month)
  or a real owned domain with a publicly trusted certificate presented by the
  backend. Deferred for now; can be implemented later if time allows.

- **Subnet tiering — shared private subnets (now) vs per-tier subnets
  (enterprise):** Compute currently shares the private subnets. A hardened setup
  would split app/management/data into **separate subnet tiers** with dedicated
  route tables, NACLs, and security group boundaries.

## Why Shared Modules Are Provider-First

Requirement 7 is about Terraform portability, not pretending all clouds are
identical. Organizing modules under `aws/`, `azure/`, `gcp/`, and `oci/` keeps
each provider implementation explicit while preserving a common functional
taxonomy such as `compute`, `database`, `network`, and `monitor`.

That structure avoids two common problems:

- mixing provider-specific resources directly into every environment definition
- forcing one over-generalized module to support incompatible cloud services in
  a single implementation

## Implementation Scope

The AWS path is fully implemented in the shared modules repository as directly
callable leaf modules: network (`vpc`: VPC, subnets, IGW, NAT, route tables),
compute (`ecr`, `eks` with managed node group and OIDC provider, `ec2` for the
Jenkins instances), monitor (`cloudwatch` log groups and `irsa-log-shipper`
role), identity (`cognito`), and edge (`api-gateway`). The `azure/`, `gcp/`, and `oci/`
trees contain provider-organized placeholder paths so the module taxonomy is
visible for future expansion without changing the reviewer-facing structure.
