# -----------------------------------------------------------------------------
# This file is STRUCTURALLY IDENTICAL across dev, stg, and prod.
#
# The two maps below ARE the contract with .github/workflows — every key is a
# GitHub variable the workflows read by that exact name. `infra/README.md` shows
# how to pipe them straight into `gh variable set`.
# -----------------------------------------------------------------------------

output "github_repository_variables" {
  description = <<-EOT
    Repository-level GitHub variables (Settings > Secrets and variables >
    Actions > Variables). Take these from the root that manages shared
    resources; in the others the build entries are null because the build
    identity is created once.

    WIF_PROVIDER here is the BUILD provider — the build job declares no
    environment, so it resolves the repository-level value. Each environment
    then overrides WIF_PROVIDER with its own deploy provider (see
    github_environment_variables), which is why the same variable name appears
    at both levels.
  EOT
  value = {
    WIF_PROVIDER          = one(module.build_identity[*].workload_identity_provider_name)
    BUILD_SERVICE_ACCOUNT = one(module.build_identity[*].service_account_email)
    AR_LOCATION           = module.artifact_registry.location
    AR_PROJECT_ID         = module.artifact_registry.project_id
    AR_REPOSITORY         = module.artifact_registry.repository_id
    IMAGE_NAME            = local.image_name
  }
}

output "github_environment_variables" {
  description = "GitHub variables for this environment (Settings > Environments > <env> > Variables). WIF_PROVIDER shadows the repository-level value so a deploy job federates through the environment-pinned provider."
  value = {
    WIF_PROVIDER            = module.deploy_identity.workload_identity_provider_name
    DEPLOY_SERVICE_ACCOUNT  = module.deploy_identity.service_account_email
    RUNTIME_SERVICE_ACCOUNT = module.cloud_run.runtime_service_account_email
    GCP_PROJECT_ID          = var.project_id
    GCP_REGION              = var.region
    SERVICE_NAME            = module.cloud_run.cloud_run_service_name
  }
}

output "cloud_run_service_uri" {
  description = "run.app URI of this environment's service — what the deploy workflow smoke-tests when no GATEWAY_URL is set."
  value       = module.cloud_run.cloud_run_service_uri
}

output "deploy_identity_attribute_condition" {
  description = "The CEL condition a GitHub OIDC token must satisfy to obtain this environment's deploy identity. Surfaced so the blast-radius boundary is checkable with `terraform output`, not only in the console."
  value       = module.deploy_identity.attribute_condition
}

output "artifact_registry_repository_url" {
  description = "Registry path images are pushed to and pulled from. Appending the IMAGE_NAME variable gives the image the pipeline builds."
  value       = module.artifact_registry.repository_url
}
