# Workload Identity Federation

This repo's pipelines deploy to Google Cloud Run without any stored credential — no
service account key, no long-lived token. Instead they use **workload identity
federation** (GitHub OIDC): GitHub mints a signed JWT asserting the identity of each
job, and Google validates it against a pre-configured trust rule before issuing a
short-lived access token.

There are **no repository secrets in this template at all.** Every value the
workflows read is a plaintext GitHub *variable*.

## Why not a service account key

A service account JSON key works but creates a standing credential, and each of its
properties is a liability:

- **It does not expire.** A key leaked today stays valid until someone remembers to
  rotate it.
- **It is bearer-only.** Whatever holds the file *is* the service account. The
  credential carries no claim about where it is being used from.
- **It spreads.** Fork PRs, logs, a compromised third-party action, a laptop backup.
- **Rotation is manual**, and therefore does not happen.

A job-scoped OIDC token eliminates all four: minted per job, valid for minutes, never
stored, and bound to a specific repository and GitHub environment by its claims.

## How it works

```mermaid
sequenceDiagram
    participant Job as Deploy Job
    participant GH as GitHub OIDC
    participant WIF as Workload Identity Pool
    participant SA as sa-deploy-&lt;env&gt;
    participant Run as Cloud Run

    Job->>GH: Request token (id-token: write)
    GH-->>Job: JWT — sub: repo:OWNER/REPO:environment:prod
    Job->>WIF: Present JWT
    WIF->>WIF: Verify signature + issuer
    WIF->>WIF: Evaluate attribute_condition
    WIF->>SA: Impersonate (roles/iam.workloadIdentityUser)
    SA-->>Job: Short-lived access token
    Job->>Run: gcloud run deploy / update-traffic
```

The two verification steps in the middle are the security boundary, and they are the
part worth understanding.

## The subject claim is the whole security model

GitHub puts a `sub` claim in the token describing the job that asked for it:

```
repo:avlon-technologies/template-gcp-cicd:environment:prod
```

**GitHub sets this, not the workflow.** A job cannot forge it, and — critically — a
job running in the `dev` environment gets `:environment:dev`, full stop. No workflow
input, shell variable, or permissions grant changes it.

That is why each environment gets its own service account, and why a bug (or a
malicious PR) in a dev-targeted workflow cannot reach production: the provider
refuses to mint the prod identity for a token that does not carry the prod subject.

Run the `show-oidc-token.yml` workflow to inspect a real token's claims. It requests
a throwaway audience, so what it prints cannot be exchanged for Google Cloud access
even before it expires.

## Provider configuration

```bash
PROJECT_ID="avlon-cicd-template"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
POOL="github"
REPO="avlon-technologies/template-gcp-cicd"

gcloud iam workload-identity-pools create "$POOL" \
  --project="$PROJECT_ID" --location="global" \
  --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="$POOL" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
  --attribute-condition="assertion.repository == '${REPO}'"
```

The `--attribute-condition` is **not optional**. Without it the provider accepts a
token from *any* GitHub repository on the internet — anyone could create a repo, run
a workflow, and exchange its token for your service account. Google lets you create
the provider without one, and this is the most common way the setup is got wrong.

## One service account per environment

The condition above scopes to the repository. The per-environment split comes from
the IAM binding on each service account:

```bash
for ENV in dev stg prod; do
  gcloud iam service-accounts create "sa-deploy-${ENV}" --project="$PROJECT_ID"

  gcloud iam service-accounts add-iam-policy-binding \
    "sa-deploy-${ENV}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project="$PROJECT_ID" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.environment/${ENV}"
done
```

The member is a `principalSet` keyed on `attribute.environment`, not a single
principal. It reads: *any token from this pool whose environment attribute is `dev`
may impersonate `sa-deploy-dev`* — and by omission, nothing else may.

### The build identity is bound differently — and it has to be

`_build.yml` pushes images, so it needs an identity too. But its job declares **no
`environment:`**, which means its token carries no environment claim and its subject
is ref-shaped rather than environment-shaped:

```
repo:avlon-technologies/template-gcp-cicd:ref:refs/heads/develop
```

An `attribute.environment` principalSet therefore cannot match it, and binding the
build account that way fails every image push with a permission error that reads as
though the roles are wrong. Bind it on the repository attribute instead:

```bash
gcloud iam service-accounts create "sa-build" --project="$PROJECT_ID"

gcloud iam service-accounts add-iam-policy-binding \
  "sa-build@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"
```

This is deliberately the weaker boundary: any job in this repository can obtain the
build identity, including one from a branch. That is acceptable precisely because the
build identity can only *write images to a registry* — it holds no deploy permission,
and pushing an image ships nothing. Deploying still requires an environment-scoped
token that only an approved, environment-declaring job can obtain.

Pair it with GitHub's side of the boundary: the `prod` environment must have required
reviewers and a deployment branch policy limited to `main`. GitHub will not mint a
token carrying `:environment:prod` until a reviewer approves, so the approval gate
sits *in front of* the credential rather than after it.

## Least privilege

Grant the deploy accounts only what a deploy needs:

| Role | Held by | Why |
| --- | --- | --- |
| `roles/run.developer` | deploy | Create revisions and shift traffic on Cloud Run |
| `roles/iam.serviceAccountUser` | deploy | Required to deploy a service that *runs as* a runtime service account |
| `roles/artifactregistry.reader` | deploy | Cloud Run pulls the image |
| `roles/artifactregistry.writer` | build | Pushing images — the deploy identities do not need this |

Scope these to the project (or the individual service), never the folder or
organization. Do not grant `roles/editor`: it is the path of least resistance, and it
makes every distinction above decorative.

Note that the **runtime** service account — what the container runs as — is a
different identity from the deploy account, and should hold only what the application
itself needs. `RUNTIME_SERVICE_ACCOUNT` sets it.

## GitHub variables

Repository-level, shared by all environments:

| Variable | Example |
| --- | --- |
| `WIF_PROVIDER` | `projects/123456789/locations/global/workloadIdentityPools/github/providers/github-provider` |
| `BUILD_SERVICE_ACCOUNT` | `sa-build@avlon-cicd-template.iam.gserviceaccount.com` |

Environment-level, set separately on `dev`, `stg`, and `prod`:

| Variable | Example |
| --- | --- |
| `DEPLOY_SERVICE_ACCOUNT` | `sa-deploy-prod@avlon-cicd-template.iam.gserviceaccount.com` |

`WIF_PROVIDER` takes the **project number**, not the project ID. Using the ID
produces a confusing permission error at exchange time rather than a not-found error.
If a first deploy fails there, check this before anything else.

## Failure modes

| Symptom | Cause |
| --- | --- |
| `Permission 'iam.serviceAccounts.getAccessToken' denied` | The `workloadIdentityUser` binding is missing, or its `principalSet` does not match the job's environment. |
| `Unable to acquire impersonated credentials` | `WIF_PROVIDER` is malformed — usually a project ID where the project number belongs. |
| `The audience in ID Token does not match` | The provider's issuer URI or allowed audiences were customized; the defaults work with `google-github-actions/auth` unmodified. |
| Token exchange succeeds, deploy returns 403 | Exchange and authorization are separate steps. The identity is right; its IAM roles are not. |
| Works on `develop`, fails on `main` | The prod service account binding or the prod environment's variables were never configured. Dev was; prod was not. |
| `startup_failure`, no logs at all | Not WIF. A caller granted fewer permissions than a called workflow requests — every caller needs `id-token: write`. |
