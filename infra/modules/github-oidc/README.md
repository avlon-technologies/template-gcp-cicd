# Module: `github-oidc`

Creates one **GitHub Actions CI identity** on Google Cloud: a workload identity
pool, an OIDC provider that admits GitHub's tokens, a service account, and the
`workloadIdentityUser` binding that lets admitted tokens impersonate it. No
service account key is created — there is nothing to leak, expire, or rotate.

The opinionated decisions it bakes in:

- **The `attribute_condition` is mandatory, not optional.** Google lets you
  create a provider without one, and such a provider accepts a token from *any*
  repository on GitHub. This module always pins at least the repository.
- **Environment scoping is the default.** With `github_environment` set, the
  provider requires both `assertion.repository` and `assertion.environment`, and
  impersonation is bound to the `attribute.environment/<env>` principalSet. A
  dev-targeted job cannot obtain the prod identity — GitHub sets the
  `environment` claim from the job's `environment:` declaration and no workflow
  input can forge it.
- **One pool per identity, not one shared pool.** Each environment is an
  independent Terraform root with its own state; a shared pool would have to be
  owned by one root and referenced by the others, coupling prod's state to
  dev's.
- **Least privilege by default.** `project_roles` defaults to
  `run.developer` + `iam.serviceAccountUser` — enough to create revisions and
  shift traffic on a service that runs as a runtime service account, and nothing
  more. Basic roles are rejected by a validation block.

## Usage

An environment-scoped deploy identity:

```hcl
module "deploy_identity" {
  source = "../../modules/github-oidc"

  project_id         = "avlon-cicd-template"
  identity_name      = "deploy-prod"
  github_repository  = "Grv91/template-gcp-cicd"
  github_environment = "prod"
}
```

A repository-scoped build identity — deliberately the weaker boundary, and
therefore granted no project roles at all (its registry write access is granted
at repository scope by the `artifact-registry` module):

```hcl
module "build_identity" {
  source = "../../modules/github-oidc"

  project_id         = "avlon-cicd-template"
  identity_name      = "build"
  github_repository  = "Grv91/template-gcp-cicd"
  github_environment = null
  project_roles      = []
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `project_id` | `string` | — | Project hosting the pool, service account, and project IAM bindings. |
| `identity_name` | `string` | — | Short name; derives pool `github-<name>`, provider `github-<name>`, SA `sa-<name>`. |
| `github_repository` | `string` | — | `OWNER/REPO` allowed to obtain this identity. |
| `github_environment` | `string` | `null` | GitHub environment to pin to. `null` = repository-scoped (build identity only). |
| `project_roles` | `list(string)` | `["roles/run.developer", "roles/iam.serviceAccountUser"]` | Project-scoped roles for the service account. |
| `display_name` | `string` | `null` | Display name; derived from `identity_name` when unset. |
| `allowed_audiences` | `list(string)` | `[]` | Empty = Google's default audience, which `google-github-actions/auth` sends unmodified. |

## Outputs

| Name | Description |
|------|-------------|
| `workload_identity_provider_name` | Full provider resource name → GitHub variable `WIF_PROVIDER`. Embeds the project **number**. |
| `workload_identity_pool_name` | Full pool resource name, for additional principalSet bindings. |
| `service_account_email` | → GitHub variable `BUILD_SERVICE_ACCOUNT` / `DEPLOY_SERVICE_ACCOUNT`. |
| `service_account_member` | `serviceAccount:<email>`, for IAM grants outside this module. |
| `service_account_id` | Fully qualified SA resource ID. |
| `attribute_condition` | The CEL condition tokens must satisfy — surfaced so the trust boundary is reviewable. |

## Operational notes

- **`WIF_PROVIDER` takes the project number, not the project ID.** The
  `workload_identity_provider_name` output already gives you the correct form.
  Substituting the ID produces `Unable to acquire impersonated credentials`,
  which reads like a permissions problem and is not one.
- **Deleted pools are soft-deleted for 30 days** and their IDs cannot be reused
  until purged (`gcloud iam workload-identity-pools undelete`). Renaming an
  identity is cheap; destroying and recreating one under the same name is not.
- The GCP side is only half of the boundary. The other half is GitHub's:
  the `prod` environment needs required reviewers and a deployment branch policy
  limited to `main`, so GitHub will not mint an `:environment:prod` token until
  a human approves. The approval gate sits *in front of* the credential.
