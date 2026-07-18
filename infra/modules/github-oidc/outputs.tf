output "workload_identity_provider_name" {
  description = "Full resource name of the OIDC provider, for the workflow's `workload_identity_provider` input (GitHub variable WIF_PROVIDER). Note it embeds the project NUMBER, not the project ID — supplying the ID here is the classic cause of `Unable to acquire impersonated credentials`."
  value       = google_iam_workload_identity_pool_provider.this.name
}

output "workload_identity_pool_name" {
  description = "Full resource name of the workload identity pool, for constructing additional principalSet bindings outside this module."
  value       = google_iam_workload_identity_pool.this.name
}

output "service_account_email" {
  description = "Email of the CI service account this identity impersonates, for the workflow's `service_account` input (GitHub variable BUILD_SERVICE_ACCOUNT or DEPLOY_SERVICE_ACCOUNT)."
  value       = google_service_account.this.email
}

output "service_account_member" {
  description = "The service account as an IAM member string (`serviceAccount:<email>`), for granting it roles outside this module."
  value       = "serviceAccount:${google_service_account.this.email}"
}

output "service_account_id" {
  description = "Fully qualified service account resource ID, for IAM bindings that target the account itself (e.g. additional workloadIdentityUser grants)."
  value       = google_service_account.this.name
}

output "attribute_condition" {
  description = "The CEL condition tokens must satisfy to be admitted by this provider. Surfaced so the trust boundary is visible in `terraform output` and in plan review, not only in the console."
  value       = local.attribute_condition
}
