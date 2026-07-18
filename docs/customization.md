# Customizing the Template

Everything you need to rename, reconfigure, or rethink when adapting this template to your own project. Work top to bottom: application, build workflow, packaging, Google Cloud, GitHub, docs.

The pipeline has exactly two hard contracts with the application — [the smoke-test contract](#3-the-smoke-test-contract) and [the packaging contract](#4-the-packaging-contract-dockerfile). Understand both before swapping in your own app; everything else is renaming.

**Where the coupling actually lives.** `_deploy.yml` is application-agnostic: it moves an image reference onto a Cloud Run service and asserts two HTTP responses. All of the .NET-specific knowledge is concentrated in `_build.yml` and the `Dockerfile`. Porting to another language means rewriting those two files and leaving the rest alone.

## 1. Application code and solution

| What | Where | Change to |
|---|---|---|
| Solution name | `cicd-demo.sln` | Your solution. Also update the `solution` input default in `_build.yml` if you rename it |
| Project names/paths | `Api/`, `Api.Test/` | Your projects. The test and publish paths are **hardcoded** in `_build.yml` (`dotnet test Api.Test/Api.Test.csproj`, `dotnet publish Api/Api.csproj`) — update both steps |
| Target framework | `Directory.Build.props` (`net10.0`), `dotnet-version: '10.x'` in `_build.yml`, and the base image in the `Dockerfile` | Your .NET version — keep all three in sync |
| Commit link in Swagger | `Api/Program.cs` (`commitNote`) | Nothing to change — CI stamps the repository URL into assembly metadata (`/p:RepositoryUrl` in `_build.yml` → `AssemblyMetadata` in `Api.csproj`), so the link follows your repo automatically; local builds show the SHA unlinked |
| OpenAPI title | `Api/Program.cs` (`document.Info.Title = "cicd-demo API"`) | Your API's name |
| Test expectations | `Api.Test/HelloWorldEndpointTests.cs` | Tests assert the sample endpoints — replace alongside the app |
| `public partial class Program { }` | End of `Api/Program.cs` | **Keep it** (adapted to your entry point). It makes the entry point visible to `WebApplicationFactory<Program>` — removing it breaks the integration tests |
| Listening port | `Dockerfile` (`ASPNETCORE_HTTP_PORTS=8080`, `EXPOSE 8080`) and `--port 8080` in both `gcloud run deploy` invocations in `_deploy.yml` | Cloud Run injects `PORT` and defaults it to 8080. If you change it, change it in both places |

## 2. `_build.yml` — the .NET-specific workflow

Every language assumption in the pipeline lives in this one file. Replacing the stack means replacing these steps:

| Step | Hardcoded value | Replace with |
|---|---|---|
| Setup .NET | `actions/setup-dotnet`, `dotnet-version: '10.x'` | Your toolchain's setup action |
| Cache | `~/.nuget/packages`, key `${{ runner.os }}-nuget-${{ hashFiles('**/*.csproj') }}` | Your package cache path and a key over your manifest files (`package-lock.json`, `go.sum`, `poetry.lock`, …) |
| Restore | `dotnet restore <solution>` | Your dependency install |
| Build | `dotnet build … /p:InformationalVersion="$BUILD_LABEL" /p:RepositoryUrl="$REPO_URL"` | Your compile step — **keep a build-time version stamp** (see below) |
| Test | `dotnet test Api.Test/Api.Test.csproj … --logger "trx;…"` | Your test runner. The `.trx` output feeds `publish-unit-test-result-action`; swap the format and the reporter together, or drop the reporter |
| Publish | `dotnet publish Api/Api.csproj --output ./publish` | Whatever produces your runnable artifact — **the `Dockerfile` expects it at `./publish`** |

Three properties of this job are load-bearing and survive any language change:

- **Tests run before the image is built**, and `continue-on-error: true` on the test step exists only so the results can be published as a check before the run fails. The "Fail if tests failed" step is what actually stops the pipeline — keep both, or make failure unconditional.
- **`push-image` is false by default.** PR validation builds and tests but produces nothing deployable; every deploying caller passes `true`. That input is also why every caller must grant `id-token: write` — a called workflow cannot exceed its caller's permission grant, and the grant is evaluated at job start, before any step condition. This is why `on-pr.yml` grants a permission it never uses.
- **The digest is the output that matters.** The push step reads `containerimage.digest` from buildx's metadata file and fails loudly if it's missing. Two tags (`sha-<commit>` and the build label) are pushed for legibility and lookup, but the digest is what every downstream deploy consumes.

### The version stamp is not optional

`_build.yml` compiles the build label into the binary (`InformationalVersion`), the app surfaces it at `/openapi/v1.json`, and every smoke test asserts it. If your replacement stack has no equivalent, **create one** — a generated version file, an `ldflags` `-X` injection, a `VERSION` env baked at build time — and expose it on an HTTP endpoint. Without it, the pipeline loses its ability to distinguish "the app is up" from "the app I intended to deploy is up," which is the single check that catches a traffic shift that silently didn't take, or a promotion that shipped the wrong digest.

## 3. The smoke-test contract

Every deploy is verified by two assertions in `_deploy.yml`, used identically by the candidate smoke test (pre-traffic, gated rollout) and the post-deploy smoke test:

1. `GET /v1/hello` returns exactly `Hello World!`
2. `GET /openapi/v1.json` has `.info.version` equal to the deployed build label

**Pre-release tolerance:** the check passes if the reported version equals the expected label *or* starts with the expected label followed by `-`. This is what lets a promoted release candidate satisfy prod's expectation — prod deploys `1.6.0` and the binary honestly reports `1.6.0-rc.3`, because promoted images are bit-identical to what QA tested and keep their candidate stamp.

**Retry semantics:** twelve attempts, ten seconds apart, each request capped at ten seconds. A wrong version is treated as "not ready yet" rather than an immediate failure — the previous revision may still be serving while the new one warms — and only a timeout fails the step.

When you replace the sample app, either:

- **Keep the contract shape (recommended):** expose a cheap health/greeting endpoint and a document whose version field reflects the build stamp — the wiring to copy is in `Api/Program.cs` (read the assembly attribute, split on `+`, stamp the OpenAPI document). This preserves the pipeline's strongest guarantee: a deploy only reports success when the *right build* is serving.
- **Or edit both smoke-test steps** in `_deploy.yml` to assert whatever your app can answer. Don't delete the version assertion casually — without it, a traffic shift that silently didn't take effect, or a wrong-digest deploy, reports green. If you keep only one assertion, keep this one.

Also note: Swagger UI and the OpenAPI document are enabled in **all environments including prod** (`Api/Program.cs`) because this sample has no sensitive surface. For a real API, consider restricting them — but the smoke test reads `/openapi/v1.json`, so if you lock the spec down, give the version assertion another endpoint to read.

## 4. The packaging contract (`Dockerfile`)

**The `Dockerfile` copies `./publish`; it does not build.** This is deliberate and load-bearing, not a shortcut:

```dockerfile
COPY --chown=app:app ./publish .
```

CI has already restored, built, **tested**, and published the application, stamping the build label into the binary. The image therefore contains the exact binary the tests ran against. A `Dockerfile` that rebuilt from source would produce a *different* binary from the one CI verified and would discard the build-time version stamp — at which point the smoke test's version assertion is checking an artifact nobody tested.

The tradeoff is that `docker build .` on a clean checkout fails, because `./publish` doesn't exist. To build locally:

```sh
dotnet publish Api/Api.csproj -c Release -o ./publish
docker build -t cicd-demo .
```

**If you swap languages, preserve the property, not the syntax.** Whatever you write must still:

- **Package the tested artifact.** The thing that goes in the image is the thing the test step exercised — not a re-compilation of the same source. If your toolchain can't publish a portable artifact, the fallback is a multi-stage build that runs the tests *inside* the same stage that produces the binary, so a test failure fails the image build.
- **Carry a build-time version stamp the smoke test can read.** See [the version stamp](#the-version-stamp-is-not-optional) above.
- **Listen on the port `_deploy.yml` configures** (8080 by default) and honour Cloud Run's injected `PORT`.

The non-root user and explicit `EXPOSE` are hygiene, not requirements — Cloud Run doesn't demand either. Keep them so the image behaves the same wherever it runs.

## 5. GitHub variables

No cloud identifier is hardcoded in any workflow. Everything is a GitHub Actions variable (not a secret — none of these are credentials), split by whether it varies per environment.

**Repository level** — Settings → Secrets and variables → Actions → Variables. Shared by every environment, read by `_build.yml`, `_deploy.yml`, and the image-lookup steps in `on-main.yml` / `on-release.yml` / `_hotfix-support.yml`:

| Variable | Purpose |
|---|---|
| `WIF_PROVIDER` | Full resource name of the Workload Identity Pool provider |
| `BUILD_SERVICE_ACCOUNT` | Identity used to push images and to *read* Artifact Registry during promotion lookups. Needs writer on the registry, nothing on Cloud Run |
| `AR_LOCATION` | Artifact Registry region (e.g. `northamerica-northeast1`) — also forms the Docker host `<AR_LOCATION>-docker.pkg.dev` |
| `AR_PROJECT_ID` | Project hosting the registry. Can differ from the runtime projects — a single shared registry across environments is the intended shape, since promotion moves one digest between them |
| `AR_REPOSITORY` | Artifact Registry repository name |
| `IMAGE_NAME` | Image name within the repository |

**Environment level** — Settings → Environments → (each of `dev`, `stg`, `prod`) → Environment variables. Read by `_deploy.yml` through the job's `environment:` scope:

| Variable | Required | Purpose |
|---|---|---|
| `DEPLOY_SERVICE_ACCOUNT` | yes | Identity impersonated for this environment's deploys. Needs Cloud Run admin on this service, and `actAs` on `RUNTIME_SERVICE_ACCOUNT` if set |
| `GCP_PROJECT_ID` | yes | Project hosting this environment's Cloud Run service |
| `GCP_REGION` | yes | Region of the service |
| `SERVICE_NAME` | yes | Cloud Run service name |
| `RUNTIME_SERVICE_ACCOUNT` | no | Identity the *container* runs as. Omitted, Cloud Run uses the project default. The deploy commands only pass `--service-account` when it's non-empty |
| `GATEWAY_URL` | no | Where smoke tests should hit the service. Set it when the service is behind a load balancer or internal ingress; otherwise `_deploy.yml` asks Cloud Run for `status.url`, because `run.app` hostnames carry a generated suffix and cannot be constructed from the service name |

**Adding a fourth environment needs no workflow edits.** `_deploy.yml` takes the environment name as an input and reads every cloud identifier from that environment's variables — there is no per-environment logic anywhere in it. Create the GitHub environment, set its variables, extend the WIF provider's attribute condition to accept the new `sub` claim, and call `_deploy.yml` with `environment: <name>` from whichever entry workflow should target it.

Renaming `dev` / `stg` / `prod` is the one change that must happen everywhere at once: the entry workflows' `environment:` inputs, the GitHub environment names, the WIF attribute conditions and service-account bindings, and the tag prefixes — the prod promotion gate specifically looks for tags matching `build/stg/`, so renaming `stg` means editing that lookup in `on-main.yml`.

## 6. The `runner` input on `_deploy.yml`

`_deploy.yml` accepts a `runner` input, defaulting to **`ubuntu-latest`**.

This differs from the Azure template, which hardcoded a self-hosted runner. The Cloud Run admin API is **IAM-gated rather than IP-gated**: a deploy needs the right identity, not the right network position, so a GitHub-hosted runner is sufficient — and cheaper, faster to start, and one less thing to maintain.

Point it at a self-hosted runner only when **the service uses internal ingress and the smoke test cannot otherwise reach it**. That is a smoke-test reachability problem, not a deploy-authorization problem, and it has a second solution: set `GATEWAY_URL` for that environment so the tests go through a public load balancer instead. Reach for the self-hosted runner when neither the service nor a gateway is publicly reachable.

## 7. Other workflow values

| What | Where | Notes |
|---|---|---|
| Cloud Run candidate tag | `_deploy.yml` (`cand-${{ github.run_id }}`) | Derived from the run id because Cloud Run tags must match `[a-z0-9-]{1,63}` and build labels contain dots. Keep the removal step — Cloud Run caps tags per service, and orphaned tags break deploys much later |
| `build-label` Cloud Run label | `_deploy.yml` (dots → dashes, lowercased) | Cloud Run label values reject dots and uppercase; the transform exists for that reason |
| Branch names | Workflow `on.push.branches` triggers, `on-pr.yml` guard, `on-main.yml` version regex (`release\|hotfix\|support`) | Only if your branch model differs. The version-detection regex, the guard job, and the ruleset configuration must stay in agreement with the triggers |
| Label derivation | `on-release.yml`, `_hotfix-support.yml` | `<version>-build.<height>`, `ms-<name>.<height>`, `<version>-hotfix.<height>`, `<version>-patch.<height>`. Changing the scheme mid-flight is safe — the pipeline deploys images under the label they were *stamped* with and warns about drift — but it costs you a rebuild on the next dispatch of an already-built commit |
| Label charset | Validation regex `^[0-9A-Za-z.-]+$` in the version-derivation steps | Labels become image tags and git tags. Keep the guard if you script label generation |
| Concurrency groups | `deploy-dev` / `deploy-stg` / `deploy-prod` in the entry workflows | Keep — they serialize deploys per environment. Release, hotfix, and support dispatches deliberately share `deploy-stg` |
| Action SHA pins | Every `uses:` in every workflow | All third-party actions are pinned to a commit SHA with a version comment. Keep that discipline when upgrading — a mutable tag on an action with cloud credentials in scope is a supply-chain hole |

## 8. Google Cloud resources and identities

| What | Notes |
|---|---|
| Cloud Run services | One per environment. Names live only in each GitHub environment's `SERVICE_NAME` variable — no code change needed |
| Artifact Registry | One Docker repository, shared across environments. Promotion moves a digest between environments, so a per-environment registry would force a copy and break the "bit-identical binary" guarantee |
| Registry cleanup policy | **Set one deliberately.** It is now the only thing bounding your prod rollback reach — the 90-day artifact expiry of the Azure template is gone, so retention is a policy decision rather than a platform limit |
| Workload Identity Pool + provider | Attribute condition must match on the `sub` claim (`repo:<owner>/<repo>:environment:<env>`). Run the **Show OIDC Token Claims** workflow to see exactly what a job presents |
| Build service account | Referenced only via `BUILD_SERVICE_ACCOUNT`. Writer on Artifact Registry; deliberately has no Cloud Run rights |
| Deploy service accounts | One per environment, referenced only via each environment's `DEPLOY_SERVICE_ACCOUNT`. Scope each to its own service — per-environment scoping is the blast-radius boundary, and it is why a dev job cannot obtain the prod identity |
| Runtime service account | Optional, per environment. The identity your *application* uses to reach other Google Cloud services — distinct from the deploy identity, and it should stay that way |

There are deliberately **no exported service-account keys** anywhere. See [workload-identity-federation.md](workload-identity-federation.md).

## 9. GitHub configuration

Covered step-by-step in [getting-started.md](getting-started.md). When adapting, re-check:

- Repo variables point at *your* WIF provider, build service account, and registry
- Environment variables point at *your* projects, regions, services, and deploy identities
- Rulesets name the same required checks (`build / Build & Test`, `Guard main source branch`) — if you rename the `_build.yml` job or the guard job, the ruleset check names must follow
- `main` still allows **merge commits only**: the prod pipeline reads the version from the merge commit subject and finds the release commit via the merge commit's second parent. A squash merge destroys both, and the pipeline fails rather than shipping something staging never tested
- **Allow GitHub Actions to create and approve pull requests** stays enabled (back-merge and backport PRs)
- The prod environment keeps its required reviewer and `main`-only deployment branch policy

## 10. Documentation

After adapting, sweep the docs for values that describe the reference deployment: the environment table in the [operations manual](operations-manual.md), the repository name in [workload-identity-federation.md](workload-identity-federation.md) examples, badge URLs and clone commands in the root [README](../README.md), and `CLAUDE.md` if you use AI-assisted tooling.

## Out of scope for this repo

The reference deployment's infrastructure — Cloud Run services, the Artifact Registry repository, the Workload Identity Pool and provider, and the build and deploy service accounts with their IAM bindings — is provisioned by Terraform in a separate platform repository. This repo contains no IaC. The pipeline only requires the resources listed in [getting-started.md](getting-started.md); provision them however your team prefers.
