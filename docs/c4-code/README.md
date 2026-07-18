# C4 — Code

The deepest zoom: how the key components are actually implemented. C4 keeps this level deliberately sparse — only the code worth a diagram gets one. This document walks the parts of the implementation where a design decision is embedded *in the code itself* and points at the source with `file:line` references.

← [C3 — Components](../c3-components/README.md) · [Architecture overview](../ARCHITECTURE.md)

> These are concrete realizations of the specification. The file paths reflect the current .NET / Cloud Run implementation; the *shape* (self-identifying build, versioned routing, immutable promotable image, verified deploy, secretless auth) is what the spec requires — a different stack would implement the same shapes elsewhere.

---

## Code map

| Element | File | Realizes (C3 component) |
|---|---|---|
| Application composition root | `Api/Program.cs` | The entire API application |
| Version metadata rendering | `Api/BuildInfo.cs` | Build Info Reader |
| Test-visibility shim | `Api/Program.cs:110` | app↔test contract |
| Endpoint contract tests | `Api.Test/HelloWorldEndpointTests.cs` | verification of the API surface |
| Packaging-only image | `Dockerfile` | Build-once-promote-many |
| Build labelling | `.github/workflows/_build.yml:63-74,92-106` | Build & Test |
| Image push + digest | `.github/workflows/_build.yml:174-219` | Package & Push |
| Secretless login | `.github/workflows/_deploy.yml:79-83` | Deploy identity |
| Gated rollout + smoke test | `.github/workflows/_deploy.yml:138-230` | Deploy verification contract |
| Traffic rollback | `.github/workflows/_deploy.yml:285-303` | Automatic recovery |
| Promotion gate | `.github/workflows/on-main.yml:149-178` | Image promotion & gating |
| Immutable tagging | `.github/workflows/_deploy.yml:341-375` | Audit trail |

---

## 1. The composition root — `Api/Program.cs`

The whole application is one file: a minimal-API startup that wires services, then maps endpoints. Reading it top to bottom traces the C3 components in order.

### 1.1 Build Info Reader — the self-identifying build

```csharp
// Api/Program.cs:12-19
var assembly = Assembly.GetExecutingAssembly();
var (buildLabel, commitSha) = BuildInfo.Split(assembly
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
    .InformationalVersion);
var repositoryUrl = assembly
    .GetCustomAttributes<AssemblyMetadataAttribute>()
    .FirstOrDefault(a => a.Key == "RepositoryUrl")?.Value;
var commitNote = BuildInfo.CommitNote(commitSha, repositoryUrl);
```

The .NET SDK appends the commit SHA to `InformationalVersion` as SemVer build metadata (`<label>+<sha>`). `BuildInfo.Split` (`Api/BuildInfo.cs:14-22`) recovers the two halves: the label becomes the displayed/asserted version, the SHA becomes a commit reference. `BuildInfo.CommitNote` (`:31-41`) renders it as a markdown link when CI stamped a `RepositoryUrl` and as a plain short SHA otherwise, so local builds degrade gracefully. **This is the source end of the app↔pipeline contract** — the value the smoke test later asserts against. The split and rendering live in a pure static class precisely so they are unit-testable without a compiled-in assembly attribute.

### 1.2 API Versioning

```csharp
// Api/Program.cs:21-37
builder.Services
    .AddApiVersioning(options => {
        options.DefaultApiVersion = new ApiVersion(1);
        options.ApiVersionReader = ApiVersionReader.Combine(
            new UrlSegmentApiVersionReader(),
            new HeaderApiVersionReader("api-version"));
    })
```

Version is read from the URL segment (`/v1/…`) *or* an `api-version` header. `GroupNameFormat = "'v'V"` (`:35`) makes the OpenAPI group name (`v1`) line up with the default document name, and `SubstituteApiVersionInUrl` (`:36`) expands the `{version:apiVersion}` route token to a literal path in the spec — which is why the tests can assert the literal `/v1/hello`.

### 1.3 OpenAPI Document Provider — making the build observable

```csharp
// Api/Program.cs:41-58
builder.Services.AddOpenApi(options => {
    options.AddDocumentTransformer((document, context, cancellationToken) => {
        document.Info.Title = "cicd-demo API";
        document.Info.Version = buildLabel;                    // ← asserted by the pipeline
        document.Info.Description =
            $"Deployed build: **{buildLabel}**{commitNote} — environment: **{builder.Environment.EnvironmentName}**";
        document.Servers?.Clear();
        return Task.CompletedTask;
    });
});
```

`document.Info.Version = buildLabel` is the **sink end of the contract**: the deploy job reads exactly this via `jq -r '.info.version'`. Clearing `Servers` (`:54`) keeps Swagger's "Try it out" same-origin, so it works whether the doc was fetched from the `run.app` URL directly or through a gateway's path prefix.

