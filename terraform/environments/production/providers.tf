provider "aws" {
  region = "ap-southeast-1"

  # Applied to every resource that supports tags. Per-resource "Name" tags are
  # set inside the modules. "create_date" is a static value to avoid drift on
  # every apply.
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
