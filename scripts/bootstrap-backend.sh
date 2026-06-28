#!/usr/bin/env bash
set -euo pipefail

# One-time bootstrap for the Terraform S3 remote backend.
#
# Terraform cannot create the backend that stores its own state (chicken/egg),
# so this script provisions the S3 bucket (versioned, encrypted, private) once,
# before the first `terraform init`. State locking uses S3 native locking
# (use_lockfile = true in backend.tf), so no DynamoDB table is required.
#
# Usage:
#   AWS_REGION=ap-southeast-1 BUCKET=mw-apse1-tfstate-bucket-01 ./scripts/bootstrap-backend.sh
#
# Then run, in each environment directory:
#   terraform init -backend-config=backend.hcl

region="${AWS_REGION:?set AWS_REGION}"
bucket="${BUCKET:?set BUCKET (must be globally unique)}"

echo "Creating S3 bucket ${bucket} in ${region}"
if [[ "${region}" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "${bucket}" --region "${region}"
else
  aws s3api create-bucket --bucket "${bucket}" --region "${region}" \
    --create-bucket-configuration LocationConstraint="${region}"
fi

aws s3api put-bucket-versioning --bucket "${bucket}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "${bucket}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "${bucket}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Done. Use these values in each environment's backend.hcl:"
echo "  bucket = \"${bucket}\""
echo "  region = \"${region}\""
