provider "aws" {
  region = "ap-southeast-1"

  default_tags {
    tags = {
      project     = "max-weather"
      environment = "production"
      managed_by  = "terraform"
      repository  = "max-weather-platform"
      create_date = "2026-06-27"
    }
  }
}
