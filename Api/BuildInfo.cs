/// <summary>
/// Turns the version metadata CI stamps into the assembly (see _build.yml
/// and Api.csproj) into the fragments the Swagger description displays.
/// Pure so the rendering branches are unit-testable — the assembly
/// attributes themselves are fixed at compile time.
/// </summary>
public static class BuildInfo
{
    /// <summary>
    /// Splits an InformationalVersion of the form "&lt;label&gt;+&lt;sha&gt;"
    /// (the SDK appends the commit SHA as SemVer build metadata) into the
    /// display label and the SHA; the SHA is null when no "+" is present.
    /// </summary>
    public static (string Label, string? CommitSha) Split(string? informationalVersion)
    {
        if (string.IsNullOrEmpty(informationalVersion))
        {
            return ("unknown", null);
        }
        var labelAndSha = informationalVersion.Split('+', 2);
        return (labelAndSha[0], labelAndSha.Length > 1 ? labelAndSha[1] : null);
    }

    /// <summary>
    /// Renders the " — commit: …" fragment: empty without a SHA, a plain
    /// backticked short SHA without a repository URL (local builds), and a
    /// markdown link to the commit when both are present. An empty or
    /// trailing-slashed URL is tolerated even though the csproj condition
    /// shouldn't produce one.
    /// </summary>
    public static string CommitNote(string? commitSha, string? repositoryUrl)
    {
        if (string.IsNullOrEmpty(commitSha))
        {
            return "";
        }
        var shortSha = commitSha[..Math.Min(8, commitSha.Length)];
        return string.IsNullOrEmpty(repositoryUrl)
            ? $" — commit: `{shortSha}`"
            : $" — commit: [`{shortSha}`]({repositoryUrl.TrimEnd('/')}/commit/{commitSha})";
    }
}
