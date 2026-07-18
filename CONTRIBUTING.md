# Contributing

Thanks for your interest in improving this template. Because the repository's product *is* its pipeline, contributions are held to the same bar the pipeline enforces for application code.

## Getting set up

```sh
git clone https://github.com/avlon-technologies/template-gcp-cicd.git
cd template-gcp-cicd
dotnet test                  # build + run the integration tests
dotnet run --project Api     # http://localhost:5018/swagger
```

No Google Cloud resources are needed to work on the app or tests. Workflow changes can be validated with a YAML linter locally, but deploy paths only truly exercise on a configured fork (see [getting-started](docs/getting-started.md)).

## Branch model and PRs

- Branch from `develop`; open PRs against `develop`. Direct pushes are blocked by ruleset.
- The **build / Build & Test** check (from `on-pr.yml`) must pass before merge.
- `main` only receives `release/*`, `hotfix/*`, and `support/*` branches, merged with **merge commits** (never squash — version detection reads the merge commit subject). Contributors normally never target `main`.

## Conventions to preserve

These are deliberate, load-bearing patterns — PRs that break them will be asked to change:

- **Actions pinned to commit SHAs** with a trailing `# vX.Y.Z` comment. When bumping, update the SHA and the comment together (Dependabot does both).
- **Workflow inputs pass to scripts via `env:`**, never interpolated directly into `run:` script bodies (shell/JS injection safety).
- **Least-privilege permissions:** the default token is read-only; every job declares exactly what it needs. Callers of reusable workflows must grant the union of what the called jobs request.
- **Jobs downstream of a skippable job** need explicit `if: ${{ !failure() && !cancelled() }}` — the implicit `success()` is false when any ancestor was skipped, and the prod promotion path skips `build` by design.
- **`public partial class Program { }`** at the end of `Api/Program.cs` stays — the integration tests need it.
- Docs live in `docs/` following the C4 structure; if you change pipeline behavior, update the [operations manual](docs/operations-manual.md) and the relevant C4 document in the same PR.

## Reporting issues

Open a GitHub issue with the failing workflow run link (if applicable), what you expected, and what happened. For suspected security problems, see [SECURITY.md](SECURITY.md) instead of opening a public issue.
