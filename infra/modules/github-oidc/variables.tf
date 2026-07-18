variable "project_id" {
  description = "GCP project that hosts the workload identity pool, the service account, and the project IAM bindings."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "identity_name" {
  description = <<-EOT
    Short name for this CI identity, used to derive every resource name in the
    module: pool `github-<identity_name>`, provider `github-<identity_name>`,
    service account `sa-<identity_name>`. Examples: `deploy-dev`, `deploy-prod`,
    `build`. Must be unique within the project.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}[a-z0-9]$", var.identity_name))
    error_message = "identity_name must be lowercase alphanumeric/hyphens, start with a letter, 3-22 chars (keeps `sa-<identity_name>` inside the 30-char service account ID limit)."
  }
}

variable "github_repository" {
  description = "GitHub repository allowed to obtain this identity, as `OWNER/REPO`. Enforced by the provider's attribute_condition — tokens from any other repository are rejected before a service account is ever named."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in OWNER/REPO form, e.g. Grv91/template-gcp-cicd."
  }
}

variable "github_environment" {
  description = <<-EOT
    GitHub environment (`dev`, `stg`, `prod`) whose jobs may impersonate this
    identity. When set, the provider additionally requires
    `assertion.environment == <value>` and impersonation is bound to the
    `attribute.environment/<value>` principalSet — this is the blast-radius
    boundary between environments.

    Set to null ONLY for a repository-scoped identity such as the build
    identity, whose job declares no GitHub environment and therefore presents a
    token carrying no environment claim. A null value deliberately widens the
    trust to "any job in this repository", so such an identity must hold no
    deploy permission whatsoever.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.github_environment == null ? true : contains(["dev", "stg", "prod"], var.github_environment)
    error_message = "github_environment must be one of: dev, stg, prod (or null for a repository-scoped identity)."
  }
}

variable "project_roles" {
  description = <<-EOT
    Project-scoped predefined roles granted to this identity's service account.
    The default is the least-privilege deploy set: create Cloud Run revisions
    and shift traffic (`roles/run.developer`), and deploy a service that runs
    AS a runtime service account (`roles/iam.serviceAccountUser`).

    Pass `["roles/artifactregistry.writer"]` for a build identity whose registry
    lives in this same project. When the registry is a shared registry in
    another project, grant writer at repository scope instead (see the
    artifact-registry module) and leave this empty.
  EOT
  type        = list(string)
  default     = ["roles/run.developer", "roles/iam.serviceAccountUser"]

  validation {
    condition     = alltrue([for r in var.project_roles : startswith(r, "roles/")])
    error_message = "project_roles entries must be predefined role IDs starting with `roles/`."
  }

  validation {
    condition     = !contains(var.project_roles, "roles/owner") && !contains(var.project_roles, "roles/editor")
    error_message = "Basic roles (roles/owner, roles/editor) are never granted to a CI identity."
  }
}

variable "display_name" {
  description = "Human-readable display name for the service account and identity pool. Defaults to a name derived from identity_name."
  type        = string
  default     = null
}

variable "allowed_audiences" {
  description = "OIDC audiences the provider accepts. Leave empty to use Google's default audience, which is what `google-github-actions/auth` sends unmodified — override only if the workflow sets a custom audience."
  type        = list(string)
  default     = []
}
