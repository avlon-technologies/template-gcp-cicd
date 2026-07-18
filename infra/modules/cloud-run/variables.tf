variable "project_id" {
  description = "GCP project that hosts the Cloud Run service and its runtime service account."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "region" {
  description = "Region for the Cloud Run service. Constrained to regions with a defined short code in the naming standard, because the code is part of the service name."
  type        = string

  validation {
    condition = contains([
      "northamerica-northeast1",
      "northamerica-northeast2",
      "us-central1",
      "us-east1",
      "europe-west1",
    ], var.region)
    error_message = "region must be one of: northamerica-northeast1, northamerica-northeast2, us-central1, us-east1, europe-west1. Add the region and its short code to locals.region_codes to extend this set."
  }
}

variable "environment" {
  description = "Deployment environment code. Part of the derived service name."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be one of: dev, stg, prod."
  }
}

variable "workload" {
  description = "Short workload name used in the derived service name (lowercase, hyphens, max 12 chars)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.workload))
    error_message = "workload must be lowercase alphanumeric/hyphens, start with a letter, max 12 chars."
  }
}

variable "component" {
  description = <<-EOT
    Component suffix identifying which deployable this is (`api`, `web`).
    Required even when the workload has only one service: the component suffix
    cannot be added later without destroying and recreating the service,
    because the name is baked into the default *.run.app hostname.
  EOT
  type        = string
  default     = "api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,11}$", var.component))
    error_message = "component must be lowercase alphanumeric/hyphens, start with a letter, max 12 chars."
  }
}

variable "bootstrap_image" {
  description = <<-EOT
    Image used ONLY when Terraform first creates the service. The deploy
    pipeline replaces it on the first `gcloud run deploy`, and Terraform ignores
    the field forever after (see the lifecycle block in main.tf). The default is
    Google's public hello container, which exists before your registry has ever
    been pushed to and so breaks the chicken-and-egg between "the service must
    exist" and "an image must exist".
  EOT
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "container_port" {
  description = "Port the container listens on. 8080 matches the `--port 8080` the deploy workflow passes; changing one without the other makes every deploy a config fight."
  type        = number
  default     = 8080

  validation {
    condition     = var.container_port > 0 && var.container_port < 65536
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "min_instances" {
  description = "Minimum number of instances kept warm (0-10). 0 scales to zero and accepts cold starts; raise it where first-request latency matters."
  type        = number
  default     = 0

  validation {
    condition     = var.min_instances >= 0 && var.min_instances <= 10
    error_message = "min_instances must be between 0 and 10."
  }
}

variable "max_instances" {
  description = "Maximum number of instances (1-100). This is the cost ceiling and the downstream-dependency protection; it is not a performance setting."
  type        = number
  default     = 2

  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 100
    error_message = "max_instances must be between 1 and 100."
  }
}

variable "cpu" {
  description = "CPU allocation per instance, as a Cloud Run quantity (`1`, `2`, `4`, or `500m`)."
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory per instance, as a Cloud Run quantity (`512Mi`, `1Gi`, `2Gi`)."
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.memory))
    error_message = "memory must be a Cloud Run quantity such as 512Mi or 1Gi."
  }
}

variable "cpu_always_allocated" {
  description = <<-EOT
    Keep the CPU allocated between requests instead of throttling it. Named
    positively per the variables standard; it maps to the inverse of Cloud Run's
    `cpu_idle`.

    false (the default) = CPU throttled outside request handling, which is
    cheaper and correct for a request/response API. Set true only when the
    container does real background work — timers, queue consumers, warmed
    caches — because throttled background work fails in ways that are extremely
    hard to diagnose.
  EOT
  type        = bool
  default     = false
}

variable "max_instance_request_concurrency" {
  description = "Maximum concurrent requests per instance (1-1000). Lower it for CPU-bound or thread-unsafe workloads."
  type        = number
  default     = 80

  validation {
    condition     = var.max_instance_request_concurrency >= 1 && var.max_instance_request_concurrency <= 1000
    error_message = "max_instance_request_concurrency must be between 1 and 1000."
  }
}

variable "request_timeout_seconds" {
  description = "Per-request timeout in seconds (1-3600)."
  type        = number
  default     = 300

  validation {
    condition     = var.request_timeout_seconds >= 1 && var.request_timeout_seconds <= 3600
    error_message = "request_timeout_seconds must be between 1 and 3600."
  }
}

variable "ingress" {
  description = <<-EOT
    Which callers may reach the service's ingress endpoint:
      INGRESS_TRAFFIC_ALL                   - any client on the internet (still subject to the invoker IAM check)
      INGRESS_TRAFFIC_INTERNAL_ONLY         - only the VPC and other internal Google traffic
      INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER - internal traffic plus an external load balancer

    Note the interaction with the pipeline: the deploy workflow's smoke test
    runs on a GitHub-hosted runner and hits the service directly, so anything
    other than INGRESS_TRAFFIC_ALL requires either a self-hosted runner (the
    `runner` input on _deploy.yml) or a reachable GATEWAY_URL environment
    variable.
  EOT
  type        = string
  default     = "INGRESS_TRAFFIC_ALL"

  validation {
    condition = contains([
      "INGRESS_TRAFFIC_ALL",
      "INGRESS_TRAFFIC_INTERNAL_ONLY",
      "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
    ], var.ingress)
    error_message = "ingress must be one of: INGRESS_TRAFFIC_ALL, INGRESS_TRAFFIC_INTERNAL_ONLY, INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER."
  }
}

variable "allow_public_access" {
  description = <<-EOT
    Grant `roles/run.invoker` to allUsers, making the service callable without
    authentication. Defaults to false — insecure is opt-in, per the modules
    standard — so a caller who forgets this variable does not publish an API to
    the internet.

    The template's smoke tests call the service anonymously, so its environments
    set this true explicitly and visibly in tfvars. A real workload fronts the
    service with a load balancer and leaves this false.
  EOT
  type        = bool
  default     = false
}

variable "execution_environment" {
  description = "Cloud Run execution environment: EXECUTION_ENVIRONMENT_GEN2 (full Linux compatibility, slower cold start) or EXECUTION_ENVIRONMENT_GEN1."
  type        = string
  default     = "EXECUTION_ENVIRONMENT_GEN2"

  validation {
    condition     = contains(["EXECUTION_ENVIRONMENT_GEN1", "EXECUTION_ENVIRONMENT_GEN2"], var.execution_environment)
    error_message = "execution_environment must be EXECUTION_ENVIRONMENT_GEN1 or EXECUTION_ENVIRONMENT_GEN2."
  }
}

variable "environment_variables" {
  description = "Plain (non-secret) environment variables for the container. Secrets never travel through here — they are mounted from Secret Manager via the runtime service account, so Terraform never sees the value."
  type        = map(string)
  default     = {}
}

variable "runtime_service_account_email" {
  description = "Email of an existing service account for the container to run as. Leave null to have this module create `sa-app-<environment>` with no permissions of its own."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Refuse API-level deletion of the service. Leave true in stg/prod; dev may set false so the environment can actually be torn down."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to the service at creation. The deploy pipeline overwrites service labels on every `gcloud run deploy --labels`, so these are a creation-time convenience, not an enforced state — see the lifecycle block in main.tf."
  type        = map(string)
  default     = {}
}
