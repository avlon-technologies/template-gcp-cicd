# -----------------------------------------------------------------------------
# This file is STRUCTURALLY IDENTICAL across dev, stg, and prod. Composition
# only — no logic, no environment conditionals. Differences come from
# terraform.tfvars.
# -----------------------------------------------------------------------------

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # Registry-internal image path, <workload>/<workload>-<component>. This is the
  # pipeline's IMAGE_NAME and is deliberately environment-free: one image is
  # built once and promoted by digest to every environment.
  image_name = "${var.workload}/${var.workload}-${var.component}"

  # Cloud Run pulls images as its per-project SERVICE AGENT, not as the runtime
  # service account and not as the deploy identity. Within a single project the
  # agent's access is implicit; the moment the registry moves to a shared
  # platform project it is not, and the failure is a deploy that succeeds and a
  # revision that never starts ("Image not found or access denied"). Granting it
  # explicitly costs nothing and removes that trap ahead of time.
  cloud_run_service_agent = "serviceAccount:service-${data.google_project.this.number}@serverless-robot-prod.iam.gserviceaccount.com"
}

# -----------------------------------------------------------------------------
# CI identities
#
# Two distinct trust levels, and the asymmetry is deliberate:
#
#   build  - repository-scoped. The build job declares no GitHub environment, so
#            its token carries no environment claim and it cannot be pinned to
#            one. Any job in this repository, including one on a branch, can
#            obtain it. That is acceptable ONLY because this identity can do
#            exactly one thing: write images to the registry. Pushing an image
#            ships nothing.
#
#   deploy - environment-scoped. Pinned to `repo AND environment`, so the token
#            a dev-targeted job receives cannot satisfy the stg or prod
#            provider, no matter what the workflow asks for. Deploying is
#            gated behind a credential that only an approved,
#            environment-declaring job can mint.
# -----------------------------------------------------------------------------

module "build_identity" {
  source = "../../modules/github-oidc"

  count = var.manage_shared_resources ? 1 : 0

  project_id        = var.project_id
  identity_name     = "build"
  github_repository = var.github_repository

  # No environment claim to bind to — see the comment above.
  github_environment = null

  # No project roles at all. Its one permission, `artifactregistry.writer`, is
  # granted at REPOSITORY scope by the artifact_registry module below: narrower
  # than a project binding, and correct whether or not the registry ever moves
  # to a shared platform project.
  project_roles = []
}

module "deploy_identity" {
  source = "../../modules/github-oidc"

  project_id         = var.project_id
  identity_name      = "deploy-${var.environment}"
  github_repository  = var.github_repository
  github_environment = var.environment

  # project_roles intentionally omitted: the module's default is the
  # least-privilege deploy set (run.developer + iam.serviceAccountUser).
}

# -----------------------------------------------------------------------------
# Shared container registry
#
# ONE registry for all environments. Every root calls this module: the owning
# root creates the repository, all roots attach their own environment's pull
# access. IAM here addresses the repository by coordinates, so the non-owning
# roots take no dependency on the owning root's state.
# -----------------------------------------------------------------------------

module "artifact_registry" {
  source = "../../modules/artifact-registry"

  create_repository = var.manage_shared_resources

  project_id    = var.artifact_registry.project_id
  location      = var.artifact_registry.location
  repository_id = var.artifact_registry.repository_id
  labels        = var.labels

  writer_members = var.manage_shared_resources ? [one(module.build_identity[*].service_account_member)] : []

  reader_members = [
    local.cloud_run_service_agent,
    module.cloud_run.runtime_service_account_member,
  ]
}

# -----------------------------------------------------------------------------
# The service itself
#
# Terraform creates it with a placeholder image and then concedes the image and
# traffic to the pipeline — see the ownership-split comment in the module. This
# root's job is that the service exists with the right shape before the first
# deploy ever runs.
# -----------------------------------------------------------------------------

module "cloud_run" {
  source = "../../modules/cloud-run"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  workload    = var.workload
  component   = var.component
  labels      = var.labels

  min_instances                    = var.cloud_run.min_instances
  max_instances                    = var.cloud_run.max_instances
  cpu                              = var.cloud_run.cpu
  memory                           = var.cloud_run.memory
  cpu_always_allocated             = var.cloud_run.cpu_always_allocated
  max_instance_request_concurrency = var.cloud_run.max_instance_request_concurrency
  request_timeout_seconds          = var.cloud_run.request_timeout_seconds
  ingress                          = var.cloud_run.ingress
  allow_public_access              = var.cloud_run.allow_public_access
  deletion_protection              = var.cloud_run.deletion_protection
}
