namespace Api.Test;

public class BuildInfoTests
{
    private const string Sha = "1866c50103ef1a4769ef7ee11b767ad5fb277361";

    [Fact]
    public void Split_LabelWithSha_SeparatesBoth()
    {
        var (label, commitSha) = BuildInfo.Split($"1.2.0-rc.1+{Sha}");

        Assert.Equal("1.2.0-rc.1", label);
        Assert.Equal(Sha, commitSha);
    }

    [Fact]
    public void Split_LabelWithoutSha_ReturnsNullSha()
    {
        var (label, commitSha) = BuildInfo.Split("20260703.5");

        Assert.Equal("20260703.5", label);
        Assert.Null(commitSha);
    }

    [Fact]
    public void Split_MissingVersion_FallsBackToUnknown()
    {
        var (label, commitSha) = BuildInfo.Split(null);

        Assert.Equal("unknown", label);
        Assert.Null(commitSha);
    }

    [Fact]
    public void CommitNote_WithRepositoryUrl_LinksShortShaToCommit()
    {
        var note = BuildInfo.CommitNote(Sha, "https://github.com/avlon-technologies/template-gcp-cicd");

        Assert.Equal(
            $" — commit: [`1866c501`](https://github.com/avlon-technologies/template-gcp-cicd/commit/{Sha})",
            note);
    }

    [Fact]
    public void CommitNote_WithoutRepositoryUrl_RendersPlainShortSha()
    {
        var note = BuildInfo.CommitNote(Sha, null);

        Assert.Equal(" — commit: `1866c501`", note);
        Assert.DoesNotContain("](", note);
    }

    [Fact]
    public void CommitNote_WithoutSha_IsEmpty()
    {
        Assert.Equal("", BuildInfo.CommitNote(null, "https://github.com/avlon-technologies/template-gcp-cicd"));
    }

    [Fact]
    public void CommitNote_TrailingSlashUrl_ProducesSingleSlashCommitPath()
    {
        var note = BuildInfo.CommitNote(Sha, "https://github.com/avlon-technologies/template-gcp-cicd/");

        Assert.Contains($"https://github.com/avlon-technologies/template-gcp-cicd/commit/{Sha}", note);
        Assert.DoesNotContain("//commit/", note);
    }

    [Fact]
    public void CommitNote_EmptyRepositoryUrl_RendersUnlinked()
    {
        // Api.csproj only stamps the attribute when the property is non-empty,
        // but an empty value must still not render a broken relative link.
        var note = BuildInfo.CommitNote(Sha, "");

        Assert.Equal(" — commit: `1866c501`", note);
    }

    [Fact]
    public void CommitNote_ShaShorterThanEightChars_IsNotTruncated()
    {
        Assert.Equal(" — commit: `abc123`", BuildInfo.CommitNote("abc123", null));
    }
}
