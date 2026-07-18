# Getting Started

End-to-end setup: from cloning the template to a verified first deployment. Budget 1–2 hours if the GCP infrastructure doesn't exist yet.

By the end you will have:

- The template running in your own GitHub repository
- An Artifact Registry repository holding the container images
- Cloud Run services for `dev`, `stg`, and `prod`
- Secretless (Workload Identity Federation) build and deploy identities
- GitHub environments, variables, and rulesets configured
- A first automatic deploy to dev

Related reading: [workload identity federation](workload-identity-federation.md) explains the auth model this guide sets up; [customization](customization.md) lists what to rename for your own project; the [operations manual](operations-manual.md) covers day-to-day releasing once you're set up.

> **This template stores zero repository secrets, by design.** Everything the workflows read is a plaintext GitHub *variable* — project IDs, service-account emails, the WIF provider resource name. None of them are credentials; they are names of things that GCP will only hand out tokens for if the OIDC token's subject matches. If you find yourself reaching for Settings → Secrets while following this guide, something has gone wrong. See [workload-identity-federation.md](workload-identity-federation.md).

## Prerequisites

| Requirement | Why |
|---|---|
| GCP project(s) with rights to create Artifact Registry repos, Cloud Run services, service accounts, workload identity pools, and IAM bindings | Build + deploy identities and the deploy targets |
| GitHub repository admin access | Environments, rulesets, and Actions settings are repo settings, not code |
| [gcloud CLI](https://cloud.google.com/sdk/docs/install), logged in (`gcloud auth login`) | Identity and infrastructure setup |
| [.NET 10 SDK](https://dotnet.microsoft.com/download) | Local build and test |
| [GitHub CLI](https://cli.github.com/) (`gh`) — optional | Used for dispatch commands throughout the docs; the Actions UI works too |

Enable the APIs before anything else — half of the confusing first-run failures are a disabled API surfacing as a permission error:

```sh
export PROJECT_ID="my-project"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project "$PROJECT_ID"
```

You can run everything in one project, or split registry and runtime across projects — the template keeps `AR_PROJECT_ID` separate from `GCP_PROJECT_ID` precisely so you can. If you split them, read the cross-project footgun at the end of Step 2.

## Step 1 — Get the code

Create your own repository from this template (GitHub → **Use this template**, or fork/clone and push). Then:

1. Make `develop` the **default branch** (Settings → General). The pipeline's gitflow model assumes it: features merge to `develop`, releases branch from it.
2. Ensure both `develop` and `main` branches exist and Actions are enabled.

Verify the app builds locally before touching any cloud configuration:

```sh
dotnet test
dotnet run --project Api      # http://localhost:5018/swagger
```

The container image is packaging-only — the `Dockerfile` copies `./publish` instead of building from source, so it cannot be built from a clean checkout. That is deliberate: the binary in the image is the exact binary the tests ran against, carrying the `InformationalVersion` that every post-deploy smoke test asserts. To build it locally:

```sh
dotnet publish Api/Api.csproj -c Release -o ./publish
docker build -t cicd-demo .
docker run --rm -p 8080:8080 cicd-demo   # http://localhost:8080/swagger
```

## Step 2 — Provision GCP resources

The pipeline needs one Artifact Registry repository (shared across all environments) and one Cloud Run service per environment. Provision them any way you prefer — Terraform, Console, or the commands below.

### Artifact Registry

One Docker repository holds every image the pipeline ever builds. It is shared, not per-environment: the whole point of build-once-promote-many is that the digest dev ran is the digest prod runs.

```sh
export AR_LOCATION="northamerica-northeast1"
export AR_PROJECT_ID="$PROJECT_ID"

gcloud artifacts repositories create cicd-demo \
  --repository-format=docker \
  --location="$AR_LOCATION" \
  --description="cicd-demo container images" \
  --project="$AR_PROJECT_ID"
```

> **Do not attach an aggressive cleanup policy to this repository.** Prod promotion locates the image to ship by its `sha-<commit>` tag; if a cleanup policy deleted it, `on-main.yml` fails with "the image has since been deleted from Artifact Registry" and there is no safe recovery other than re-running the release through staging. Unlike the Azure template's 90-day artifact retention, nothing here expires on its own — the only way to lose a promotable image is to delete it.

### Cloud Run services

The workflows deploy with `gcloud run deploy`, which creates the service if it doesn't exist. You can therefore let the first dev run create the dev service. Creating them up front is still worth it, because it lets you set ingress, scaling, and IAM before anything is exposed:

```sh
export GCP_REGION="northamerica-northeast1"

for ENV in dev stg prod; do
  gcloud run deploy "cicd-demo-$ENV" \
    --image="us-docker.pkg.dev/cloudrun/container/hello" \
    --region="$GCP_REGION" \
    --project="$PROJECT_ID" \
    --port=8080 \
    --allow-unauthenticated \
    --quiet
done
```

That placeholder image just reserves the name and URL; the first real deploy replaces it.

Two assumptions worth knowing before you deviate from the defaults:

- **Port 8080.** Both `_deploy.yml` (`--port 8080`) and the `Dockerfile` (`ASPNETCORE_HTTP_PORTS=8080`) pin it. Cloud Run's own default is also 8080, so all three agree — change one and you must change all three.
- **The smoke tests must be able to reach the service.** `_deploy.yml` asks Cloud Run for `status.url` rather than constructing a hostname (run.app URLs carry a generated suffix and are not derivable from the service name), then curls `/v1/hello` and `/openapi/v1.json` from a GitHub-hosted runner. A service with `--ingress=internal` is unreachable from there. Two supported ways out: set the environment's `GATEWAY_URL` variable to a load-balancer hostname the runner *can* reach, or point the deploy job at a self-hosted runner via the `runner` input. Note the deploy itself never needs network position — the Cloud Run admin API is IAM-gated, not IP-gated. Only the smoke test needs to reach the app.

**Cross-project footgun:** if `AR_PROJECT_ID` differs from `GCP_PROJECT_ID`, the Cloud Run *service agent* of the runtime project — not the deploy service account — is what pulls the image, and it needs read access on the registry:

```sh
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
gcloud artifacts repositories add-iam-policy-binding cicd-demo \
  --location="$AR_LOCATION" --project="$AR_PROJECT_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@serverless-robot-prod.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

Skipping this produces a deploy that fails at revision creation with an image-pull error, which reads like a bad image reference rather than an IAM gap.

## Step 3 — Create the identities

There is no service-account key anywhere in this setup. GitHub mints a short-lived OIDC token for each job; GCP's Security Token Service exchanges it for an access token, but only if the token's `sub` claim matches a binding you created. The full rationale and mechanism is in [workload-identity-federation.md](workload-identity-federation.md).

Four identities in total: one **build** service account (pushes images and reads them back during promotion) and one **deploy** service account per environment.

### 3a — Workload identity pool and provider

```sh
export OWNER_REPO="OWNER/REPO"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

gcloud iam workload-identity-pools create github \
  --location="global" --display-name="GitHub Actions" --project="$PROJECT_ID"

gcloud iam workload-identity-pools providers create-oidc github \
  --location="global" \
  --workload-identity-pool="github" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
  --attribute-condition="assertion.repository == '${OWNER_REPO}'" \
  --project="$PROJECT_ID"

export WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github"
echo "$WIF_PROVIDER"
```

> **The `--attribute-condition` is not optional.** A provider created without one will exchange a token from *any* GitHub repository on the internet for a token in your project — the identity of the caller is only as narrow as the condition makes it. The repository-level condition above is the outer boundary; the per-environment boundary comes from the subject-scoped bindings in 3c.

Note the condition scopes on `assertion.repository`, not on `assertion.sub` alone. The build job in `_build.yml` runs **without** a GitHub `environment:` declaration, so its token's `sub` is `repo:OWNER/REPO:ref:refs/heads/develop` — a provider condition that demanded `repo:OWNER/REPO:environment:<env>` would lock the build out and every image push would fail at auth. Environment scoping belongs on the deploy service accounts, where the tokens actually carry an environment claim.

### 3b — Build service account

Pushes to Artifact Registry, and reads image tags back during release/prod promotion (`gcloud artifacts docker images list`). `roles/artifactregistry.writer` covers both, scoped to the one repository:

```sh
gcloud iam service-accounts create cicd-demo-build \
  --display-name="cicd-demo GitHub build" --project="$PROJECT_ID"

export BUILD_SA="cicd-demo-build@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud artifacts repositories add-iam-policy-binding cicd-demo \
  --location="$AR_LOCATION" --project="$AR_PROJECT_ID" \
  --member="serviceAccount:${BUILD_SA}" \
  --role="roles/artifactregistry.writer"

# Any job in this repository may impersonate the build SA — it can push
# images, and nothing else. Deploy rights live on separate accounts.
gcloud iam service-accounts add-iam-policy-binding "$BUILD_SA" \
  --project="$PROJECT_ID" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${OWNER_REPO}" \
  --role="roles/iam.workloadIdentityUser"
```

### 3c — Deploy service accounts, one per environment

Each is trusted for exactly one GitHub environment. Run this three times, for `dev`, `stg`, and `prod`:

```sh
ENV=dev   # repeat for stg and prod

gcloud iam service-accounts create "cicd-demo-deploy-$ENV" \
  --display-name="cicd-demo GitHub deploy ($ENV)" --project="$PROJECT_ID"

DEPLOY_SA="cicd-demo-deploy-${ENV}@${PROJECT_ID}.iam.gserviceaccount.com"

# Create revisions, shift traffic, manage tags on Cloud Run.
gcloud run services add-iam-policy-binding "cicd-demo-$ENV" \
  --region="$GCP_REGION" --project="$PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/run.developer"

# Read the image it is asked to deploy.
gcloud artifacts repositories add-iam-policy-binding cicd-demo \
  --location="$AR_LOCATION" --project="$AR_PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/artifactregistry.reader"

# THE BINDING THAT MATTERS: only a job running in the GitHub environment
# named $ENV, in this repository, can become this service account.
gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" \
  --project="$PROJECT_ID" \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/subject/repo:${OWNER_REPO}:environment:${ENV}" \
  --role="roles/iam.workloadIdentityUser"
```

> The subject string must exactly match `repo:OWNER/REPO:environment:<env>` — this is the security boundary. A token from a fork, another repository, or a job that didn't declare `environment: prod` is rejected by STS before any GCP API is touched. Owner and repo are **case-sensitive** here; GitHub's URLs are not, which makes a capitalisation mismatch a genuinely nasty first-run failure ("unable to impersonate", with nothing in the run pointing at the cause).

### 3d — Runtime service account (optional)

`RUNTIME_SERVICE_ACCOUNT` sets the identity the container itself runs as. Leave the variable unset and Cloud Run uses the project's default compute service account — fine for the demo app, not fine for anything that touches your data. If you do set it, the deploy account needs permission to *assign* it, which is `roles/iam.serviceAccountUser` **on the runtime account** (not on the project):

```sh
gcloud iam service-accounts create "cicd-demo-runtime-$ENV" \
  --display-name="cicd-demo runtime ($ENV)" --project="$PROJECT_ID"

RUNTIME_SA="cicd-demo-runtime-${ENV}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/iam.serviceAccountUser"
```

Omitting this binding fails the deploy with a permission error naming the *runtime* account, which reads like a problem with the account being assigned rather than with the account doing the assigning.

## Step 4 — Configure GitHub

### Repository variables

Settings → Secrets and variables → Actions → **Variables** (repository level). These are the same for every environment, so they live once at the repo level:

| Variable | Value |
|---|---|
| `WIF_PROVIDER` | Full provider resource name from Step 3a: `projects/<number>/locations/global/workloadIdentityPools/github/providers/github` |
| `BUILD_SERVICE_ACCOUNT` | Build SA email (Step 3b) |
| `AR_LOCATION` | Artifact Registry location, e.g. `northamerica-northeast1` — the workflows derive the registry host as `<AR_LOCATION>-docker.pkg.dev` |
| `AR_PROJECT_ID` | Project holding the Artifact Registry repository |
| `AR_REPOSITORY` | Repository name, e.g. `cicd-demo` |
| `IMAGE_NAME` | Image name within the repository, e.g. `cicd-demo` |

All six are variables, **not secrets**. A project number and a service-account email grant nothing on their own; the grant is the IAM binding, and it is conditioned on a token GitHub only issues to this repository. Putting these in secrets buys no security and costs you readable logs.

### Environments

Settings → Environments → create `dev`, `stg`, and `prod`. In each, add **environment variables** (again, not secrets):

| Variable | Value |
|---|---|
| `DEPLOY_SERVICE_ACCOUNT` | That environment's deploy SA email (Step 3c) |
| `GCP_PROJECT_ID` | Project hosting that environment's Cloud Run service |
| `GCP_REGION` | Cloud Run region, e.g. `northamerica-northeast1` |
| `SERVICE_NAME` | Cloud Run service name, e.g. `cicd-demo-dev` |
| `RUNTIME_SERVICE_ACCOUNT` | *Optional* — runtime identity (Step 3d). Unset means Cloud Run's default compute SA |
| `GATEWAY_URL` | *Optional* — smoke-test the service through this hostname instead of its run.app URL. Set it when the service uses internal ingress behind a load balancer |

On the **`prod`** environment specifically, set both protections:

- **Required reviewers** — a human approval gate before production deploys. (The back-merge job runs in parallel with the deploy, so `develop` gets release commits back even while prod waits for approval.)
- **Deployment branch policy → selected branches → `main`.** This is the enforcement of record for "prod only ships from main." `on-main.yml` has its own guard that rejects dispatches from other refs, but that guard only exists on refs that contain it — the environment policy is what cannot be bypassed by pushing a modified workflow to a branch.

### Actions settings

Settings → Actions → General:

- **Workflow permissions:** *Read repository contents and packages permissions* (read-only default token — jobs elevate explicitly). Note the consequence: a caller workflow must grant `id-token: write` for every job that authenticates to GCP, and `contents: write` for deploys that tag. A called workflow cannot exceed its caller's grant, and a missing grant fails as an instant `startup_failure` with **no logs at all** — the single most confusing first-run failure in this template.
- **Allow GitHub Actions to create and approve pull requests:** **enabled.** The back-merge and backport jobs in `on-main.yml` open PRs with the built-in token. With this disabled, they fail loudly after a successful prod deploy — the release ships, and `develop` silently falls behind.

### Rulesets

Settings → Rules → Rulesets. These enforce the quality gates the pipeline assumes:

| Ruleset target | Rules |
|---|---|
| `develop` | Require a pull request; require the **build / Build & Test** status check |
| `main` | Require a pull request; require **build / Build & Test** and **Guard main source branch** checks; **allow merge commits only** (disable squash and rebase) |

Merge-commit-only on `main` is load-bearing, and in two distinct ways:

1. `on-main.yml` reads the release version from the default merge commit subject (`Merge pull request #N from …/release/X.Y.Z`). A squashed or reworded merge yields no version, and the run fails by design rather than shipping an untraceable build.
2. Promotion resolves the image to ship by walking to the merge commit's **second parent** — the release branch head — and looking up the image tagged `sha-<that commit>`. A squash merge has no second parent, so there is nothing to look up.

> The required checks only appear in the ruleset picker after they have run at least once — open a trivial PR first if GitHub won't autocomplete them.

## Step 5 — First deploy to dev

Push (or merge a PR) to `develop`:

```sh
git checkout develop
git commit --allow-empty -m "Trigger first dev deploy"
git push
```

Watch Actions → **CI/CD — Develop → DEV**. The run should: build and test, push an image to Artifact Registry (the step summary prints the label, digest, and full `IMAGE@sha256:...` reference), deploy that digest to your dev Cloud Run service, then pass the smoke test (`GET /v1/hello` returns `Hello World!` and `/openapi/v1.json` reports the build label, `YYYYMMDD.<run_number>`).

Verify: open the URL from the run summary and append `/swagger` — the page shows the deployed build label, linked commit, and environment name.

If the run fails, the [troubleshooting table](operations-manual.md#troubleshooting) maps the common failure messages to causes. The most frequent first-run issues are a missing `permissions: id-token: write` grant (instant `startup_failure`, no logs), a WIF binding whose subject doesn't exactly match `repo:OWNER/REPO:environment:dev`, and a disabled `iamcredentials.googleapis.com`.

## Step 6 — First release to stg and prod

Once dev works, exercise the full promotion path (full detail: [operations manual](operations-manual.md)):

```sh
# Cut a release branch
git checkout develop && git pull
git checkout -b release/0.1.0
git push -u origin release/0.1.0

# Dispatch a release candidate to staging
gh workflow run on-release.yml --ref release/0.1.0
```

The push already built and pushed an image tagged `sha-<commit>`; the dispatch finds it by that tag and reuses it rather than rebuilding — labels are commit-derived, so the push build already carries the label the dispatch resolves. It deploys that digest to stg, smoke-tests it, and tags the commit `build/stg/0.1.0-build.<height>`. Then promote:

```sh
gh pr create --base main --head release/0.1.0 --title "Release 0.1.0"
gh pr merge --merge      # merge commit — do NOT squash
```

The prod run resolves the release branch head from the merge commit's second parent, **requires a `build/stg/*` tag on it** (an image existing is not proof staging tested it — images are pushed at build time, before any deploy), looks up that commit's image digest, and deploys it as a **gated rollout**: the revision goes up with `--no-traffic` under a `cand-<run_id>` tag, gets smoke-tested on its own tagged URL while production keeps serving the old revision, and only then takes 100% of traffic. A failure before the shift leaves production untouched; a failure after it returns traffic to the revision that was serving when the run started. Then it tags `build/prod/0.1.0`, creates GitHub Release `v0.1.0`, and opens a back-merge PR to `develop`.

Rollback is the same machinery in reverse — dispatch `on-main.yml` from `main` with a released version, and it locates that version's digest and rolls it out through the same gate.

## Next steps

- Adapt the template to your own application: [customization.md](customization.md)
- Learn the day-to-day flows (hotfixes, rollbacks, redeploys): [operations manual](operations-manual.md)
- Understand the design: [ARCHITECTURE.md](ARCHITECTURE.md)
- Inspect what GitHub's OIDC tokens actually contain: run the **Show OIDC Token Claims** workflow (Actions → Show OIDC Token Claims). Worth doing before debugging any WIF failure — it shows you the exact `sub` string your bindings must match.
