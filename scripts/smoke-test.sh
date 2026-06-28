#!/usr/bin/env bash
set -euo pipefail

# Deployment smoke test used by the Jenkins pipeline after each environment
# rollout.
#
# By default it validates the freshly deployed workload through the NGINX
# Ingress endpoint, which is unauthenticated (the OAuth2/JWT check lives at the
# API Gateway edge, not on the in-cluster service). This keeps the rollout gate
# independent of token issuance.
#
# To smoke test through the authenticated API Gateway instead, set BASE_URL to
# the API Gateway endpoint and provide ACCESS_TOKEN with a valid bearer token.

environment="${1:-staging}"
base_url="${BASE_URL:-http://weather.example.com}"
access_token="${ACCESS_TOKEN:-}"

echo "Running smoke test for ${environment} against ${base_url}"

if [[ -n "${access_token}" ]]; then
  curl --fail --silent --show-error \
    --header "Authorization: Bearer ${access_token}" \
    "${base_url}/health" >/dev/null
else
  curl --fail --silent --show-error "${base_url}/health" >/dev/null
fi

echo "Smoke test passed for ${environment}"
