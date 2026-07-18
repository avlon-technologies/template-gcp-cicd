# Operations Manual

How to build, deploy, release, and verify this application across environments.

> Setting the pipeline up for the first time? Start with [getting-started.md](getting-started.md). Adapting the template to your own project? See [customization.md](customization.md). This manual covers day-to-day operation of a configured pipeline.

## Environments at a glance

| Environment | Cloud Run service | URL | Deployed by |
|---|---|---|---|
| dev | `SERVICE_NAME` in the `dev` environment | resolved at deploy time | push to `develop` (automatic) |
| stg | `SERVICE_NAME` in the `stg` environment | resolved at deploy time | manual dispatch of a release, hotfix, or support pipeline |
| prod | `SERVICE_NAME` in the `prod` environment | resolved at deploy time | merge PR to `main` (automatic, **gated rollout**) |

**URLs are resolved, not constructed.** `run.app` hostnames carry a generated suffix and are not derivable from the service name, so `_deploy.yml` asks Cloud Run for `status.url`. When an environment defines `GATEWAY_URL`, that value is used instead — a service behind internal ingress and a load balancer does not admit callers on its `run.app` hostname. Every deploy run's summary prints the URL it actually used.

**Quality gates (enforced by repository rulesets):** all merges to `develop` and `main` go through a pull request, every PR must pass the **build / Build & Test** check (the `on-pr.yml` workflow), and `main` accepts merge commits only — squash and rebase are disabled there because release version detection reads the merge commit subject. **PRs into `main` may only come from `release/*`, `hotfix/*`, or `support/*` branches** (the **Guard main source branch** check) — features flow to prod through a release, never directly.

Every deploy, in every environment, ends with an automatic **smoke test**: `GET /v1/hello` must return exactly `Hello World!` **and** `GET /openapi/v1.json` must report `.info.version` equal to the build label being deployed — or a pre-release of it, so `1.6.0-rc.3` satisfies an expectation of `1.6.0`. The check retries up to twelve times at ten-second intervals; a version mismatch is treated as "not ready yet" until the loop times out, since the old revision may still be serving while the new one warms up. A deploy that leaves the app broken *or serving the wrong build* fails the pipeline instead of reporting success.

## What identifies a build

Three names travel together, and it matters which one is load-bearing:

| Name | Example | Role |
|---|---|---|
| **Image digest** | `sha256:9f2c…` | **The promotable identity.** Every deploy references the image by digest, never by tag, so a moved tag cannot change what ships |
| Commit tag | `sha-<commit>` | How later runs *find* the digest for a given commit (`gcloud artifacts docker images list --filter="tags:sha-<sha>"`) |
| Build label | `1.1.0-build.187` | Human-legible version, compiled into the binary as `InformationalVersion`, asserted by the smoke test, and used for git tags |

> **Digests do not expire.** This is the one behavioural improvement over the Azure original worth internalising: that template promoted a GitHub Actions artifact, which vanished after 90 days and took the rollback window with it. **"Artifact expired, rollback window closed" is not a failure mode here.** Rollback reach is bounded only by your Artifact Registry retention/cleanup policy — if you never delete images, a two-year-old release is still promotable.

## Deploy to dev (automatic)

Merging a PR to `develop` (or any push to it) triggers **CI/CD — Develop → DEV**: build → test → push image → deploy to dev. No manual steps.

```sh
gh pr create --base develop --head my-feature
gh pr merge --merge
```

The build is labeled `YYYYMMDD.<run_number>`. Dev deploys are not tagged — the **Deployments** view and the run history are the record, and the running build is always identifiable via Swagger.

To redeploy under a previous dev label (e.g. to retry a failed deploy with the same label):

**From the command line:**
```sh
gh workflow run on-develop.yml --ref develop -f build-label=20260703.32
```

**From the UI:** Actions → **CI/CD — Develop → DEV** → Run workflow → enter the build label (e.g. `20260703.32`). The label must be in `YYYYMMDD.<run_number>` form and must match a previous **CI/CD — Develop → DEV** run — it is validated against that workflow's own run history, searching from the day before too, since a run can be created just before UTC midnight relative to the build step that stamped the date. The pipeline fails fast if it doesn't match. Leave the input empty to build and deploy HEAD normally.

