locals {
  region_codes = {
    northamerica-northeast1 = "nane1"
    northamerica-northeast2 = "nane2"
    us-central1             = "usce1"
    us-east1                = "usea1"
    europe-west1            = "euwe1"
  }

  region_code  = local.region_codes[var.region]
  service_name = "run-${var.workload}-${var.component}-${var.environment}-${local.region_code}"

  create_runtime_service_account = var.runtime_service_account_email == null

  runtime_service_account_email = local.create_runtime_service_account ? google_service_account.runtime[0].email : var.runtime_service_account_email
}

# Runtime identity: what the container runs AS. Deliberately distinct from the
# deploy identity, and created with no permissions at all — every grant it ever
# receives is an explicit, greppable decision made by the caller.
resource "google_service_account" "runtime" {
  count = local.create_runtime_service_account ? 1 : 0

  project      = var.project_id
  account_id   = "sa-app-${var.environment}"
  display_name = "${var.workload}-${var.component} runtime (${var.environment})"
  description  = "Identity the ${local.service_name} container runs as. Holds only what the application itself needs."
}

resource "google_cloud_run_v2_service" "this" {
  project  = var.project_id
  name     = local.service_name
  location = var.region
  ingress  = var.ingress
  labels   = var.labels

  deletion_protection = var.deletion_protection

  template {
    service_account                  = local.runtime_service_account_email
    execution_environment            = var.execution_environment
    max_instance_request_concurrency = var.max_instance_request_concurrency
    timeout                          = "${var.request_timeout_seconds}s"

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.bootstrap_image

      ports {
        container_port = var.container_port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        # cpu_idle = true means the CPU is throttled between requests. Inverted
        # from the variable so the caller's flag reads positively.
        cpu_idle = !var.cpu_always_allocated
      }

      dynamic "env" {
        for_each = var.environment_variables
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  # ---------------------------------------------------------------------------
  # THE OWNERSHIP SPLIT — read this before changing anything above.
  #
  # Two systems write to this one resource, and they own different things:
  #
  #   Terraform owns that the service EXISTS and what SHAPE it has — its name,
  #   region, ingress, scaling bounds, CPU/memory, concurrency, timeout,
  #   runtime service account, invoker IAM.
  #
  #   The pipeline owns WHICH IMAGE IS RUNNING and WHERE TRAFFIC GOES. It
  #   deploys imperatively (`gcloud run deploy --image ...@sha256:...`,
  #   `gcloud run services update-traffic ...`) because the promotable identity
  #   is a digest produced by a build that happens long after any apply.
  #
  # Without the ignore_changes below, those two owners fight, and the fight is
  # silent and destructive: every `terraform apply` after a deploy would see the
  # live digest differ from `bootstrap_image` and cheerfully create a new
  # revision rolling production BACK to the placeholder image. During a gated
  # rollout it would also delete the candidate tag and reset traffic mid-flight.
  # The classic symptom is "production reverted itself hours after a good
  # deploy, and nobody deployed anything" — the cause being a routine
  # infrastructure apply for an unrelated change.
  #
  # So Terraform stops asserting the fields the pipeline mutates:
  #
  #   image        - the whole point; set once at creation, owned by the deploy
  #                  workflow from then on.
  #   traffic      - `--no-traffic`, `--tag`, and `update-traffic` are the
  #                  gated-rollout mechanism. Terraform must not have opinions
  #                  about which revision is serving or which tags exist.
  #   labels       - `gcloud run deploy --labels build-label=...` rewrites
  #                  service and revision labels on every deploy.
  #   annotations  - written by gcloud and by Cloud Run itself.
  #   revision     - revision names are generated per deploy.
  #   client / client_version - gcloud stamps these to identify the deployer.
  #
  # What this does NOT mean: it is not "Terraform gave up on this resource". A
  # change to scaling, ingress, or the runtime service account still plans and
  # applies normally, and still takes effect on the next revision. Only the
  # pipeline-owned fields are conceded.
  #
  # Consequence to keep in mind: because `image` is ignored, `bootstrap_image`
  # is read exactly once, at creation. Changing it later is a no-op — the way to
  # change what is running is to deploy.
  # ---------------------------------------------------------------------------
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].labels,
      template[0].annotations,
      template[0].revision,
      traffic,
      labels,
      annotations,
      client,
      client_version,
    ]
  }
}

# Public invocation, opt-in. allUsers here is the difference between "anyone on
# the internet may call this" and "only IAM-holders may" — it is not a
# networking control, and it is orthogonal to `ingress`.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  count = var.allow_public_access ? 1 : 0

  project  = var.project_id
  location = google_cloud_run_v2_service.this.location
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
