locals {
  display_name = coalesce(var.display_name, "GitHub Actions ${var.identity_name}")

  # Each identity gets its OWN pool + provider rather than sharing one pool.
  # Reason: every environment is an independent Terraform root with its own
  # state (see environments.md). A single shared pool would have to be owned by
  # one root and referenced by the others, coupling prod's state to dev's. A
  # pool per identity keeps each root self-contained.
  #
  # NOTE: a deleted workload identity pool is soft-deleted for 30 days and its
  # ID cannot be reused until it is purged (`gcloud iam
  # workload-identity-pools undelete`). Renaming an identity is cheap;
  # destroying and recreating one under the same name is not.
  pool_id     = "github-${var.identity_name}"
  provider_id = "github-${var.identity_name}"

  environment_scoped = var.github_environment != null

  # The attribute condition is the outer boundary: it decides which tokens the
  # provider will even look at. Without it the provider accepts a token from
  # ANY repository on GitHub — this is the single most common way a WIF setup
  # is got wrong, and Google will happily let you create the provider that way.
  #
  # Environment-scoped identities pin BOTH claims. `assertion.environment` is
  # set by GitHub from the job's `environment:` declaration and cannot be forged
  # or overridden by workflow inputs, so a dev-targeted job — even a malicious
  # one — cannot present a token that satisfies the prod provider.
  repository_condition = format("assertion.repository == %q", var.github_repository)
  attribute_condition = local.environment_scoped ? format(
    "%s && assertion.environment == %q", local.repository_condition, var.github_environment
  ) : local.repository_condition

  # A token from a job with no `environment:` declaration carries no
  # `environment` claim at all, and mapping a missing claim unguarded fails the
  # exchange. Guard it for repository-scoped identities; environment-scoped
  # providers are already unreachable without the claim.
  environment_mapping = local.environment_scoped ? "assertion.environment" : "has(assertion.environment) ? assertion.environment : \"\""

  # Impersonation is granted to a SET of principals, not one principal: any
  # token this pool admitted whose environment attribute is <env>. Paired with
  # the attribute condition above, the effective grant is
  # "jobs of THIS repo running in THIS GitHub environment" — and GitHub will
  # not mint an `:environment:prod` token until that environment's protection
  # rules and required reviewers are satisfied, so the human gate sits in front
  # of the credential rather than after it.
  principal_set = local.environment_scoped ? format(
    "principalSet://iam.googleapis.com/%s/attribute.environment/%s",
    google_iam_workload_identity_pool.this.name,
    var.github_environment
    ) : format(
    "principalSet://iam.googleapis.com/%s/attribute.repository/%s",
    google_iam_workload_identity_pool.this.name,
    var.github_repository
  )
}

resource "google_iam_workload_identity_pool" "this" {
  project                   = var.project_id
  workload_identity_pool_id = local.pool_id
  display_name              = local.display_name
  description               = "GitHub Actions OIDC federation for ${var.github_repository}${local.environment_scoped ? " (${var.github_environment})" : ""}."
}

resource "google_iam_workload_identity_pool_provider" "this" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.this.workload_identity_pool_id
  workload_identity_pool_provider_id = local.provider_id
  display_name                       = local.display_name
  description                        = "Admits GitHub Actions tokens matching: ${local.attribute_condition}"

  attribute_condition = local.attribute_condition

  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.environment" = local.environment_mapping
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
    # Empty list => Google's default audience, which is exactly what
    # google-github-actions/auth sends when left unconfigured.
    allowed_audiences = var.allowed_audiences
  }
}

resource "google_service_account" "this" {
  project      = var.project_id
  account_id   = "sa-${var.identity_name}"
  display_name = local.display_name
  description  = "CI identity for ${var.github_repository}${local.environment_scoped ? " (${var.github_environment})" : ""}. Impersonated via Workload Identity Federation — no key exists."
}

resource "google_service_account_iam_member" "workload_identity_user" {
  service_account_id = google_service_account.this.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.principal_set
}

resource "google_project_iam_member" "roles" {
  for_each = toset(var.project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.this.email}"
}
