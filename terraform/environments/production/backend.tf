terraform {
  backend "s3" {
    use_lockfile = true
    key          = "max-weather/production/terraform.tfstate"
    encrypt      = true
  }
}
