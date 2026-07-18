# Dev values. This file and backend.tf are the ONLY things that differ between
# the three environment roots.
#
# No credentials here — not passwords, not keys, not tokens. tfvars are code,
# committed to a public repository, and every value also lands in state.

environment = "dev"
project_id  = "avlon-cicd-template"
region      = "northamerica-northeast1"

# Dev owns the resources shared by all three environments: the one Artifact
# Registry repository and the repository-scoped build identity. Apply this root
# FIRST — stg and prod attach IAM to a registry that must already exist.
manage_shared_resources = true

cloud_run = {
  min_instances = 0 # scale to zero; cold starts are fine here
  max_instances = 2
  cpu           = "1"
  memory        = "512Mi"

  # The smoke test in _deploy.yml calls the service anonymously from a
  # GitHub-hosted runner, so the service is reachable and unauthenticated in
  # every environment of this template. A real workload puts a load balancer in
  # front, sets ingress to INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER,
  # allow_public_access to false, and gives the environment a GATEWAY_URL
  # variable for the smoke test to use instead.
  ingress             = "INGRESS_TRAFFIC_ALL"
  allow_public_access = true

  # Dev is the one environment that should be genuinely disposable.
  deletion_protection = false
}

labels = {
  workload    = "cicd-demo"
  environment = "dev"
  managed-by  = "terraform"
  repository  = "template-gcp-cicd"
}
