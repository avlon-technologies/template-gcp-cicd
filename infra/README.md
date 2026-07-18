# Infrastructure

Terraform for the Google Cloud side of this template: the container registry the
pipeline pushes to, the federated identities it authenticates as, and the Cloud
Run services it deploys to.

There are **no credentials anywhere in this directory** — not in `.tf` files,
not in `terraform.tfvars`, not in any GitHub variable these outputs feed. The
pipeline authenticates by Workload Identity Federation, so no service account
key ever exists to be committed, leaked, or rotated.

## Layout

```text
infra/
├── modules/
│   ├── github-oidc/          # WIF pool + provider + CI service account + IAM
│   ├── cloud-run/            # the service, its runtime identity, invoker IAM
│   └── artifact-registry/    # the ONE shared Docker repository + push/pull IAM
└── environments/
    ├── dev/                  # state: avlon-tfstate-dev  / prefix template-gcp-cicd
    ├── stg/                  # state: avlon-tfstate-stg  / prefix template-gcp-cicd
    └── prod/                 # state: avlon-tfstate-prod / prefix template-gcp-cicd
```

Each environment is an independent root: its own state, its own IAM, its own
apply. **The three roots are structurally identical** — same `main.tf`,
`variables.tf`, `outputs.tf`, `providers.tf` — and differ only in `backend.tf`
(which state) and `terraform.tfvars` (which values). Drift between them is a
bug, not a style question; a PR touching one should touch all three or say why
not.

Terraform workspaces are not used. The directory you are in *is* the
environment.

## Bootstrap order

Three orderings matter, and each one bites in a different way if ignored.

### 1. State buckets exist before anything (platform prerequisite)

`backend.tf` points at `avlon-tfstate-{dev,stg,prod}`, prefix
`template-gcp-cicd`. **This configuration does not create those buckets.** They
are platform infrastructure — versioning, soft delete, dual-region, bucket-scoped
IAM — owned by the backend-bootstrap stack.

If `terraform init` fails with a 404 or 403 on the bucket, the bucket or your
grant on it does not exist yet. That is a prerequisite to obtain, not something
to work around by falling back to local state.

### 2. Dev before stg and prod (shared resources)

The Artifact Registry repository and the build identity are **shared by all
three environments**, because build-once-promote-many requires one artifact in
one place. Only one Terraform state can own a resource, so the dev root owns
them (`manage_shared_resources = true` in `dev/terraform.tfvars`); stg and prod
set it `false` and only attach their own pull access.

So:

```bash
cd infra/environments/dev  && terraform init && terraform apply   # registry + build identity + dev service
cd ../stg                  && terraform init && terraform apply
cd ../prod                 && terraform init && terraform apply
```

Applying stg or prod first fails on IAM bindings against a repository that does
not exist yet.

### 3. The Cloud Run service exists before the first pipeline deploy

This is the chicken-and-egg worth being explicit about.

`_deploy.yml` runs `gcloud run deploy`, which will happily *create* a service
that does not exist. But a service created that way is created with **gcloud's
defaults** — not this configuration's ingress, scaling, runtime service account,
or invoker IAM — and Terraform would then plan to reshape a resource it does not
have in state. The first `terraform apply` after that is a mess.

So Terraform creates the service first, using
`bootstrap_image = us-docker.pkg.dev/cloudrun/container/hello`, a public image
that exists before your registry has ever been pushed to. You get a real,
running, correctly-shaped service on day one, serving Google's hello container.
The first pipeline deploy then replaces the image with your build.

