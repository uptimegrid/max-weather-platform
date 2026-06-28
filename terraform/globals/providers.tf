provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      application = "max-weather"
      managed_by  = "terraform"
      repository  = "max-weather-platform"
    }
  }
}
