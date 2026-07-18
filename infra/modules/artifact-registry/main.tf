locals {
  # Derived from variables, never from the resource, so every reference below
  # works identically whether or not this root is the one that creates the
  # repository. That is what keeps the non-owning roots free of a cross-state
  # dependency on the owning root.
  repository_url = "${var.location}-docker.pkg.dev/${var.project_id}/${var.repository_id}"
}

resource "google_artifact_registry_repository" "this" {
  count = var.create_repository ? 1 : 0

  project       = var.project_id
  location      = var.location
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = var.description
  labels        = var.labels

  docker_config {
    immutable_tags = var.immutable_tags
  }

  cleanup_policy_dry_run = var.cleanup_policy_dry_run

  dynamic "cleanup_policies" {
    for_each = var.untagged_retention_days == null ? [] : [var.untagged_retention_days]
    content {
      id     = "delete-untagged"
      action = "DELETE"
      condition {
        tag_state  = "UNTAGGED"
        older_than = "${cleanup_policies.value * 24 * 60 * 60}s"
      }
    }
  }

  # The registry outlives every service that pulls from it, and deleting it
  # destroys the rollback history for all three environments at once.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_artifact_registry_repository_iam_member" "writer" {
  for_each = toset(var.writer_members)

  project    = var.project_id
  location   = var.location
  repository = var.repository_id
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "reader" {
  for_each = toset(var.reader_members)

  project    = var.project_id
  location   = var.location
  repository = var.repository_id
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
