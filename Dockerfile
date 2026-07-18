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

# Run non-root. Cloud Run does not require it, but the container should not
# depend on running privileged to work elsewhere.
#
# The .NET runtime images already ship a non-root `app` user (uid 1654), so
# there is nothing to create — adding one fails with "user 'app' in use".
USER app
WORKDIR /app

COPY --chown=app:app ./publish .

# Cloud Run's container contract is that the app listens on $PORT, which it
# injects (8080 unless the service overrides it). _deploy.yml pins --port 8080,
# so the two agree today — but honouring $PORT rather than hardcoding keeps the
# image correct if anyone changes the service port, instead of leaving a
# container that starts cleanly and then serves nothing on the expected port.
#
# Shell form is required for the ${PORT:-8080} expansion; `exec` hands PID 1 to
# dotnet so SIGTERM reaches it and shutdown stays graceful.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

ENTRYPOINT ["sh", "-c", "ASPNETCORE_HTTP_PORTS=${PORT:-8080} exec dotnet Api.dll"]
