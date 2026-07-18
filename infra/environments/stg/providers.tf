terraform {
  required_version = "~> 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# `project` and `region` are explicit, never inherited from ambient gcloud CLI
# context. An engineer with another project selected in their shell must not be
# able to apply this root into it.
provider "google" {
  project = var.project_id
  region  = var.region
}
