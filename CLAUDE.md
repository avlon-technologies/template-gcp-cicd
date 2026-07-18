# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A CI/CD pipeline demo: a minimal .NET 10 web API (`cicd-demo.sln` — `Api` is a minimal-API project with a hello-world endpoint at `/`; `Api.Test` holds xUnit integration tests using `WebApplicationFactory`) deployed to **Google Cloud Run** via GitHub Actions. `Api/Program.cs` ends with `public partial class Program { }` to make the entry point visible to the test project — keep it when editing.

**The pipeline is the product.** The app is deliberately trivial; changes that make the app more interesting at the cost of making the pipeline harder to read are going the wrong way.

## Build and test commands (as run by CI)

```sh
dotnet restore cicd-demo.sln
dotnet build cicd-demo.sln --configuration Release --no-restore
dotnet test Api.Test/Api.Test.csproj --configuration Release --no-build --logger trx
dotnet publish Api/Api.csproj --configuration Release --no-build --output ./publish
docker build -t cicd-demo .          # requires ./publish to exist — see below
```

Run locally: `dotnet run --project Api`

**The `Dockerfile` does not build the application.** It copies `./publish`, which CI has already built, tested, and stamped with the build label. This is load-bearing: the smoke test after every deploy asserts that the running app reports the exact label CI stamped, so an image that rebuilt from source would be a different binary than the one the tests passed against. If you change the Dockerfile, preserve that property.

## Workflow architecture

Two reusable workflows (prefixed `_`) are composed by branch-triggered entry workflows:

- `_build.yml` — build, test, publish, and (when `push-image: true`) build and push a container image to Artifact Registry. Accepts an optional `version` input; otherwise the build label defaults to `YYYYMMDD.<run_number>`. The label is stamped into `InformationalVersion` at the *build* step (publish runs `--no-build`) and surfaces in Swagger. Outputs `build-label`, `image-digest`, and `image-ref`. The image is tagged `sha-<commit>` and `<label>`, but **the digest is the promotable identity** — tags are mutable, digests are not. Requires `checks: write` and `pull-requests: write` on the caller to publish test results as a PR check, and `id-token: write` for Workload Identity Federation.
- `_deploy.yml` — authenticates via WIF, deploys the image **by digest** to Cloud Run, smoke-tests `/v1/hello` *and* asserts `/openapi/v1.json` reports the deployed `build-label` (a pre-release of it also passes — promoted candidate binaries keep their stamp), prints the URL to the run summary, and — when the caller sets `tag-deployment: true` (stg and prod callers do; dev doesn't) — tags `build/<environment>/<build-label>` on the commit the image was built from (`source-sha` input, defaults to the run's HEAD). stg tags double as the prod promotion gate's proof of a green staging deploy. Tags are immutable: an existing tag at a different commit fails the deploy (same commit is a no-op).

  With `gated-rollout: true` (prod only) it deploys the revision with `--no-traffic --tag cand-<run_id>`, smoke-tests that tagged revision's own URL, then shifts 100% of traffic to it. A failed *post-shift* smoke test returns traffic to the revision recorded before the deploy; a failure *before* the shift never moves traffic at all. The candidate tag is always removed afterward — Cloud Run caps tags per service, and leaking them breaks deploys much later in a way that is hard to diagnose.

  Requires a GitHub environment (`dev` | `stg` | `prod`) — service name, region, project, and deploy service account come from that environment's variables, scoped by the job's `environment:` declaration, so entry workflows carry no per-env config. Callers must grant `id-token: write` and `contents: write`.
- `on-pr.yml` — builds/tests PRs to `develop`/`main` with `push-image` left false; the check is required by rulesets, which also enforce PR-only merges (merge-commit-only on `main`).

Pipeline behavior also depends on repo settings outside these files: rulesets, workflow permissions (default token read-only; "Actions can create PRs" enabled for the back-merge step), and the GitHub variables listed below — see `docs/getting-started.md`.

Two gotchas worth remembering:

- Jobs downstream of the promotion path's skipped `build` job need explicit `!failure() && !cancelled()` conditions (implicit `success()` fails on skipped ancestors).
- A called workflow's `permissions` block is evaluated at job start, before any step condition, and cannot exceed its caller's grant. `on-pr.yml` therefore grants `id-token: write` even though it never pushes an image — without it the run dies with `startup_failure` and no logs.

Entry workflows carry `concurrency` groups so deploys to the same environment serialize (`deploy-dev` / `deploy-stg` / `deploy-prod`; the three stg pipelines share a group on dispatch, group per-branch on push); `on-pr.yml` cancels superseded PR builds. All actions are pinned to commit SHAs with a `# vX.Y.Z` comment — Dependabot keeps the pins current; when bumping manually, update the SHA and the comment together.

Branch → environment mapping:

| Entry workflow | Trigger branches | Environment |
|---|---|---|
| `on-develop.yml` | `develop` | dev |
| `on-release.yml` | `release/**`, `milestone/**` | stg |
| `on-hotfix.yml` | `hotfix/**` | stg |
| `on-support.yml` | `support/**` | stg |
| `on-main.yml` | `main` | prod (gated rollout) |

