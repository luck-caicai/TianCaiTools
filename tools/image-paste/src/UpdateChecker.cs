using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ImagePaste;

internal record AvailableRelease(Version Version, string PageUrl);

internal static class UpdateChecker
{
    private const string Repository = "luck-caicai/TianCaiTools";
    internal static Version CurrentVersion
    {
        get
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version!;
            return new(version.Major, version.Minor, version.Build);
        }
    }

    internal static async Task<AvailableRelease?> CheckAsync(CancellationToken cancellationToken)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"TianCaiImagePaste/{CurrentVersion}");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        AvailableRelease? latest = null;
        for (int page = 1; page <= 100; page++)
        {
            using var response = await client.GetAsync($"https://api.github.com/repos/{Repository}/releases?per_page=100&page={page}", cancellationToken).ConfigureAwait(false);
            if ((int)response.StatusCode is 403 or 429)
                throw new HttpRequestException("GitHub 请求暂时受限，请稍后再试。");
            response.EnsureSuccessStatusCode();
            string json = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            latest = SelectLatest(json, latest);
            bool more = response.Headers.TryGetValues("Link", out var links) && links.Any(link => link.Contains("rel=\"next\"", StringComparison.Ordinal));
            if (!more) return latest;
        }
        throw new HttpRequestException("发布记录过多，未能完成检查，请前往 GitHub 查看。");
    }

    internal static AvailableRelease? SelectLatest(string json, AvailableRelease? latest = null)
    {
        using var document = JsonDocument.Parse(json);
        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) continue;
            string tag = release.GetProperty("tag_name").GetString() ?? "";
            var match = Regex.Match(tag, @"\Aimage-paste/v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z");
            if (!match.Success || !Version.TryParse(tag[13..], out var version)) continue;
            string expected = $"image-paste-{version}-win-x64.zip";
            bool hasPackage = release.GetProperty("assets").EnumerateArray().Any(asset =>
                asset.GetProperty("name").GetString() == expected && asset.GetProperty("state").GetString() == "uploaded"
                && asset.GetProperty("size").GetInt64() > 0);
            if (hasPackage && (latest == null || version > latest.Version))
                latest = new(version, $"https://github.com/{Repository}/releases/tag/{Uri.EscapeDataString(tag)}");
        }
        return latest;
    }
}
