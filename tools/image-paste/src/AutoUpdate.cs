using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

namespace ImagePaste;

internal static class AutoUpdate
{
    internal const string Executable = "TianCai图片直粘.exe";
    private const long Limit = 256L * 1024 * 1024;
    internal record Plan(string Target, int ParentId, long ParentStart, int GuardId, long GuardStart, string Hash, string Token);

    internal static async Task<string> PrepareAsync(AvailableRelease release, IProgress<int> progress, CancellationToken token)
    {
        string target = Environment.ProcessPath!;
        // The helper is a copy of this executable; framework-dependent builds need other files.
#pragma warning disable IL3000
        if (!string.IsNullOrEmpty(typeof(AutoUpdate).Assembly.Location))
            throw new InvalidOperationException("自动更新仅支持官方单文件发布版。");
#pragma warning restore IL3000
        string stage = Path.Combine(Path.GetDirectoryName(target)!, ".tiancai-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage); // Check directory write access before downloading or exiting.
        try
        {
            string asset = $"image-paste-{release.Version}-win-x64.zip";
            string baseUrl = $"https://github.com/luck-caicai/TianCaiTools/releases/download/image-paste%2Fv{release.Version}/";
            using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            client.DefaultRequestHeaders.UserAgent.ParseAdd($"TianCaiImagePaste/{UpdateChecker.CurrentVersion}");
            string checksum = Path.Combine(stage, "checksum");
            await Download(client, baseUrl + asset + ".sha256", checksum, 1024, null, token);
            string zip = Path.Combine(stage, "package.zip");
            await Download(client, baseUrl + asset, zip, Limit, progress, token);
            string text = await File.ReadAllTextAsync(checksum, token);
            await Task.Run(() => ExtractVerified(zip, text, asset, Path.Combine(stage, "new.exe")), token);
            var info = FileVersionInfo.GetVersionInfo(Path.Combine(stage, "new.exe"));
            if (new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart) != release.Version)
                throw new InvalidDataException("安装包中的程序版本不匹配。");
            File.Copy(target, Path.Combine(stage, "helper.exe"));
            File.Delete(zip);
            File.Delete(checksum);
            return stage;
        }
        catch { Cleanup(stage); throw; }
    }