### 1.4 Endpoints, probes, and the gateway prefix

```csharp
// Api/Program.cs:66-106
var pathBase = app.Configuration["PATH_BASE"];
if (!string.IsNullOrEmpty(pathBase)) { app.UsePathBase(pathBase); }   // no-op when unset
app.MapGet("/", () => "Hello World!").ExcludeFromDescription();      // unversioned greeting
app.MapHealthChecks("/healthz").ExcludeFromDescription();            // liveness probe
var api = app.MapGroup("/v{version:apiVersion}").WithApiVersionSet(apiVersions);
api.MapGet("/hello", () => "Hello World!").MapToApiVersion(new ApiVersion(1));  // smoke-test target
app.MapOpenApi();                                                    // /openapi/v1.json
app.UseSwaggerUI(o => o.SwaggerEndpoint("../openapi/v1.json", "cicd-demo v1"));
```

Two path decisions carry weight. `UsePathBase` lets one image serve correctly both at the service's own hostname and behind a load balancer that forwards a prefix — the same reason the Swagger endpoint is `../openapi/v1.json` rather than an absolute `/openapi/v1.json` (`:102-105`), which would escape the prefix. And `/healthz` is deliberately decoupled from the greeting (C3): the platform probe must not depend on business responses, and dependency checks can be registered on `AddHealthChecks()` at `:39` to surface as Degraded/Unhealthy.

### 1.5 The test-visibility shim — don't delete this

```csharp
// Api/Program.cs:110
public partial class Program { }
```

Minimal-API programs have an implicit, internal entry point. This partial declaration makes `Program` visible so the test project's `WebApplicationFactory<Program>` can boot the *real* app in-process. Removing it breaks every integration test.

---

## 2. Endpoint contract tests — `Api.Test/HelloWorldEndpointTests.cs`

The tests boot the real app via `WebApplicationFactory<Program>` and exercise the HTTP surface — the same surface the deploy smoke test hits, verified before the image is ever pushed:

```csharp
// Api.Test/HelloWorldEndpointTests.cs — one assertion per surface element
Root_ReturnsHelloWorld                          → GET /               == "Hello World!"
Healthz_ReportsHealthy                          → GET /healthz        == "Healthy"
V1Hello_ReturnsHelloWorld                       → GET /v1/hello       == "Hello World!"
OpenApiSpec_IsServed                            → GET /openapi/v1.json contains /v1/hello, title, "Deployed build:"
SwaggerUi_IsServed                              → GET /swagger/index.html contains "swagger-ui"
OpenApiSpec_OmitsServers_SoTryItOutStaysSameOrigin
PathBase_PrefixedRequests_AreServed / _UnprefixedRequests_StillServed
```

The OpenAPI tests assert the *shape* of the stamped document and the absence of a `servers` entry, and the `PATH_BASE` pair asserts the gateway behaviour both ways — so a regression in the Build Info / OpenAPI / prefix wiring fails the build rather than surfacing only after deploy.

---

## 3. Packaging, not building — `Dockerfile`

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine
RUN adduser --disabled-password --gecos '' --uid 64198 app
USER app
WORKDIR /app
COPY --chown=app:app ./publish .
ENV ASPNETCORE_HTTP_PORTS=8080
ENTRYPOINT ["dotnet", "Api.dll"]
```

The image **copies CI's publish output instead of building from source**. That single `COPY` is the architectural line: the binary in the image is the exact binary the tests ran against, still carrying the `InformationalVersion` stamped at build time. A multi-stage Dockerfile that rebuilt from source would produce different bytes than the tests verified and would silently break the smoke test's version assertion. The accepted cost is that `docker build .` fails on a clean checkout — run `dotnet publish Api/Api.csproj -c Release -o ./publish` first.

Port 8080 is pinned here *and* in `_deploy.yml`'s `--port 8080`; Cloud Run's own default agrees. Change one and you must change all three. Running as a non-root uid is not a Cloud Run requirement — it is there so the image behaves the same on platforms that do require it.

---

## 4. Build labelling and image push — `.github/workflows/_build.yml`

The label is resolved once and stamped into the assembly **at build time** (publish runs `--no-build`, so a later stamp would be too late):

```yaml
# _build.yml:63-74 — resolve the label (explicit input, else date-based)
if [ -n "$INPUT_VERSION" ]; then echo "value=$INPUT_VERSION" >> "$GITHUB_OUTPUT"
else echo "value=$(date +'%Y%m%d').$RUN_NUMBER" >> "$GITHUB_OUTPUT"; fi

