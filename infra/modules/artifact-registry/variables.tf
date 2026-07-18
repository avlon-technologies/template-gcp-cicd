variable "project_id" {
  description = "GCP project that hosts the Docker repository."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "location" {
  description = "Artifact Registry location (a GCP region, e.g. northamerica-northeast1). Images are addressed as `<location>-docker.pkg.dev/<project_id>/<repository_id>/<image>`."
  type        = string
}

variable "repository_id" {
  description = "Repository name within Artifact Registry, e.g. `containers`. One repository serves every environment — see create_repository."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,62}$", var.repository_id))
    error_message = "repository_id must be lowercase alphanumeric/hyphens and start with a letter."
  }
}

variable "create_repository" {
  description = <<-EOT
    Whether this root creates the repository, or only attaches IAM to an
    existing one.

    The registry is SHARED ACROSS ENVIRONMENTS by design: build-once,
    promote-many means the digest staging verified is the digest production
    runs, and that is only possible when one artifact lives in one place. But
    each environment is an independent Terraform root with its own state, and
    exactly one of them can own the resource. Whichever root sets
    `manage_shared_resources = true` (dev, by convention) creates it; the others
    set this false and still get their IAM grants, which reference the
    repository by its coordinates rather than by resource attribute, so no
    cross-state dependency is created.
  EOT
  type        = bool
  default     = true
}

variable "immutable_tags" {
  description = "Reject pushes that would move an existing tag. Leave true: it turns 'a tag was overwritten' from a detectable incident into an impossible one, and it is the property that makes tag-based traceability trustworthy."
  type        = bool
  default     = true
}

variable "untagged_retention_days" {
  description = "Delete untagged image versions older than this many days. Untagged digests are leftovers from superseded or interrupted builds; 30 days comfortably outlives any rollback window that still references an old digest. Set null to disable the cleanup policy."
  type        = number
  default     = 30

  validation {
    condition     = var.untagged_retention_days == null ? true : var.untagged_retention_days >= 1
    error_message = "untagged_retention_days must be at least 1, or null to disable cleanup."
  }
}

variable "cleanup_policy_dry_run" {
  description = "Evaluate cleanup policies and log what they would delete without deleting anything. Useful for one release cycle after changing retention."
  type        = bool
  default     = false
}

variable "writer_members" {
  description = "IAM members granted `roles/artifactregistry.writer` on the repository — the build identity, and nothing else. Deploy identities never push."
  type        = list(string)
  default     = []
}

variable "reader_members" {
  description = "IAM members granted `roles/artifactregistry.reader` on the repository — each environment's Cloud Run service agent (which performs the image pull) and its runtime service account."
  type        = list(string)
  default     = []
}

variable "description" {
  description = "Human-readable description of the repository."
  type        = string
  default     = "Shared container images. One registry for all environments; promotion is by digest, never by rebuild."
}

variable "labels" {
  description = "Labels applied to the repository."
  type        = map(string)
  default     = {}
}
