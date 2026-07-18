using System.Reflection;
using Asp.Versioning;

var builder = WebApplication.CreateBuilder(args);

// The CI build stamps its build label (e.g. 1.2.0, 1.2.0-rc.1, 20260703.5)
// into InformationalVersion; the SDK appends the commit SHA as SemVer build
// metadata ("+<sha>"). BuildInfo splits them: the label is the display
// version, the shortened SHA goes in the description — linked to the
// repository when CI stamped its URL in (see Api.csproj), plain otherwise
// (local builds).
var assembly = Assembly.GetExecutingAssembly();
var (buildLabel, commitSha) = BuildInfo.Split(assembly
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
    .InformationalVersion);
var repositoryUrl = assembly
    .GetCustomAttributes<AssemblyMetadataAttribute>()
    .FirstOrDefault(a => a.Key == "RepositoryUrl")?.Value;
var commitNote = BuildInfo.CommitNote(commitSha, repositoryUrl);

builder.Services
    .AddApiVersioning(options =>
    {
        options.DefaultApiVersion = new ApiVersion(1);
        options.ReportApiVersions = true;
        options.ApiVersionReader = ApiVersionReader.Combine(
            new UrlSegmentApiVersionReader(),
            new HeaderApiVersionReader("api-version")
        );
    })
    .AddApiExplorer(options =>
    {
        // Group name "v1" matches the default OpenAPI document name, and the
        // {version:apiVersion} route token is expanded to the literal segment.
        options.GroupNameFormat = "'v'V";
        options.SubstituteApiVersionInUrl = true;
    });

builder.Services.AddHealthChecks();

builder.Services.AddOpenApi(options =>
{
    options.AddDocumentTransformer((document, context, cancellationToken) =>
    {
        document.Info.Title = "cicd-demo API";
        document.Info.Version = buildLabel;
        document.Info.Description =
            $"Deployed build: **{buildLabel}**{commitNote} — environment: **{builder.Environment.EnvironmentName}**";

        // No servers entry: Swagger UI then resolves calls against the URL
        // the document was fetched from, which keeps "Try it out"
        // same-origin whether the doc was reached directly or through the
        // gateway's path prefix.
        document.Servers?.Clear();

        return Task.CompletedTask;
    });
});

var app = builder.Build();

// A path-prefixing reverse proxy or gateway can serve the API under a
// prefix it forwards as-is (PATH_BASE, e.g. /cicd-demo). UsePathBase strips
// the prefix when present and does nothing when absent, so direct traffic
// (*.run.app, custom domains, local dev) is unaffected.
var pathBase = app.Configuration["PATH_BASE"];
if (!string.IsNullOrEmpty(pathBase))
{
    app.UsePathBase(pathBase);
}

// Root stays unversioned and returns the plain greeting.
app.MapGet("/", () => "Hello World!").ExcludeFromDescription();

// Dedicated liveness probe, decoupled from the greeting endpoint — point
// platform/gateway health probes at "/healthz". Register dependency checks
// here (Key Vault, etc.) to have them reported as Degraded/Unhealthy.
app.MapHealthChecks("/healthz").ExcludeFromDescription();

// API endpoints are versioned by URL segment; breaking changes are published
// as a new version in this set while old versions keep serving from the same
// deployment.
var apiVersions = app.NewApiVersionSet()
    .HasApiVersion(new ApiVersion(1))
    .ReportApiVersions()
    .Build();

var api = app.MapGroup("/v{version:apiVersion}")
    .WithApiVersionSet(apiVersions);

// hello world endpoint
api.MapGet("/hello", () => "Hello World!")
    .WithName("HelloWorld")
    .WithSummary("Returns the hello-world greeting.")
    .MapToApiVersion(new ApiVersion(1));

// OpenAPI spec + Swagger UI are deliberately enabled in every environment,
// including prod (this is a demo API with no sensitive surface).
app.MapOpenApi(); // serves /openapi/v1.json
app.UseSwaggerUI(options =>
{
    // Relative to the UI's own URL (/swagger/), so the document fetch stays
    // under whatever path prefix the UI was reached through — an absolute
    // "/openapi/v1.json" would escape the gateway's PATH_BASE prefix.
    options.SwaggerEndpoint("../openapi/v1.json", "cicd-demo v1");
}); // serves /swagger

app.Run();

public partial class Program { }