**Terraform never takes the image back**, because the `cloud-run` module ignores
changes to it — see [the ownership split](modules/cloud-run/README.md#the-ownership-split-read-this-first).
Terraform owns that the service exists and what shape it has; the pipeline owns
which image is running and where traffic goes. Get this wrong and a routine
infrastructure apply silently rolls production back to the placeholder image.

## Wiring the outputs into GitHub

Every key in the two output maps is a GitHub variable read by
`.github/workflows/` under exactly that name. There are no secrets — all of
these are plaintext variables.

### Repository-level variables

Read from the **dev** root (the one that manages shared resources; in the others
the build entries are `null`).

| Variable | Source | Consumed by |
|---|---|---|
| `WIF_PROVIDER` | build identity's provider | `_build.yml` — the build job declares no environment, so it resolves the repository-level value |
| `BUILD_SERVICE_ACCOUNT` | `sa-build@…` | `_build.yml` |
| `AR_LOCATION` | registry region | `_build.yml` (`gcloud auth configure-docker`, image path) |
| `AR_PROJECT_ID` | registry project | `_build.yml` |
| `AR_REPOSITORY` | `containers` | `_build.yml` |
| `IMAGE_NAME` | `cicd-demo/cicd-demo-api` | `_build.yml` |

```bash
cd infra/environments/dev
terraform output -json github_repository_variables |
  jq -r 'to_entries[] | select(.value != null) | "\(.key)=\(.value)"' |
  while IFS='=' read -r k v; do gh variable set "$k" --body "$v"; done
```

### Environment-level variables

Read from each root, set on the matching GitHub environment (`dev`, `stg`,
`prod`).

| Variable | Source | Consumed by |
|---|---|---|
| `WIF_PROVIDER` | that environment's deploy provider | `_deploy.yml` |
| `DEPLOY_SERVICE_ACCOUNT` | `sa-deploy-<env>@…` | `_deploy.yml` |
| `RUNTIME_SERVICE_ACCOUNT` | `sa-app-<env>@…` | `_deploy.yml` (`--service-account`) |
| `GCP_PROJECT_ID` | project | `_deploy.yml` |
| `GCP_REGION` | region | `_deploy.yml` |
| `SERVICE_NAME` | `run-cicd-demo-api-<env>-nane1` | `_deploy.yml` |

```bash
for ENV in dev stg prod; do
  cd "infra/environments/$ENV"
  terraform output -json github_environment_variables |
    jq -r 'to_entries[] | "\(.key)=\(.value)"' |
    while IFS='=' read -r k v; do gh variable set "$k" --env "$ENV" --body "$v"; done
  cd -
done
```

### Why `WIF_PROVIDER` appears at both levels

This is the one piece of the wiring that surprises people, and it is
deliberate. GitHub resolves `vars.X` to the environment-level value when the job
declares an `environment:`, falling back to the repository-level value when it
does not.

- The **build** job declares no environment. Its token carries no `environment`
  claim, so it *cannot* be admitted by an environment-pinned provider. It gets
  the repository-level `WIF_PROVIDER` — the build provider, which pins the
  repository only.
- Every **deploy** job declares `environment: dev|stg|prod`. Its
  environment-level `WIF_PROVIDER` shadows the repository-level one and points
  at that environment's provider, which requires
  `assertion.repository == "…" && assertion.environment == "<env>"`.

The result: one variable name, two trust levels, resolved automatically by which
job is asking.

## The trust boundary

Two asymmetric identities, on purpose:

**Build — repository-scoped, deliberately weaker.** Any job in this repository,
including one on a branch, can obtain it. Acceptable because it can do exactly
one thing: write images to the registry. Pushing an image ships nothing. It
holds no project roles at all — its `artifactregistry.writer` grant is scoped to
the repository, not the project.

**Deploy — environment-scoped, the real boundary.** The provider requires both
the repository and the environment claim. GitHub sets `assertion.environment`
from the job's `environment:` declaration; no workflow input, shell variable, or
permissions grant can forge it. A bug or a malicious PR in a dev-targeted
workflow cannot reach production, because the prod provider will not admit a
token that does not carry the prod claim.

GitHub owns the other half: the `prod` environment must have required reviewers
and a deployment branch policy limited to `main`. GitHub will not mint an
`:environment:prod` token until a reviewer approves — so the approval gate sits
*in front of* the credential rather than after it.

Verify a boundary without leaving the terminal:

```bash
terraform output deploy_identity_attribute_condition
# "assertion.repository == \"Grv91/template-gcp-cicd\" && assertion.environment == \"prod\""
```

## Adapting this to your project

| Change | Where |
|---|---|
| GitHub repository | `github_repository` default in `environments/*/variables.tf` (all three — it must not differ) |
| GCP project(s) | `project_id` in each `terraform.tfvars`. Splitting into per-environment projects is a tfvars change only |
| Region | `region` in each `terraform.tfvars`; add the region and its short code to `locals.region_codes` in `modules/cloud-run/main.tf` |
| Workload / component names | `workload` and `component` defaults in `environments/*/variables.tf`. **The component suffix cannot be changed later without recreating the service** — its name is baked into the run.app hostname |
| Registry coordinates | `artifact_registry` default in `environments/*/variables.tf` (all three — promotion breaks if they diverge) |
| State buckets | `backend.tf` in each root |
| Locking prod down | `prod/terraform.tfvars`: set `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"` and `allow_public_access = false`, then give the prod GitHub environment a `GATEWAY_URL` variable — `_deploy.yml` already prefers it over the run.app hostname when set |

The template runs all three environments in one project (`avlon-cicd-template`),
which is why the deploy service accounts are named `sa-deploy-<env>` rather than
just `sa-deploy`. Real workloads use one project per environment, where the
project ID already encodes the environment and the shorter name suffices.

## Checks

```bash
terraform fmt -recursive        # from infra/
tflint --recursive
# per root:
terraform init -backend=false && terraform validate
terraform plan                  # the real review artifact
```

`.terraform.lock.hcl` is committed in every root — constraint ranges say what
*could* run, the lock file says what *does*. The committed locks were generated
on Windows; before CI runs these roots, regenerate them for every platform in
use so the file stops churning between laptops and Linux runners:

```bash
terraform providers lock \
  -platform=linux_amd64 -platform=windows_amd64 -platform=darwin_arm64
```
 `*.tfstate` and `.terraform/` are
git-ignored: state is a plaintext secret store, and a state file that reaches a
commit is an incident.