> **Dev redeploy rebuilds; it does not promote.** Unlike the release-family pipelines, this path builds HEAD afresh and stamps it with the label you supplied. Dev deploys are disposable and untagged, so there is no commit-keyed lookup to reuse. If you need the *exact* binary from an old dev run, shift traffic to its revision with `gcloud` instead.

## Cut a release

Once the state of `develop` is ready to become a release, create and push a release branch named after the bare version (no `v`, no candidate suffix — see naming rationale below):

```sh
git checkout develop && git pull
git checkout -b release/1.1.0
git push -u origin release/1.1.0
```

Every push to `release/**` triggers **CI/CD — Release → STG** in build-only mode: it builds, tests, and pushes an image to Artifact Registry, but does **not** deploy. Land stabilization fixes directly on this branch.

**Candidate labels are derived from the commit, not chosen.** The label is a pure function of the branch name and the commit height (`git rev-list --count HEAD`): the tip of `release/1.1.0` at height 187 builds `1.1.0-build.187`, and every stabilization fix advances the height, minting the next candidate automatically. There is no version input anywhere in the flow. Because the same commit always derives the same label, the push build's image *is* the candidate — it is tagged `sha-<commit>` for exactly the lookup a later dispatch performs, plus the label itself for legibility.

Milestone branches (`milestone/**`) run the same pipeline and derive `ms-<name>.<height>`.

> **Every push to a release-family branch pushes an image.** That is deliberate: labels are commit-derived, so the push build already carries the label a later dispatch will resolve, and rebuilding a commit CI already built is pure waste. The cost is registry storage rather than the Azure template's artifact-retention tradeoff — govern it with an Artifact Registry cleanup policy, keeping in mind that the policy, not a fixed 90 days, is now what bounds your prod rollback reach. Images are readable by anyone with pull access, which stays harmless **only while builds embed no secrets** (configuration belongs in Cloud Run service settings at deploy time, never in the image).

## Deploy a release candidate to staging

Deploys to stg are gated on a human trigger (manual dispatch). Dispatching means exactly "deploy this branch's HEAD to stg" — nothing to type.

**From the UI:**
1. **Actions** tab → **CI/CD — Release → STG** (left sidebar)
2. Click **Run workflow**
3. **Use workflow from:** select the release branch (e.g. `release/1.1.0`) — easy to miss; it defaults to the repository's default branch (`develop`), and the pipeline fails fast if the selected branch isn't a `release/*` or `milestone/*` branch
4. Click **Run workflow**

**From the command line:**
```sh
gh workflow run on-release.yml --ref release/1.1.0
```

The dispatch **reuses the image the push already built** — it looks the image up by its `sha-<commit>` tag, recovers the label from the image's other tag, skips the build job, and deploys by digest. The binary that reaches stg is bit-identical to the one CI tested on push. The run deploys to stg and tags the commit `build/stg/1.1.0-build.187` — the audit trail of exactly what QA tested, and the artifact the prod promotion gate later looks for.

A rebuild happens only if no image is tagged `sha-<commit>` (the commit was never built, or its image was removed by a cleanup policy) or if the image carries no label tag. A new candidate requires a new commit — push the fix, the height advances, dispatch again.

> **The stamped label wins over the derived one.** If the label-derivation logic changed between the push build and the dispatch, the pipeline deploys under the label the image was *actually stamped with* and writes a "label drift" warning to the run summary. The version is compiled into the binary; re-labeling would ship an app that reports something other than what it is. Push a new commit to adopt the new derivation.

## Deploy to production

When a candidate is accepted, merge the release branch to `main` via PR:

```sh
gh pr create --base main --head release/1.1.0 --title "Release 1.1.0"
gh pr merge --merge        # merge commit — do NOT squash (see note)
```

Merging triggers **CI/CD — Main → PROD**, which automatically:

1. Extracts `1.1.0` from the merge commit subject
2. Resolves the release commit — the merge commit's **second parent** (`.parents[1]`), i.e. the release branch head, not the merge commit itself
3. **Verifies staging actually tested it.** A `build/stg/*` git tag must point at that release commit. This gate exists because **"image exists" is not "staging tested it"**: the image is pushed at build time, before any stg deploy, whereas a `build/stg/*` tag is created only after a stg deploy passes its smoke test. No matching tag is a **hard error** — the run refuses to promote rather than shipping something staging never saw
4. **Promotes the stg-tested image** (build-once-promote-many): it finds the digest via the release commit's `sha-<commit>` tag and ships *that exact image* — the build job is skipped. A resolved version with no locatable image is likewise a hard error, never a silent rebuild
5. Deploys via **gated rollout** (below)
6. Tags the release-branch commit the image was built from as `build/prod/1.1.0`
7. Creates GitHub Release **v1.1.0** with generated notes

