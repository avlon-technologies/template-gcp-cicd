# Production values. This file and backend.tf are the ONLY things that differ
# between the three environment roots.
#
# No credentials here — not passwords, not keys, not tokens. tfvars are code,
# committed to a public repository, and every value also lands in state.

environment = "prod"
project_id  = "avlon-cicd-template"
region      = "northamerica-northeast1"

# Dev owns the shared registry and build identity. This root only attaches its
# own pull access to them.
manage_shared_resources = false

cloud_run = {
  # Warm instances: prod's gated rollout smoke-tests a candidate revision on a
  # tagged URL under a timeout, and cold starts eat that budget.
  min_instances = 1
  max_instances = 10
  cpu           = "1"
  memory        = "1Gi"

  # NOTE — this is the template's deliberate compromise, and the one line to
  # revisit first when adapting it. _deploy.yml smoke-tests prod from a
  # GitHub-hosted runner over the public run.app hostname, so the service is
  # unauthenticated. A real production API sets:
  #     ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  #     allow_public_access = false
  # and gives the prod GitHub environment a GATEWAY_URL variable pointing at the
  # load balancer, which _deploy.yml already prefers when it is set.
  ingress             = "INGRESS_TRAFFIC_ALL"
  allow_public_access = true

  deletion_protection = true
}

labels = {
  workload    = "cicd-demo"
  environment = "prod"
  managed-by  = "terraform"
  repository  = "template-gcp-cicd"
}
