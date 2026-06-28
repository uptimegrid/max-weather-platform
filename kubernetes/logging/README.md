# CloudWatch Log Shipping (aws-for-fluent-bit)

This directory deploys the `aws-for-fluent-bit` DaemonSet that forwards
application pod logs to Amazon CloudWatch, completing the logging requirement
end to end.

## How It Fits Together

```text
weather-api pods (stdout JSON)
  -> aws-for-fluent-bit DaemonSet (per node)
  -> assumes IRSA role (logs:PutLogEvents)
  -> CloudWatch Logs group provisioned by Terraform
```

- Terraform (`terraform-shared-modules/aws/monitor`) provisions the CloudWatch
  log groups and the IRSA IAM role.
- This Helm release provides the in-cluster agent that uses that role.

## Required Values

Fill the placeholders in `values.yaml` from the Terraform outputs of the target
environment:

| values.yaml field                         | Terraform output                    |
| ----------------------------------------- | ----------------------------------- |
| `serviceAccount.annotations` role-arn     | `module.monitor.log_shipper_role_arn` |
| `cloudWatchLogs.region`                    | `var.aws_region`                    |
| `cloudWatchLogs.logGroupName`              | `module.monitor.log_group_name`     |

The service account name (`aws-for-fluent-bit`) and namespace (`kube-system`)
must match the IRSA trust policy defaults in the monitor module.

## Installation

```bash
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
  --namespace kube-system \
  -f kubernetes/logging/values.yaml
```

## Verification

After deployment, confirm log delivery:

```bash
kubectl -n kube-system rollout status daemonset/aws-for-fluent-bit
aws logs describe-log-streams \
  --log-group-name "$(terraform -chdir=terraform/environments/staging output -raw log_group_name)"
```