# _build.yml:101-106 — compile it in, along with the repo URL for the commit link
dotnet build ... /p:InformationalVersion="$BUILD_LABEL" /p:RepositoryUrl="$REPO_URL"
```

This is the origin of the value that flows: **build label → `InformationalVersion` → `document.Info.Version` → smoke-test assertion → git tag.** Inputs are passed via `env:` and never interpolated into the shell script (injection-safe).

### 4.1 The digest is the output that matters

```bash
# _build.yml:191-209
docker buildx build --file Dockerfile \
  --tag "${IMAGE}:sha-${COMMIT_SHA}" \
  --tag "${IMAGE}:${BUILD_LABEL}" \
  --metadata-file /tmp/build-metadata.json --push .

DIGEST="$(jq -r '."containerimage.digest"' /tmp/build-metadata.json)"
echo "ref=${IMAGE}@${DIGEST}" >> "$GITHUB_OUTPUT"
```

Two tags are pushed, but neither is the promotable identity — `image-ref` is always `IMAGE@sha256:…`. Tags are mutable and exist for human legibility and for the `sha-<commit>` lookup that later jobs use to *find* an image; the digest is what gets deployed. The whole step is gated on `if: inputs.push-image` (`:176`), so PR validation builds and tests but produces nothing deployable.

### 4.2 The permission that fails with no logs

```yaml
# _build.yml:50-58
permissions:
  contents: read
  checks: write
  pull-requests: write
  id-token: write        # required for WIF even though only the push steps use it
```

A called workflow's `permissions` block is evaluated at job start, *before* any step condition — and a called workflow cannot exceed its caller's grant. Every caller that passes `push-image: true` must also grant `id-token: write`, or the run dies instantly with `startup_failure` and no logs at all. `on-pr.yml` grants it too (`on-pr.yml:28`) even though it never mints a token, for exactly this reason.

---

## 5. Deploy verification — `.github/workflows/_deploy.yml`

### 5.1 Secretless login

```yaml
# _deploy.yml:79-83
- uses: google-github-actions/auth@...
  with:
    workload_identity_provider: ${{ vars.WIF_PROVIDER }}       # repo-level, not a secret
    service_account: ${{ vars.DEPLOY_SERVICE_ACCOUNT }}        # per-environment
```

No secret and no service-account key appear anywhere. The job's `environment: ${{ inputs.environment }}` (`:73`) is what puts `environment:<env>` into the OIDC token's `sub` claim; the WIF provider matches the repository via an attribute condition, and the per-environment IAM binding on the deploy service account matches the full subject `repo:OWNER/REPO:environment:<env>`. A dev job cannot become the prod identity because its token carries a different subject. Full mechanism: [`workload-identity-federation.md`](../workload-identity-federation.md).

Note the asymmetry with `_build.yml`: the build job runs *without* an `environment:` declaration, so its subject is `repo:OWNER/REPO:ref:refs/heads/…`. That is why the provider's attribute condition scopes on `assertion.repository` rather than on a subject pattern — and why environment scoping lives on the deploy service accounts, where the tokens actually carry an environment claim.

### 5.2 The gated rollout — deploy cold, verify, then shift

```bash
# _deploy.yml:154-165 — candidate revision takes no traffic
TAG="cand-${RUN_ID}"
gcloud run deploy "$SERVICE_NAME" --image "$IMAGE_REF" ... --no-traffic --tag "$TAG"

# _deploy.yml:225-229 — only after the candidate smoke test passes
gcloud run services update-traffic "$SERVICE_NAME" --to-revisions "${REVISION}=100"
```

This is the Cloud Run equivalent of a deploy-to-slot-then-swap, with the advantage that the candidate gets a stable preview URL without a second deployment target. The tag is derived from `github.run_id`, not the build label (`:141-143`): Cloud Run tags must match `[a-z0-9-]{1,63}` and build labels legitimately contain dots (`1.1.0-build.187`). The tagged URL is *read back* from the service description (`:171-174`) rather than constructed — `run.app` hostnames carry a generated suffix.

### 5.3 The smoke test — the deploy verification contract in code

```bash
# _deploy.yml:197-213 (candidate) and 267-283 (post-deploy) — same contract
for i in $(seq 1 12); do
  BODY=$(curl -fsS --max-time 10 "$URL/v1/hello" || true)
  if [ "$BODY" = "Hello World!" ]; then
    DEPLOYED=$(curl -fsS --max-time 10 "$URL/openapi/v1.json" | jq -r '.info.version // empty' || true)
    if [ "$DEPLOYED" = "$EXPECTED" ] || [[ "$DEPLOYED" == "$EXPECTED"-* ]]; then
      exit 0        # healthy: right answer AND right build
    fi
  fi
  sleep 10