Release specifics (`on-release.yml`): pushes only build (deploy is gated on `workflow_dispatch`; no dispatch inputs). Labels are **commit-derived** — a pure function of branch name + commit height (`git rev-list --count HEAD`, hence the prepare job's `fetch-depth: 0` checkout): `release/X.Y.Z` at height N builds `X.Y.Z-build.N`, `milestone/<name>` builds `ms-<name>.N`. Because every build of a commit yields the same label, *push* builds are already promotable: they push an image tagged `sha-<commit>`, and a dispatch **finds that image by tag and skips the build entirely** (no image rebuilds; a recovered label that disagrees with the derived one — possible only if the derivation logic changed between push and dispatch — deploys under the *stamped* label, since the version is compiled in and re-labeling would ship a binary that reports the wrong version). When the release merges to main, `on-main.yml` **promotes that exact digest** (build job skipped) — a missing image, or a release head with no `build/stg/*` tag (built but never green on staging), **fails the prod run** (no silent rebuild of untested source). Labels are charset-restricted (letters/digits/`.`/`-`) because they become image tags and git tags.

Note the Cloud Run tag on a candidate revision is derived from the **run id**, not the build label: Cloud Run tags must match `[a-z0-9-]{1,63}` and build labels legitimately contain dots.

`on-main.yml` accepts an optional `version` dispatch input for rollback/redeploy: supply a previously released version (e.g. `1.5.0`) to promote that release's stg-tested image to prod via the same gated path. It resolves the `v<version>` tag, walks to the merge commit's **second parent** (the release branch head), and looks up that commit's image. Unlike an artifact-based pipeline there is **no retention window** — digests do not expire, so rollback is bounded only by registry cleanup policy. The `release` and `backmerge` jobs are skipped on dispatch (push-only). Dispatching without a version redeploys the current HEAD of `main`. The `backmerge` job runs **parallel to deploy** (needs only `prepare`) so develop gets the merged commits back even if the prod deploy fails or waits on an environment approval: release sources get a branch back-merge PR; hotfix/support sources get a cherry-pick (`-m 1` of the merge commit) onto a `backport/<version>` branch instead, because those branches are cut from `main` or old version tags — their history is foreign to develop.

`on-develop.yml` accepts an optional `build-label` dispatch input: supply a previous dev build label to rebuild HEAD stamped with that label and redeploy to dev. Dev deploys are not tagged — the label is validated against the workflow's own run history.

Hotfix/support specifics (`on-hotfix.yml`, `on-support.yml`): same dispatch-gated pattern as releases, via the shared `_hotfix-support.yml`, with labels `X.Y.Z-hotfix.<height>` / `X.Y.Z-patch.<height>`. Merging either to `main` auto-detects the version from the merge commit subject (a push whose subject doesn't parse **fails the run** rather than falling back to an untested date-label rebuild). Cut `hotfix/X.Y.Z` and `support/X.Y.Z` branches from `main` (or a version tag), not `develop`.

## Infrastructure

Terraform lives in [`infra/`](infra/) in this repo: `infra/modules/` (artifact-registry, github-oidc, cloud-run) and `infra/environments/{dev,stg,prod}/`, following `../engineering-standards/terraform/`.

**Terraform owns the Cloud Run service's existence and shape; the pipeline owns which image is running.** The service resource carries `lifecycle { ignore_changes = [...] }` on the container image and traffic so that `terraform apply` does not revert a deployed revision. If you edit that module, do not remove those ignores without understanding what they prevent.

Artifact Registry is **shared across environments** — build-once-promote-many means one registry, with the same digest promoted to different services.

## Deploy identity

CI authenticates to Google Cloud via OIDC Workload Identity Federation — there are **no repository secrets at all**, and no service account keys. See `docs/workload-identity-federation.md` for the full model.

The essential shape: the pool provider is scoped to this repository by an attribute condition, and each environment's deploy service account is bound to `attribute.environment/<env>` so that a job's GitHub-issued `sub` claim determines which identity it can obtain. The **build** service account is bound on `attribute.repository` instead, because `_build.yml` declares no `environment:` and its token therefore carries no environment claim — this is why the build identity holds only `artifactregistry.writer` and no deploy permission.

Repository variables: `WIF_PROVIDER` (uses the project **number**), `BUILD_SERVICE_ACCOUNT`, `AR_LOCATION`, `AR_PROJECT_ID`, `AR_REPOSITORY`, `IMAGE_NAME`.

Environment variables (per `dev`/`stg`/`prod`): `DEPLOY_SERVICE_ACCOUNT`, `GCP_PROJECT_ID`, `GCP_REGION`, `SERVICE_NAME`, optionally `RUNTIME_SERVICE_ACCOUNT` and `GATEWAY_URL`.

Deploys fail until the Terraform has been applied for the target environment.
