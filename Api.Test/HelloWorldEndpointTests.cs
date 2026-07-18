using Microsoft.AspNetCore.Mvc.Testing;

namespace Api.Test;

public class HelloWorldEndpointTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HelloWorldEndpointTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task Root_ReturnsHelloWorld()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/");

        response.EnsureSuccessStatusCode();
        Assert.Equal("Hello World!", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Healthz_ReportsHealthy()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/healthz");

        response.EnsureSuccessStatusCode();
        Assert.Equal("Healthy", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task V1Hello_ReturnsHelloWorld()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/v1/hello");

        response.EnsureSuccessStatusCode();
        Assert.Equal("Hello World!", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task OpenApiSpec_IsServed()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/openapi/v1.json");

        response.EnsureSuccessStatusCode();
        var spec = await response.Content.ReadAsStringAsync();
        // Version token substituted to a literal path, doc stamped with build info.
        Assert.Contains("/v1/hello", spec);
        Assert.Contains("cicd-demo API", spec);
        Assert.Contains("Deployed build:", spec);
    }

    [Fact]
    public async Task SwaggerUi_IsServed()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/swagger/index.html");

        response.EnsureSuccessStatusCode();
        Assert.Contains("swagger-ui", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task OpenApiSpec_OmitsServers_SoTryItOutStaysSameOrigin()
    {
        var client = _factory.CreateClient();

        var spec = await client.GetStringAsync("/openapi/v1.json");

        // With no servers entry, Swagger UI resolves calls against the URL the
        // document was fetched from — correct both directly and behind the
        // gateway's path prefix.
        Assert.DoesNotContain("\"servers\"", spec);
    }

    [Fact]
    public async Task PathBase_PrefixedRequests_AreServed()
    {
        var client = PathBasedFactory().CreateClient();

        var response = await client.GetAsync("/cicd-demo/v1/hello");

        response.EnsureSuccessStatusCode();
        Assert.Equal("Hello World!", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task PathBase_UnprefixedRequests_StillServed()
    {
        // UsePathBase must be tolerant: direct traffic (run.app,
        // custom domains, the pipeline's smoke tests) carries no prefix.
        var client = PathBasedFactory().CreateClient();

        var response = await client.GetAsync("/v1/hello");

        response.EnsureSuccessStatusCode();
        Assert.Equal("Hello World!", await response.Content.ReadAsStringAsync());
    }

    private WebApplicationFactory<Program> PathBasedFactory() =>
        _factory.WithWebHostBuilder(builder =>
            builder.UseSetting("PATH_BASE", "/cicd-demo"));
}