### The gated rollout

This replaces the Azure template's deploy-to-slot-then-swap, and needs no second deployment target:

1. `gcloud run deploy --no-traffic --tag cand-<run_id>` — the new revision goes up **cold**, taking no production traffic, and gets its own stable preview URL
2. The candidate is smoke-tested **on that tagged URL**. A failure here aborts before any traffic shift: **production is untouched, and there is nothing to roll back**
3. `gcloud run services update-traffic --to-revisions <revision>=100` — traffic shifts to the candidate
4. The post-shift smoke test runs against the live service URL. It catches both a traffic shift that silently didn't take effect and a deploy that shipped the wrong image
5. **On a failed post-shift smoke test, traffic returns to the revision recorded before the deploy** — captured in the run's first step, before anything changed. The job still fails; production is left running the prior version
6. **The candidate tag is removed afterward, always** — on success and on failure alike

> **Why the tag is always cleaned up.** Cloud Run caps the number of tags on a service. Leaving `cand-*` tags to accumulate breaks deploys much later, at a point where the cause is very hard to see — so the removal step runs unconditionally and tolerates its own failure.

> **Rollback only happens if traffic actually moved.** The rollback step is conditioned on the traffic-shift step having succeeded *and* on a previously serving revision having been recorded. A pre-shift failure never took traffic, and the very first deploy of a service has no predecessor to return to.

> **The Cloud Run tag is derived from the run id, not the build label.** Cloud Run tags must match `[a-z0-9-]{1,63}`, and build labels legitimately contain dots (`1.1.0-build.187`). The same constraint is why the `build-label` Cloud Run label has its dots lowercased to dashes.

> **Promoted images keep their candidate stamp.** Because the promoted binary is bit-identical to what QA tested, prod's Swagger shows the label it was built with (e.g. `1.1.0-build.187`) — that's a feature: it tells you exactly which candidate was promoted, and the smoke test's pre-release tolerance is what lets it satisfy an expectation of `1.1.0`. The git tag (`build/prod/1.1.0`) and GitHub Release (`v1.1.0`) carry the release version.

> **Always use a merge commit for release PRs, with the default message.** The version is read from the merge commit subject ("Merge pull request #N from …/release/1.1.0"), and the release commit is found via the merge commit's second parent — a squash merge has neither. A push whose subject doesn't name a `release/*`, `hotfix/*`, or `support/*` branch **fails the prod run outright**: the stg-tested image can't be located without a version, and the pipeline refuses to rebuild untested source for prod. The only escape hatch is an explicit dispatch with `rebuild-from-source: true` (see below). Squash also breaks the back-merge.

8. Opens a **back-merge PR** from the release branch into `develop`, so stabilization fixes aren't lost (requires the "Allow GitHub Actions to create and approve pull requests" setting — see repository settings below). This runs as its own `backmerge` job, **in parallel with the deploy** rather than after it: the commits are on `main` the moment the PR merges, so `develop` needs them back even if the prod deploy fails or is still waiting on the prod environment's approval gate. (For **hotfix and support** merges the job cherry-picks onto a `backport/<version>` branch instead — see the hotfix section.)

The back-merge PR is created automatically but merged manually — review it (conflicts with ongoing develop work are possible), merge with a merge commit, then delete the release branch:

```sh
gh pr merge <back-merge-pr> --merge
git push origin --delete release/1.1.0
```

