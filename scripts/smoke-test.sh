#!/usr/bin/env bash
set -euo pipefail

# Post-rollout smoke test used by the Jenkins deploy pipeline. It runs an
# in-cluster request against the deployed weather-api /health endpoint using the
# current kubeconfig context (the pipeline points kubeconfig at the target
# environment's cluster before calling this). Checking from inside the cluster
# keeps the gate independent of external DNS, the ingress NLB, security groups,
# and the API Gateway auth layer.

environment="${1:-staging}"
namespace="${NAMESPACE:-max-weather}"

echo "Running smoke test for ${environment}: GET /health on weather-api"
body=$(kubectl -n "${namespace}" exec deploy/weather-api -- \
  node -e "fetch('http://127.0.0.1:8080/health').then(r=>r.text()).then(t=>process.stdout.write(t)).catch(e=>{console.error(e);process.exit(1)})")
echo "Response: ${body}"
echo "${body}" | grep -q '"status":"ok"'
echo "Smoke test passed for ${environment}"
