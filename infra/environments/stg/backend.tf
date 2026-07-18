# State lives in the environment's state bucket, under a prefix named for the
# workload: one state per deployable workload per environment.
#
# BOOTSTRAP ORDERING — read before the first `terraform init`:
# This bucket is NOT created by this configuration. It is platform
# infrastructure, provisioned by the backend-bootstrap stack that owns all state
# buckets (versioning, soft delete, dual-region, bucket-scoped IAM). If
# `terraform init` fails with a 404 or 403 on the bucket, the bucket or your
# IAM grant on it does not exist yet — that is a platform prerequisite, not
# something to work around by falling back to local state. See infra/README.md.
terraform {
  backend "gcs" {
    bucket = "avlon-tfstate-stg"
    prefix = "template-gcp-cicd"
  }
}
