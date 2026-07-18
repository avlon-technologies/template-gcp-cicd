# Module: `artifact-registry`

Manages the **one Docker repository shared by all three environments**, plus the
push and pull IAM on it.

The opinionated decisions it bakes in:

- **One registry, not one per environment.** Build-once-promote-many means the
  image staging verified is byte-for-byte the image production runs, and
  promotion is carried by digest. Per-environment registries force either a
  rebuild (a different artifact every time — different base layers, different
  dependency resolution) or a cross-registry copy that teams shortcut.
  Environment separation is an *authorization* problem, solved by the IAM
  below, not a reason to fork the artifact store.
- **Immutable tags.** A push to an existing tag fails at the registry. This is
  stronger than detecting a moved tag after the fact — the rule enforces itself.
- **Untagged versions expire after 30 days.** Digest-only leftovers from
  superseded or interrupted builds are storage with no consumer. Digests
  referenced by a tag are unaffected.
- **`prevent_destroy`.** The registry outlives every service pulling from it,
  and destroying it takes the rollback history of all three environments with
  it.
- **Push and pull are different principals.** Only the build identity writes;
  deploy identities never push. Pulls are performed by Cloud Run's per-project
  service agent, which is why that agent — not just the runtime service
  account — appears in `reader_members`.

## The `create_repository` split

The registry is shared but Terraform state is not: each environment root has its
own state, and exactly one of them can own the resource. So every root calls
this module, and:

- the root with `manage_shared_resources = true` (dev, by convention) passes
  `create_repository = true` and creates it;
- the others pass `false` and still attach their own environment's pull access.

IAM here addresses the repository by **coordinates** (`project` / `location` /
`repository`) rather than by resource attribute, so the non-owning roots take no
dependency on the owning root's state — no `terraform_remote_state`, no shared
secrets, no apply-order coupling beyond "create it before you grant on it".

## Usage

```hcl
module "artifact_registry" {
  source = "../../modules/artifact-registry"

  create_repository = var.manage_shared_resources

  project_id    = "avlon-cicd-template"
  location      = "northamerica-northeast1"
  repository_id = "containers"

  writer_members = ["serviceAccount:sa-build@avlon-cicd-template.iam.gserviceaccount.com"]
  reader_members = [
    "serviceAccount:service-123456789@serverless-robot-prod.iam.gserviceaccount.com",
    "serviceAccount:sa-app-prod@avlon-cicd-template.iam.gserviceaccount.com",
  ]
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `project_id` | `string` | — | Project hosting the repository. |
| `location` | `string` | — | Region; forms the `<location>-docker.pkg.dev` host. |
| `repository_id` | `string` | — | Repository name, e.g. `containers`. |
| `create_repository` | `bool` | `true` | Whether this root owns the resource or only attaches IAM. |
| `immutable_tags` | `bool` | `true` | Reject pushes that would move an existing tag. |
| `untagged_retention_days` | `number` | `30` | Delete untagged versions older than this. `null` disables. |
| `cleanup_policy_dry_run` | `bool` | `false` | Log what cleanup would delete without deleting. |
| `writer_members` | `list(string)` | `[]` | Members granted `roles/artifactregistry.writer`. |
| `reader_members` | `list(string)` | `[]` | Members granted `roles/artifactregistry.reader`. |
| `description` | `string` | (see variables.tf) | Repository description. |
| `labels` | `map(string)` | `{}` | Repository labels. |

## Outputs

| Name | Description |
|------|-------------|
| `repository_url` | `<location>-docker.pkg.dev/<project>/<repository>` — the build workflow appends `/<IMAGE_NAME>`. |
| `repository_id` | → GitHub variable `AR_REPOSITORY`. |
| `location` | → GitHub variable `AR_LOCATION`. |
| `project_id` | → GitHub variable `AR_PROJECT_ID`. |
