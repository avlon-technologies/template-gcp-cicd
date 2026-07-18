output "repository_url" {
  description = "Registry path images are pushed to and pulled from: `<location>-docker.pkg.dev/<project>/<repository>`. The build workflow appends `/<IMAGE_NAME>`."
  value       = local.repository_url
}

output "repository_id" {
  description = "Repository name, for the pipeline's AR_REPOSITORY variable."
  value       = var.repository_id
}

output "location" {
  description = "Repository location, for the pipeline's AR_LOCATION variable (it also forms the `<location>-docker.pkg.dev` host that `gcloud auth configure-docker` is pointed at)."
  value       = var.location
}

output "project_id" {
  description = "Project hosting the repository, for the pipeline's AR_PROJECT_ID variable."
  value       = var.project_id
}
