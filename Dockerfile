# Packaging-only image.
#
# This Dockerfile deliberately does NOT build the application. CI has already
# restored, built, tested, and published it, stamping the build label into
# InformationalVersion — and the smoke test after every deploy asserts that the
# running app reports that exact label. Rebuilding here would produce a
# different binary from the one the tests passed against and silently break
# that guarantee.
#
# The tradeoff is that `docker build .` on a clean checkout will fail: it needs
# ./publish to exist. That is intentional. To build locally, run:
#
#   dotnet publish Api/Api.csproj -c Release -o ./publish
#   docker build -t cicd-demo .
#
FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine

# Non-root by default. Cloud Run does not require it, but the container should
# not depend on running privileged to work elsewhere.
RUN adduser --disabled-password --gecos '' --uid 64198 app
USER app
WORKDIR /app

COPY --chown=app:app ./publish .

# Cloud Run injects PORT and defaults it to 8080; the Cloud Run service in
# _deploy.yml is configured for 8080 to match. Kept explicit rather than
# inherited so the image behaves the same when run locally.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "Api.dll"]