(If nothing landed on the release branch after it was cut, the PR will show no diff or won't be created — just delete the branch.)

### The emergency escape hatch

To knowingly deploy an untested rebuild of `main`, bypassing the staging gate entirely:

```sh
gh workflow run on-main.yml --ref main -f rebuild-from-source=true
```

This builds `main`'s HEAD fresh, labels it with the date fallback (`YYYYMMDD.<run_number>`), and puts it through the same gated rollout. It exists so that "the gate refused" is never a dead end — but it ships a binary no staging environment has seen, which is why it must be asked for explicitly and cannot be reached by leaving an input blank. Dispatches must run from `main`; the workflow rejects any other ref with an explanatory error, and the prod environment's deployment branch policy enforces the same rule independently.

## Hotfix production

For urgent fixes that can't wait for a release cycle. Always cut from `main` (or the relevant version tag), not `develop`:

```sh
git checkout main && git pull
git checkout -b hotfix/1.1.1
# fix, commit
git push -u origin hotfix/1.1.1
```

Pushes build, test, and push a promotable image with the commit-derived label (`1.1.1-hotfix.<height>`) — no automatic stg deploy. When ready to verify on stg, dispatch manually (no inputs; the dispatch reuses the push build's image by digest and skips the rebuild):

**From the UI:** Actions → **CI/CD — Hotfix → STG** → Run workflow → select the hotfix branch (the **Use workflow from** selector defaults to `develop` — same trap as the release dispatch; the pipeline fails fast if the branch isn't `hotfix/*`)

**From the command line:**
```sh
gh workflow run on-hotfix.yml --ref hotfix/1.1.1
```

When verified, PR `hotfix/1.1.1 → main` (merge commit). Merging triggers **CI/CD — Main → PROD**, which auto-detects `1.1.1` from the merge commit subject, checks the `build/stg/*` gate, promotes the stg-tested image by digest, runs the gated rollout, creates GitHub Release `v1.1.1`, and raises a **cherry-pick backport PR** to `develop`: because hotfix branches are cut from `main` (not `develop`), their history is never merged into `develop` directly — the `backmerge` job cherry-picks the merge commit's combined diff (`-m 1`) onto a `backport/1.1.1` branch and opens the PR from that. If the cherry-pick hits conflicts, the job fails with the exact manual commands to run; if `develop` already contains the change, it skips gracefully.

Re-dispatching on the same commit redeploys the same image; a new candidate label requires a new commit (the height advances with each fix) — same rules as the release flow.

## Maintain a support branch

Use a `support/X.Y.Z` branch to backport fixes to a prior production version while a newer release is in progress on `develop`. Cut from `main` at the relevant version tag:

```sh
git checkout -b support/1.4.1 v1.4.0
git push -u origin support/1.4.1
```

`on-support.yml` and `on-hotfix.yml` are thin wrappers over the same reusable pipeline (`_hotfix-support.yml`), differing only in branch type and label suffix (`-patch.<height>` rather than `-hotfix.<height>`): pushes build and test only, deploys to stg on manual dispatch, and merging to `main` triggers full prod promotion, a GitHub Release `v1.4.1`, and the same **cherry-pick backport PR** to `develop` as a hotfix. Conflicts are more likely here than for hotfixes — `develop` has usually drifted far from the old supported version — so expect to finish some backports manually using the commands from the failed job's log.

```sh
gh workflow run on-support.yml --ref support/1.4.1
gh pr create --base main --head support/1.4.1 --title "Support 1.4.1"
gh pr merge --merge
```

> **Note:** the `support/*` source branch must be enabled in the GitHub ruleset for `main` (Settings → Rules → the `main` ruleset → bypass/source branch list). See the repository settings section below.

## Roll back production

**Immediate rollback (any retained revision).** Cloud Run keeps prior revisions, so rollback is a traffic change — no rebuild, no redeploy, effective in seconds:

```sh
# See what exists and what's serving
gcloud run revisions list --service <SERVICE_NAME> \
  --region <GCP_REGION> --project <GCP_PROJECT_ID>

# Send all traffic back to a known-good revision
gcloud run services update-traffic <SERVICE_NAME> \
  --region <GCP_REGION> --project <GCP_PROJECT_ID> \
  --to-revisions <good-revision>=100
```

This is the manual equivalent of what the pipeline does automatically when a post-shift smoke test fails. It is strictly wider than the Azure slot swap it replaces: a swap could only reach the *one* previous build, whereas any retained revision is one command away.

**Rollback to any previously released version (through the pipeline).** Dispatch `on-main.yml` with the target version:

```sh
gh workflow run on-main.yml --ref main -f version=1.5.0
```

**From the UI:** Actions → **CI/CD — Main → PROD** → Run workflow → enter the version (e.g. `1.5.0`). The input must be a released version in bare `X.Y.Z` form — anything else is rejected before a build starts. The pipeline then:

1. Resolves the `v1.5.0` tag to its merge commit
2. Walks to that commit's **second parent** (`.parents[1]`) — the release branch head
3. Confirms a `build/stg/*` tag points at it (the same gate as a normal promotion — rollbacks are not exempt)
4. Finds that commit's image **digest** via its `sha-<commit>` tag
5. Promotes it through the **same gated rollout** as any other prod deploy: cold revision, candidate smoke test, traffic shift, post-shift smoke test, automatic traffic return on failure

The `build/prod/<version>` tag already points at the release commit that produced the image, so tagging is a no-op. No new GitHub Release is created — only push-triggered runs create releases.

Because the promoted identity is a digest, **there is no retention window to miss.** The rollback fails only if the image was never built for that commit or has since been deleted from Artifact Registry — in which case the error says exactly that, and tells you to re-dispatch the release pipeline from the source branch.

**For dev/stg:** the same `update-traffic` command works, or re-run an earlier successful workflow run.

## Verify a deployment

- **Run summary** — every deploy run's summary shows a "🚀 Deployed" card with the app, Swagger, and API URLs, plus the fully qualified **image reference pinned by digest** that was deployed. The build job's summary shows the label, digest, and reference of the image it pushed.
- **Swagger** — `<app-url>/swagger` shows the exact build label, linked commit SHA, and environment of what's running.
- **Smoke test** — already ran automatically; a green deploy job means the app answered correctly *and* reported the expected build.
- **Cloud Run** — `gcloud run services describe <SERVICE_NAME> --region <region> --project <project>` shows the serving revision, its image digest, and the `build-label` label applied at deploy time.
- **Deployments view** — repo home → right sidebar → **Deployments** (or `/deployments`): per-environment history.
- **Tags** — `git fetch --tags && git tag -l 'build/*'`: every successful **stg/prod** deploy tags the exact commit as `build/stg/<label>` or `build/prod/<label>` — the audit trail of what QA/UAT tested and what shipped. Dev deploys are not tagged.
- **Releases** — repo **Releases** page lists `vX.Y.Z` with generated notes.

## Version and branch naming

| Thing | Convention | Example |
|---|---|---|
| Release branch | bare version | `release/1.1.0` |
| Milestone branch | bare name | `milestone/beta` |
| Hotfix branch | bare patch version | `hotfix/1.1.1` |
| Support branch | bare patch version | `support/1.1.1` |
| Dev label | `YYYYMMDD` + run number | `20260703.32` |
| Release candidate label | version + `-build.` + height | `1.1.0-build.187` |
| Milestone label | `ms-` + name + `.` + height | `ms-beta.204` |
| Hotfix label | version + `-hotfix.` + height | `1.1.1-hotfix.42` |
| Support label | version + `-patch.` + height | `1.4.1-patch.51` |
| Release / hotfix / support tag (automatic on prod deploy) | `v` + version | `v1.1.0` |

**Height** is `git rev-list --count HEAD` — which is why the release-family pipelines check out with `fetch-depth: 0` (a shallow clone would report height 1), using a treeless partial clone (`filter: tree:0`) to keep that cheap as history grows.

The candidate label identifies a *build of one commit* — it is derived, never typed, so the same commit always carries the same label and each new commit mints the next candidate. The branch identifies the *line of development*; candidate suffixes never appear in branch names. Labels become image tags and git tags, so they are validated against `[0-9A-Za-z.-]+`; a branch name that derives anything outside that charset fails the run.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Run fails instantly with `startup_failure` and no logs | A caller job is missing the `permissions:` block the reusable workflow requires (`id-token: write` for any build that pushes an image and for every deploy; plus `contents: write`, `checks: write`, `pull-requests: write` as applicable) — the repo default token is read-only and called workflows cannot elevate it |
| Deploy fails: service not found | The Cloud Run service hasn't been provisioned in that project/region, or `SERVICE_NAME` / `GCP_REGION` / `GCP_PROJECT_ID` are wrong for that environment |
| Deploy or build fails at "Authenticate to Google Cloud" | Workload Identity Federation problem — the provider's attribute condition didn't match the job's `sub` claim, or the service account doesn't allow impersonation from that principal. See `docs/workload-identity-federation.md`, and run the **Show OIDC Token Claims** workflow to see the exact subject a job presents (`repo:<owner>/<repo>:environment:<env>`) |
| Deploy fails with a permission error on `gcloud run deploy` | The environment's `DEPLOY_SERVICE_ACCOUNT` lacks Cloud Run admin rights, or lacks `iam.serviceAccounts.actAs` on the `RUNTIME_SERVICE_ACCOUNT` it is being asked to assign |
| Build fails at "Build and push image" with a denied push | The repo-level `BUILD_SERVICE_ACCOUNT` lacks writer on the Artifact Registry repository, or `AR_LOCATION` / `AR_PROJECT_ID` / `AR_REPOSITORY` don't name a repository that exists |
| Push to `develop`/`main` rejected (GH013) | Rulesets require a PR — open one instead of pushing directly |
| Release merged but prod run fails: "Could not parse a release/hotfix/support branch from the merge commit subject" | The PR was squash-merged or the merge message was customized, hiding the branch name — the run refuses to fall back to an untested rebuild. Redeploy by dispatching **CI/CD — Main → PROD** with the version, and keep the default merge message next time (main's ruleset blocks squash, so a customized message is the usual cause) |
| Prod run fails: "does not resolve to a merge commit, so its stg-tested image cannot be located" | The PR was squash-merged, so there is no second parent identifying the release commit. Nothing to promote — re-dispatch the source branch's pipeline |
| Prod run fails: "No `build/stg/*` tag points at …" | **The staging gate.** The image was built, but its stg deploy never went green (smoke test failed, deploy errored, or the dispatch was never run). "Image exists" is not "staging tested it". Dispatch the release/hotfix/support pipeline on the source branch, let the stg deploy pass, then re-run the prod run |
| Prod run fails: "No image tagged `sha-…`" | The candidate was never built for that commit, or an Artifact Registry cleanup policy deleted the image. **This is not an expiry** — digests don't lapse. Dispatch the source branch's pipeline to rebuild, verify staging, then re-run |
| Prod dispatch rejected: "Main → PROD dispatches must run from main" | The **Use workflow from** selector was left on another branch. Dispatches must run from `main`; the prod environment's deployment branch policy enforces this independently |
| Prod dispatch rejected: "No version given" | A dispatch must either name a released version (rollback) or explicitly set `rebuild-from-source: true`. An empty version alone is refused, so "redeploy untested main" can never happen by accident |
| Prod dispatch rejected: "is not a released version number" | The `version` input must be bare `X.Y.Z` (no `v`, no suffix) — it is used to resolve the `v<version>` tag |
| Prod deploy failed at "Smoke test candidate revision" | The new build is unhealthy — **production was not touched.** The candidate took no traffic and the shift never happened. Fix forward and redeploy; there is nothing to roll back |
| Prod deploy failed at "Smoke test deployment" (after the shift) | Traffic moved but the service stopped answering correctly — the pipeline **returned traffic to the previously serving revision automatically.** Production is running the prior version. Investigate the bad build before redeploying |
| Prod deploy failed *and* traffic was not returned | Either the failure was pre-shift (nothing to return), or this was the service's first-ever deploy and no previous serving revision was recorded. Check the "Record currently serving revision" step's output |
| Deploy fails: "Could not resolve the tagged candidate URL" | The `--no-traffic --tag` deploy reported success but the tag isn't in `status.traffic` — usually the service hit **Cloud Run's per-service tag cap** because earlier `cand-*` tags were left behind. Inspect with `gcloud run services describe … --format=json` and remove strays via `gcloud run services update-traffic … --remove-tags cand-<id>` |
| Smoke test fails: "reports version 'X', expected 'Y'" | The app answers but is running the wrong build — the deploy or traffic shift didn't take effect, or the wrong image shipped. Check which run last deployed to that environment and which revision is serving; redeploy the intended digest |
| Smoke test fails against a service that is demonstrably healthy | The runner can't reach it. The default `ubuntu-latest` runner is fine for public ingress, but a service on **internal ingress** needs either a `GATEWAY_URL` for that environment or the `runner` input pointed at a self-hosted runner inside the network |
| Deploy fails at "Tag deployment": "Deployment tags are immutable" | The `build/<env>/<label>` tag already points at different code — two commits derived the same label (e.g. a release branch re-cut at the same commit height). Push another commit to advance the height, or delete the stale tag if its run is confirmed dead |
| Deploy failed at "Smoke test deployment" (dev/stg) | Direct deploys take traffic immediately, so the previous build is already out of service — fix forward, or use `gcloud run services update-traffic` to return to the last good revision |
| Deploy run sits in "Queued" | Concurrency groups serialize deploys per environment (`deploy-dev`, `deploy-stg`, `deploy-prod`) — the run starts when the in-flight deploy to that environment finishes. Release, hotfix, and support dispatches **share** `deploy-stg`; pushes queue per branch (`build-<ref>`) instead, so they don't block each other |
| A job after a *skipped* job never runs | GitHub implicitly wraps `if` conditions in `success()`, which is false when **any ancestor job was skipped** — and the promotion path skips `build` by design. Downstream jobs must use `!failure() && !cancelled()` explicitly (deploy and release already do; copy that pattern for new jobs) |
| Back-merge PR wasn't created after a release | Check the `backmerge` job's log. If it says "not permitted to create pull requests", re-enable **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests** |
| Backport PR wasn't created after a hotfix/support merge | The cherry-pick onto `develop` hit conflicts — the `backmerge` job log contains the exact manual commands (`git cherry-pick -m 1 <merge-sha>` onto a `backport/<version>` branch); resolve and open the PR by hand |
| Dispatch fails at "Derive version from the commit" | The workflow was dispatched from the wrong branch (the **Use workflow from** selector defaults to `develop`), or the branch name derives a label with characters outside letters/digits/`.`/`-`. Select the right branch, or rename it |
| Dispatch rebuilds instead of reusing the push image | No image is tagged `sha-<commit>` (the push build failed or never ran, or a cleanup policy removed it), or the image carries no label tag alongside its `sha-` tag. A fresh build is the correct fallback — same commit, same derived label, so the new image is interchangeable and usable for prod promotion |
| Dispatch log shows "label derivation changed since the push build" | The label-derivation logic was edited between the push and the dispatch. The pipeline deploys the binary under the label it was actually stamped with (the stamp is compiled in); push a new commit to adopt the new derivation |
| Dev redeploy fails: "No 'CI/CD — Develop → DEV' run matches label" | The label doesn't correspond to a real run of that workflow. Check it against the Actions run history — and remember the dev path rebuilds HEAD under that label rather than promoting an old image |

## Repository settings the pipeline depends on

These live in GitHub settings, not in the workflow files — if the repo is ever recreated or transferred, they must be reconfigured:

| Setting | Where | Value |
|---|---|---|
| Rulesets `develop` / `main` / `release` | Settings → Rules | PR required; **build / Build & Test** status check required; `main` allows merge commits only; `main` source branches must include `support/*` |
| Workflow permissions | Settings → Actions → General | Default token: **read-only**; **Allow GitHub Actions to create and approve pull requests: on** (the back-merge and backport PRs need it) |
| Repo variables | Settings → Secrets and variables → Actions | `WIF_PROVIDER`, `BUILD_SERVICE_ACCOUNT`, `AR_LOCATION`, `AR_PROJECT_ID`, `AR_REPOSITORY`, `IMAGE_NAME` — the same for every environment, so they live at repo level |
| Environment variables | Settings → Environments → (each env) → Environment variables | `DEPLOY_SERVICE_ACCOUNT`, `GCP_PROJECT_ID`, `GCP_REGION`, `SERVICE_NAME` per environment, plus optional `RUNTIME_SERVICE_ACCOUNT` and `GATEWAY_URL`. `_deploy.yml` reads them via the job's `environment:` scope, so entry workflows carry no per-env config |
| Environments | Settings → Environments | `dev`, `stg`, `prod` — each matched by the WIF provider's attribute condition on the `sub` claim |
| Prod protection | Settings → Environments → prod | **Required reviewer** (deploy approval gate) and **deployment branch policy: `main` only** — the platform-level enforcement that a "Main → PROD" dispatch from any other ref (e.g. an unmerged `release/*` branch) is refused at the deploy job, regardless of workflow logic. The `Validate dispatch` step in `on-main.yml` is the fast, explanatory layer in front of it |

There are deliberately **no repository secrets** — Google Cloud auth is OIDC Workload Identity Federation, with no exported service-account keys anywhere. See `docs/workload-identity-federation.md`, and run the **Show OIDC Token Claims** workflow to inspect what GitHub actually asserts about a job.

## Infrastructure changes

All Google Cloud resources (Cloud Run services, the Artifact Registry repository, the Workload Identity Pool and provider, the build and per-environment deploy service accounts and their IAM bindings) are Terraform-managed in the platform infrastructure repository — change infrastructure there via plan/apply, never in the Cloud Console. This repo contains no IaC; the resources the pipeline requires are listed in [getting-started.md](getting-started.md).
