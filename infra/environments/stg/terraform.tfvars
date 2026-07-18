# Staging values. This file and backend.tf are the ONLY things that differ
# between the three environment roots.
#
# No credentials here — not passwords, not keys, not tokens. tfvars are code,
# committed to a public repository, and every value also lands in state.

environment = "stg"
project_id  = "avlon-cicd-template"
region      = "northamerica-northeast1"

# Dev owns the shared registry and build identity. This root only attaches its
# own pull access to them.
manage_shared_resources = false

cloud_run = {
  min_instances = 0
  max_instances = 4
  cpu           = "1"
  memory        = "512Mi"

  # See the note in dev/terraform.tfvars: the pipeline's smoke test reaches the
  # service directly from a GitHub-hosted runner.
  ingress             = "INGRESS_TRAFFIC_ALL"
  allow_public_access = true

  deletion_protection = true
}

labels = {
  workload    = "cicd-demo"
  environment = "stg"
  managed-by  = "terraform"
  repository  = "template-gcp-cicd"
}