done
exit 1              # timed out → fail the deploy
```

`[[ "$DEPLOYED" == "$EXPECTED"-* ]]` accepts a pre-release of the expected label — a promoted image keeps its rc stamp (e.g. prod expects `1.6.0`, the byte-identical stg image reports `1.6.0-build.42`), which is *correct* and must pass. A mismatch is retried (warm-up / traffic propagation), not failed immediately. Running the identical contract on the candidate URL and again on the service URL is not redundant: the first proves the image is good, the second proves the traffic shift actually took effect.

The URL is resolved once (`:236-257`), preferring the environment's `GATEWAY_URL` when set — a service behind internal ingress does not admit callers on its `run.app` hostname, and the smoke test should verify the path users actually take.

### 5.4 Automatic traffic rollback

```yaml
# _deploy.yml:285-303
- name: Roll traffic back after failed post-shift smoke test
  if: ${{ failure() && steps.shift.outcome == 'success' && steps.current.outputs.revision != '' }}
  run: gcloud run services update-traffic ... --to-revisions "${PREV_REVISION}=100"
```

Both guards are load-bearing. `steps.shift.outcome == 'success'` means traffic actually moved: a *pre*-shift failure (a bad build caught on the candidate URL) never reached users and must **not** trigger a rollback, and a direct dev/stg deploy has no shift at all. `steps.current.outputs.revision != ''` handles the very first deploy of a service, where there is nothing to roll back to — the previously serving revision was captured at `:88-105`, before anything changed. The job still fails; this only restores service.

The candidate tag is removed with `if: always()` (`:305-322`): Cloud Run caps the number of tags on a service, and leaked tags break deploys much later, at a point where the cause is very hard to see.

### 5.5 Immutable deployment tags

```javascript
// _deploy.yml:350-375 (github-script) — create-or-verify, never move
try {
  await github.rest.git.createRef({ ref: `refs/tags/build/<env>/<label>`, sha });
} catch (err) {
  if (err.status !== 422) throw err;                 // 422 = tag already exists
  const existing = await github.rest.git.getRef(...);
  if (existing.data.object.sha === sha) core.info('already correct — no-op');
  else core.setFailed('deployment tags are immutable — use a new label');
}
```

The tag is written on the commit the image was **built from** (`SOURCE_SHA`, the release-branch head on the promotion path — not the merge commit). Reusing a label for different code fails the deploy rather than silently rewriting history. The tag ref is passed via `env:` and not interpolated into the script source, so a label cannot inject JavaScript even if upstream validation is ever loosened.

---

## 6. The promotion gate — `.github/workflows/on-main.yml`

```bash
# on-main.yml:153-158 — "the image exists" is NOT "staging tested it"
STG_TAG=$(gh api --paginate "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/build/stg/" \
  --jq ".[] | select(.object.sha == \"$RELEASE_SHA\") | .ref" | head -1)
if [ -z "$STG_TAG" ]; then
  echo "::error::No build/stg/* tag points at $RELEASE_SHA — this build was never successfully deployed to staging."
  exit 1
fi

# on-main.yml:161-165 — only then, resolve the digest to promote
DIGEST="$(gcloud artifacts docker images list "$IMAGE" --include-tags \
  --filter="tags:sha-${RELEASE_SHA}" --format='value(version)' | head -1)"
```

This is the single most important gate in the pipeline. The image is pushed at *build* time, before any deploy, so its existence proves nothing about verification. A `build/stg/*` tag is created only after a staging deploy passes its smoke test — so requiring one on the release-branch head is what makes "prod only ships what staging tested" a checked fact rather than an assumption.

Every failure on this path is a hard error, never a fallback rebuild (`:144-147`, `:155-158`, `:171-178`): a release head that can't be resolved, a missing stg tag, or a missing image all fail the prod run. Silently rebuilding from source would ship untested bytes to production — precisely the outcome the whole chain exists to prevent. Note the failure mode differs from an artifact-based pipeline's: digests do not expire, so "no image found" means it was never built for that commit or a registry cleanup policy deleted it, never that a retention window lapsed.

---

## Key decisions at this level

- **One value, threaded through every layer.** The build label is chosen in shell (`_build.yml`), compiled into the binary (`InformationalVersion`), baked into the image, re-emitted over HTTP (`Program.cs`), asserted twice by the deploy (`_deploy.yml`), and frozen as an immutable git tag. The code at each hop preserves that identity exactly.
- **The digest is the only thing that crosses job boundaries.** `image-ref` is always digest-pinned. Tags are for lookup and for humans; nothing that ships is selected by a mutable name.
- **The contract is enforced by real HTTP, not mocks.** Integration tests and the deploy smoke test hit the same endpoints the same way, so "passes CI" and "works when deployed" test the same surface — and the packaging-only Dockerfile guarantees they test the same bytes.
- **Security properties live in small, load-bearing lines.** No stored key (`vars.*` + `environment:` shaping the OIDC subject), no privilege to move a tag (create-or-verify), no traffic rollback on a pre-shift failure (the `steps.shift.outcome` guard), no prod deploy without a `build/stg/*` tag. Each is a few lines carrying an architectural guarantee — worth reading carefully before editing.
</content>
