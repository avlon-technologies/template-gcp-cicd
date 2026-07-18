# -----------------------------------------------------------------------------
# This file is STRUCTURALLY IDENTICAL across dev, stg, and prod. A change here
# is a change to all three. Environment differences live in terraform.tfvars and
# nowhere else.
#
# Values that must NOT differ between environments carry a default here rather
# than appearing in tfvars, so they cannot drift: the GitHub repository the
# trust boundary is built on, and the shared registry coordinates that
# build-once-promote-many depends on. Values that legitimately differ have no
# default, so every environment is forced to state them explicitly.
# -----------------------------------------------------------------------------

variable "environment" {
  description = "Deployment environment code. Drives resource naming, the GitHub environment the deploy identity is bound to, and the state bucket this root writes to."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be one of: dev, stg, prod."
  }
}

variable "project_id" {
  description = "GCP project this environment's Cloud Run service, CI identities, and IAM bindings live in."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "region" {
  description = "Region for the Cloud Run service."
  type        = string
}

variable "workload" {
  description = "Short workload name used in all derived resource names. Identical in every environment."
  type        = string
  default     = "cicd-demo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.workload))
    error_message = "workload must be lowercase alphanumeric/hyphens, start with a letter, max 12 chars."
  }
}

variable "component" {
  description = "Component suffix for this deployable. Baked into the Cloud Run service name and therefore into its run.app hostname — it cannot be changed without recreating the service."
  type        = string
  default     = "api"
}

variable "github_repository" {
  description = "GitHub repository whose Actions jobs may federate into this project, as `OWNER/REPO`. Defaulted rather than set per environment: it is the same repository for all three, and a per-environment typo here would silently widen or break the trust boundary."
  type        = string
  default     = "Grv91/template-gcp-cicd"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in OWNER/REPO form."
  }
}

variable "manage_shared_resources" {
  description = <<-EOT
    Whether this root owns the resources shared by all three environments: the
    Artifact Registry repository and the repository-scoped build identity.

    Exactly ONE environment sets this true (dev, by convention) — the registry
    is shared on purpose, because promotion by digest requires one artifact in
    one place, and only one Terraform state can own a given resource. The other
    two roots set it false and still attach their own IAM to the registry.
  EOT
  type        = bool
}

variable "artifact_registry" {
  description = "Coordinates of the shared Docker repository. Defaulted rather than set per environment: all three environments must address the same registry or promotion silently becomes a rebuild."
  type = object({
    project_id    = string
    location      = string
    repository_id = string
  })
  default = {
    project_id    = "avlon-cicd-template"
    location      = "northamerica-northeast1"
    repository_id = "containers"
  }
}

variable "cloud_run" {
  description = <<-EOT
    Shape and scale of this environment's Cloud Run service. No default: every
    environment states its own sizing, ingress posture, and public-access
    decision explicitly, so a missing tfvars line can never silently deploy
    prod with dev's settings.
  EOT
  type = object({
    min_instances                    = number
    max_instances                    = number
    cpu                              = string
    memory                           = string
    cpu_always_allocated             = optional(bool, false)
    max_instance_request_concurrency = optional(number, 80)
    request_timeout_seconds          = optional(number, 300)
    ingress                          = string
    allow_public_access              = bool
    deletion_protection              = bool
  })
}

variable "labels" {
  description = "Labels applied to this environment's resources."
  type        = map(string)
}