    private static async Task Download(HttpClient client, string url, string path, long limit, IProgress<int>? progress, CancellationToken token)
    {
        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        var source = response.RequestMessage!.RequestUri!;
        if (source.Scheme != "https" || source.Host is not ("github.com" or "release-assets.githubusercontent.com" or "objects.githubusercontent.com"))
            throw new InvalidDataException("下载来源不受信任。");
        long? length = response.Content.Headers.ContentLength;
        if (length > limit) throw new InvalidDataException("安装包过大。");
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true);
        using var input = await response.Content.ReadAsStreamAsync(token);
        byte[] buffer = new byte[81920];
        long total = 0;
        int last = -1;
        int count;
        while ((count = await input.ReadAsync(buffer, token)) > 0)
        {
            total += count;
            if (total > limit) throw new InvalidDataException("安装包过大。");
            await output.WriteAsync(buffer.AsMemory(0, count), token);
            int percent = length > 0 ? (int)Math.Min(100, total * 100 / length.Value) : 0;
            if (percent != last) { progress?.Report(percent); last = percent; }
        }
        if (length.HasValue && total != length) throw new InvalidDataException("下载不完整。");
    }

    internal static void ExtractVerified(string zip, string checksum, string asset, string destination)
    {
        string[] parts = checksum.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 2 || parts[1] != asset || parts[0].Length != 64 || !parts[0].All(Uri.IsHexDigit)
            || !Hash(zip).Equals(parts[0], StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("安装包校验失败，请重试。");
        using var archive = ZipFile.OpenRead(zip);
        if (archive.Entries.Count(e => e.FullName == Executable) != 1
            || archive.Entries.Any(e => e.FullName != Executable && e.FullName != "使用说明.md"))
            throw new InvalidDataException("安装包结构不受支持。");
        var entry = archive.GetEntry(Executable)!;
        if (entry.Length < 1 || entry.Length > Limit) throw new InvalidDataException("程序大小异常。");
        entry.ExtractToFile(destination, false);
    }

    internal static string Hash(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    internal static void StartHelper(string stage, int guardId, long guardStart)
    {
        using var parent = Process.GetCurrentProcess();
        string token = "Local\\TianCai.ImagePaste.Update." + Guid.NewGuid().ToString("N");
        var plan = new Plan(Environment.ProcessPath!, parent.Id, parent.StartTime.ToUniversalTime().Ticks,
            guardId, guardStart, Hash(Path.Combine(stage, "new.exe")), token);
        File.WriteAllText(Path.Combine(stage, "plan.json"), JsonSerializer.Serialize(plan));
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, token);
        using var helper = Start(Path.Combine(stage, "helper.exe"), "--apply-update", stage);
        if (!ready.WaitOne(15000))
        {
            if (!helper.HasExited) { helper.Kill(); helper.WaitForExit(); }
            throw new TimeoutException("更新助手未就绪，旧程序继续运行。");
        }
    }

    internal static int RunHelper(string stage, Action<string>? reportFailure = null)
    {
        bool parentExited = false;
        Plan? plan = null;
        try
        {
            plan = JsonSerializer.Deserialize<Plan>(File.ReadAllText(Path.Combine(stage, "plan.json")))!;
            stage = Path.GetFullPath(stage);
            if (Path.GetFileName(plan.Target) != Executable
                || !string.Equals(Path.GetDirectoryName(stage), Path.GetDirectoryName(Path.GetFullPath(plan.Target)), StringComparison.OrdinalIgnoreCase)
                || !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(stage), @"\A\.tiancai-update-[a-f0-9]{32}\z"))
                throw new InvalidDataException("更新路径异常。");
            using var parent = OpenProcess(plan.ParentId, plan.ParentStart);
            using var guard = OpenProcess(plan.GuardId, plan.GuardStart);
            using (var ready = EventWaitHandle.OpenExisting(plan.Token)) ready.Set();
            if (parent != null && !parent.WaitForExit(120000)) throw new TimeoutException("旧程序仍在运行，已取消替换。");
            parentExited = true;
            if (guard != null && !guard.WaitForExit(30000)) throw new TimeoutException("光标恢复进程尚未退出，已取消替换。");
            string payload = Path.Combine(stage, "new.exe");
            if (Hash(payload) != plan.Hash) throw new InvalidDataException("待安装文件发生变化。");
            Install(payload, plan.Target, () =>
            {
                using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, plan.Token + ".started");
                using var child = Start(plan.Target, "--updated", plan.Token + ".started", stage);
                if (!ready.WaitOne(30000))
                {
                    // Only terminate the new main process; its guard restores the cursor itself.
                    if (!child.HasExited) { child.Kill(); child.WaitForExit(5000); }
                    throw new InvalidOperationException("新版启动未确认。");
                }
            });
            return 0;
        }
        catch (Exception ex)
        {
            AppLog.Write(ex);
            if (parentExited && plan != null)
            {
                try { using var restarted = Start(plan.Target); }
                catch (Exception restartError) { AppLog.Write(restartError); }
            }
            string message = "更新未完成：" + ex.Message + "\n请重试；如仍无法启动，可从发布页重新下载。";
            if (reportFailure != null) reportFailure(message);
            else MessageBox.Show(message, "更新失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }

    internal static void Install(string payload, string target, Action launch)
    {
        string backup = target + ".previous";
        Retry(() => File.Replace(payload, target, backup));
        try { launch(); }
        catch
        {
            Retry(() => File.Replace(backup, target, null));
            throw;
        }
    }

    private static void Retry(Action action)
    {
        for (int attempt = 0; ; attempt++)
        {
            try { action(); return; }
            catch (IOException) when (attempt < 40) { Thread.Sleep(250); }
        }
    }

    private static Process? OpenProcess(int id, long start)
    {
        try
        {
            var process = Process.GetProcessById(id);
            if (process.StartTime.ToUniversalTime().Ticks == start) return process;
            process.Dispose();
        }
        catch (ArgumentException) { }
        return null;
    }

    private static Process Start(string path, params string[] args)
    {
        var info = new ProcessStartInfo(path) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden, WorkingDirectory = Path.GetDirectoryName(path)! };
        foreach (string arg in args) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new InvalidOperationException("无法启动程序。");
    }

    internal static void Cleanup(string stage)
    {
        // Delete only our known files, never recursively delete a supplied directory.
        foreach (string name in new[] { "new.exe", "helper.exe", "plan.json", "package.zip", "checksum" })
        {
            try { File.Delete(Path.Combine(stage, name)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        try { Directory.Delete(stage); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
