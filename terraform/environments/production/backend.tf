terraform {
  backend "s3" {
    # bucket / region / dynamodb_table are provided at init time via:
    #   terraform init -backend-config=backend.hcl
    # See backend.hcl.example and scripts/bootstrap-backend.sh.
    use_lockfile = true
    key          = "max-weather/production/terraform.tfstate"
    encrypt      = true
  }
}
