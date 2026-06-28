# NGINX Ingress Controller

This directory contains the values used to deploy the NGINX Ingress Controller for the Max Weather platform.

Recommended installation command:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f kubernetes/ingress-controller/values.yaml
```

The application ingress resource in `kubernetes/base/ingress.yaml` assumes this controller and the `nginx` ingress class are present.

## Load balancer

`values.yaml` annotates the controller Service to provision an **internal Network
Load Balancer** (`aws-load-balancer-type: nlb`, `aws-load-balancer-internal:
true`). The NLB has no public IP; API Gateway reaches it through a VPC Link, so
API Gateway is the only public entry point.

Deploy order matters: this controller must be installed **before** the full
Terraform apply that wires the API Gateway VPC Link, because that apply looks up
the internal NLB (by the `kubernetes.io/service-name` tag) to bind the VPC Link
to its listener. Bootstrap a fresh environment with a targeted apply
(VPC + EKS), install this controller, then run the full apply. Both environments
use the same VPC Link design.
