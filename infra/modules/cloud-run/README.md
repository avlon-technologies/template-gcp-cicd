# Module: `cloud-run`

Manages a **Cloud Run v2 service and its runtime identity** for one
environment — and, just as importantly, manages *only the parts of it that
Terraform should own*.

## The ownership split (read this first)

Two systems write to this one resource:

| Owner | Owns |
|-------|------|
| **Terraform** | That the service **exists** and what **shape** it has: name, region, ingress, scaling bounds, CPU/memory, concurrency, timeout, runtime service account, invoker IAM. |
| **The pipeline** | **Which image is running** and **where traffic goes**. `.github/workflows/_deploy.yml` runs `gcloud run deploy --image ...@sha256:...` and `gcloud run services update-traffic`. |

The pipeline deploys imperatively because the promotable identity is a **digest
produced by a build that happens long after any apply** — there is no way for a
Terraform configuration to know it, and no reason for a deploy to wait on an
infrastructure apply.

That split only works because the module carries a `lifecycle.ignore_changes`
on every field the pipeline mutates:

```
template[0].containers[0].image
template[0].labels
template[0].annotations
template[0].revision
traffic
labels
annotations
client
client_version
```

**Without it the two owners fight, and the fight is silent and destructive.**
Every `terraform apply` after a deploy would see the live digest differ from
`bootstrap_image` and cheerfully create a new revision rolling the environment
**back to the placeholder image**. Mid gated-rollout it would additionally
delete the candidate tag and reset traffic. The symptom is *"production reverted
itself hours after a good deploy and nobody deployed anything"* — the cause
being a routine infrastructure apply for a completely unrelated change.

What this does **not** mean: Terraform has not given up on the resource. Change
`min_instances`, `ingress`, or the runtime service account and it plans and
applies normally, taking effect on the next revision. Only the pipeline-owned
fields are conceded.

One consequence worth internalising: because `image` is ignored, **`bootstrap_image`
is read exactly once, at creation.** Changing it later is a no-op. The way to
change what is running is to deploy.

## The bootstrap image

The first `terraform apply` must supply *some* image, and at that point your
registry has never been pushed to. `bootstrap_image` therefore defaults to
Google's public `us-docker.pkg.dev/cloudrun/container/hello`, which always
exists. Terraform creates a running, healthy service; the first pipeline deploy
replaces the image and nothing ever reverts it.

This is what resolves the chicken-and-egg between "the service must exist before
the pipeline can deploy to it" and "an image must exist before the service can
be created".

## Usage

```hcl
module "cloud_run" {
  source = "../../modules/cloud-run"

  project_id  = "avlon-cicd-template"
  region      = "northamerica-northeast1"
  environment = "prod"
  workload    = "cicd-demo"
  component   = "api"

  min_instances       = 1
  max_instances       = 10
  cpu                 = "1"
  memory              = "1Gi"
  ingress             = "INGRESS_TRAFFIC_ALL"
  allow_public_access = true
  deletion_protection = true
}
```

Produces the service `run-cicd-demo-api-prod-nane1`, running as a purpose-made
`sa-app-prod` service account that holds no permissions until the caller grants
some.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `project_id` | `string` | — | Project hosting the service. |
| `region` | `string` | — | Region; must have a short code in `locals.region_codes` (it is part of the name). |
| `environment` | `string` | — | `dev` \| `stg` \| `prod`. |
| `workload` | `string` | — | Short workload name, max 12 chars. |
| `component` | `string` | `"api"` | Component suffix. Baked into the run.app hostname — cannot be added later without recreating the service. |
| `bootstrap_image` | `string` | Google hello container | Creation-time image only; ignored thereafter. |
| `container_port` | `number` | `8080` | Must match the `--port 8080` in `_deploy.yml`. |
| `min_instances` | `number` | `0` | Warm instances (0–10). |
| `max_instances` | `number` | `2` | Cost ceiling (1–100). |
| `cpu` | `string` | `"1"` | CPU per instance. |
| `memory` | `string` | `"512Mi"` | Memory per instance. |
| `cpu_always_allocated` | `bool` | `false` | `false` = CPU throttled between requests. Set `true` only for real background work. |
| `max_instance_request_concurrency` | `number` | `80` | Concurrent requests per instance (1–1000). |
| `request_timeout_seconds` | `number` | `300` | Per-request timeout (1–3600). |
| `ingress` | `string` | `"INGRESS_TRAFFIC_ALL"` | Who may reach the ingress endpoint. |
| `allow_public_access` | `bool` | `false` | Grant `run.invoker` to `allUsers`. Insecure is opt-in. |
| `execution_environment` | `string` | `"EXECUTION_ENVIRONMENT_GEN2"` | Gen1 or Gen2. |
| `environment_variables` | `map(string)` | `{}` | Non-secret env vars. Secrets are mounted from Secret Manager, never passed here. |
| `runtime_service_account_email` | `string` | `null` | Existing SA to run as. `null` creates `sa-app-<environment>`. |
| `deletion_protection` | `bool` | `true` | Refuse API-level deletion. |
| `labels` | `map(string)` | `{}` | Creation-time labels — the pipeline overwrites service labels on every deploy (hence `ignore_changes`). |

## Outputs

| Name | Description |
|------|-------------|
| `cloud_run_service_name` | → GitHub variable `SERVICE_NAME`. |
| `cloud_run_service_uri` | run.app URI; generated by Cloud Run and not derivable from the name. |
| `cloud_run_service_id` | Fully qualified resource ID, for load-balancer backends. |
| `cloud_run_service_location` | → GitHub variable `GCP_REGION`. |
| `runtime_service_account_email` | → GitHub variable `RUNTIME_SERVICE_ACCOUNT`. |
| `runtime_service_account_member` | `serviceAccount:<email>`, for registry/secret/database grants. |

## Notes

- `ingress` and `allow_public_access` are orthogonal. Ingress is a network
  control; the invoker binding is an authorization one. A service can be
  reachable and refuse you, or authorize you and be unreachable.
- Anything other than `INGRESS_TRAFFIC_ALL` breaks the deploy workflow's smoke
  test unless the environment also sets `GATEWAY_URL` (which `_deploy.yml`
  prefers when present) or the job runs on a self-hosted runner (the `runner`
  input).
- The runtime service account is a **different identity** from the deploy
  account. It should hold only what the application itself needs.
