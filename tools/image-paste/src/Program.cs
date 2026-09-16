using System.Diagnostics;
using Microsoft.Win32;

namespace ImagePaste;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length == 2 && args[0] == "--update-probe")
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                var release = UpdateChecker.CheckAsync(timeout.Token).GetAwaiter().GetResult();
                File.WriteAllText(args[1], System.Text.Json.JsonSerializer.Serialize(new { current = UpdateChecker.CurrentVersion.ToString(), latest = release?.Version.ToString(), url = release?.PageUrl }));
            }
            catch (Exception ex) { File.WriteAllText(args[1], ex.ToString()); Environment.ExitCode = 1; }
            return;
        }
        if (args.Length == 4 && args[0] == "--cursor-guard")
        {
            Environment.ExitCode = BusyCursor.RunGuard(int.Parse(args[1]), long.Parse(args[2]), args[3]);
            return;
        }
        if (args.Length == 2 && args[0] == "--cursor-test")
        {
            Environment.ExitCode = CursorTests.Run(args[1]);
            return;
        }
        if (args.Length == 1 && args[0] == "--cursor-orphan-test")
        {
            var cursor = new BusyCursor();
            cursor.Begin();
            Environment.Exit(0); // Intentionally bypass Dispose to exercise the recovery process.
            return;
        }
        if (args.Length >= 2 && args[0] == "--shell-probe")
        {
            try { File.WriteAllText(args[1], System.Text.Json.JsonSerializer.Serialize(ShellFolder.InspectViews(), new System.Text.Json.JsonSerializerOptions { WriteIndented = true })); }
            catch (Exception ex) { File.WriteAllText(args[1], ex.ToString()); Environment.ExitCode = 1; }
            return;
        }
        if (args.Length >= 2 && args[0] == "--self-test")
        {
            Environment.ExitCode = SelfTests.Run(args[1]);
            return;
        }
        if (args.Length >= 2 && args[0] == "--diagnose")
        {
            var target = PasteTarget.Capture();
            string folder;
            try { folder = target == null ? "Not a focused shell file view" : ShellFolder.Resolve(target); }
            catch (Exception ex) { folder = ex.ToString(); }
            File.WriteAllText(args[1], System.Text.Json.JsonSerializer.Serialize(new { target, folder,
                foregroundClass = Native.ClassName(Native.GetForegroundWindow()), image = Native.HasImage(), files = Native.HasFiles() },
                new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Converters = { new IntPtrConverter() } }));
            return;
        }
        using var singleton = new Mutex(true, "Local\\ImagePaste.Tray.v1", out bool first);
        if (!first) { MessageBox.Show("TianCai图片直粘已经在运行，请查看系统托盘。", "TianCai图片直粘"); return; }
        Application.ThreadException += (_, e) => AppLog.Write(e.Exception);
        try { using var app = new TrayApp(); Application.Run(app); }
        catch (Exception ex) { AppLog.Write(ex); MessageBox.Show(ex.Message, "TianCai图片直粘启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}

internal sealed class IntPtrConverter : System.Text.Json.Serialization.JsonConverter<nint>
{
    public override nint Read(ref System.Text.Json.Utf8JsonReader reader, Type type, System.Text.Json.JsonSerializerOptions options) => (nint)reader.GetInt64();
    public override void Write(System.Text.Json.Utf8JsonWriter writer, nint value, System.Text.Json.JsonSerializerOptions options) => writer.WriteNumberValue(value.ToInt64());
}

internal static class AppLog
{
    internal static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ImagePaste");
    internal static void Write(Exception error)
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            string path = Path.Combine(DirectoryPath, "error.log");
            if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) File.Move(path, path + ".old", true);
            File.AppendAllText(path, $"{DateTime.Now:O} {error}\n");
        }
        catch { /* Logging must not prevent pasting or quitting. */ }
    }
}

internal sealed class TrayApp : ApplicationContext
{
    private readonly Control dispatcher = new();
    private readonly NotifyIcon tray;
    private readonly PasteHook hook;
    private readonly BusyCursor cursor;
    private readonly CancellationTokenSource updateCancellation = new();
    private readonly ToolStripMenuItem checkUpdate = new("检查更新");
    private bool busy, exiting;
    private string? lastImage;

    internal TrayApp()
    {
        _ = dispatcher.Handle;
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        var menu = new ContextMenuStrip();
        var enabled = new ToolStripMenuItem("启用TianCai图片直粘") { Checked = true, CheckOnClick = true };
        var startup = new ToolStripMenuItem("开机启动") { Checked = IsStartupEnabled() };
        menu.Items.Add(enabled);
        menu.Items.Add(startup);
        menu.Items.Add("打开最近保存的位置", null, (_, _) => OpenLast());
        menu.Items.Add("工具所在位置", null, (_, _) => OpenToolLocation());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(checkUpdate);
        checkUpdate.Click += async (_, _) => await CheckUpdateAsync();
        menu.Items.Add("使用说明", null, (_, _) => MessageBox.Show(
            "截图或复制图片后，在桌面或资源管理器文件列表中按 Ctrl + V，即可保存为 PNG。\n\n" +
            "其他软件、地址栏、搜索框和重命名中的粘贴保持原样。\n复制的内容已是文件时，由 Windows 正常粘贴。\n\n" +
            "仅支持有真实路径的文件夹。右键菜单粘贴、第三方文件管理器暂不支持。\n" +
            "剪贴板内容不会被修改。双击托盘图标可打开最近保存的位置。",
            $"TianCai图片直粘 {UpdateChecker.CurrentVersion}"));
        menu.Items.Add("退出", null, (_, _) => ExitThread());
        tray = new NotifyIcon { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application, Text = "TianCai图片直粘 · 已启用", ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (_, _) => OpenLast();
        cursor = new BusyCursor();
        hook = new PasteHook(request => dispatcher.BeginInvoke(new Action(() => Paste(request))));
        enabled.CheckedChanged += (_, _) => { hook.Enabled = enabled.Checked; tray.Text = enabled.Checked ? "TianCai图片直粘 · 已启用" : "TianCai图片直粘 · 已暂停"; };
        startup.Click += (_, _) =>
        {
            try
            {
                bool value = !IsStartupEnabled();
                using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
                if (value) key.SetValue("ImagePaste", $"\"{Environment.ProcessPath}\"");
                else key.DeleteValue("ImagePaste", false);
                startup.Checked = value;
            }
            catch (Exception ex) { Notify("开机启动设置失败", ex.Message, ToolTipIcon.Error); }
        };
        Notify("TianCai图片直粘已启动", "截图后在桌面或文件夹按 Ctrl + V，即可保存图片。", ToolTipIcon.Info);
    }

    private static bool IsStartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return string.Equals(key?.GetValue("ImagePaste") as string, $"\"{Environment.ProcessPath}\"", StringComparison.OrdinalIgnoreCase);
    }

    private async Task CheckUpdateAsync()
    {
        if (!checkUpdate.Enabled || exiting) return;
        checkUpdate.Enabled = false;
        checkUpdate.Text = "正在检查更新…";
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(updateCancellation.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        try
        {
            var release = await UpdateChecker.CheckAsync(timeout.Token);
            if (exiting) return;
            if (release == null)
                MessageBox.Show("暂未找到图片直粘的正式安装包，请稍后再试。", "检查更新");
            else if (release.Version <= UpdateChecker.CurrentVersion)
                MessageBox.Show($"当前版本：{UpdateChecker.CurrentVersion}\n暂无更新的正式版本。", "检查更新", MessageBoxButtons.OK, MessageBoxIcon.Information);
            else if (MessageBox.Show($"发现新版本：{release.Version}\n当前版本：{UpdateChecker.CurrentVersion}\n\n是否打开官方发布页面查看更新说明并下载？\n下载后请退出旧程序，再解压替换。", "发现更新", MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
                Process.Start(new ProcessStartInfo(release.PageUrl) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            if (exiting) return;
            AppLog.Write(ex);
            string reason = ex is OperationCanceledException ? "连接超时，请检查网络后重试。" : "无法完成更新检查，请检查网络或稍后重试。";
            MessageBox.Show(reason + "\n图片粘贴功能不受影响。", "检查更新失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            if (!exiting) { checkUpdate.Text = "检查更新"; checkUpdate.Enabled = true; }
        }
    }

    private async void Paste(PasteRequest request)
    {
        if (exiting) return;
        if (busy) return;
        busy = true;
        try
        {
            cursor.Begin();
            string folder = ShellFolder.Resolve(request);
            using var snapshot = await ClipboardImage.CaptureAsync(request.ClipboardVersion);
            // Snapshot and destination are fixed before expensive encoding or network I/O.
            string path = await Task.Run(() =>
            {
                byte[] png = ClipboardImage.Encode(snapshot);
                return ImageFile.Save(folder, png);
            });
            lastImage = path;
            Native.SHChangeNotify(0x2, 0x2005, path, 0); // SHCNE_CREATE, SHCNF_PATHW | FLUSHNOWAIT
            if (!exiting) tray.Text = hook.Enabled ? "TianCai图片直粘 · 已保存 " + DateTime.Now.ToString("HH:mm:ss") : "TianCai图片直粘 · 已暂停";
        }
        catch (Exception ex)
        {
            AppLog.Write(ex);
            string message = ex is UnauthorizedAccessException ? "没有写入这个文件夹的权限，请选择其他文件夹。" : ex.Message;
            Notify("图片未保存", message, ToolTipIcon.Warning);
        }
        finally { cursor.End(); busy = false; if (exiting) base.ExitThreadCore(); }
    }

    private void Notify(string title, string text, ToolTipIcon icon)
    {
        if (!exiting) tray.ShowBalloonTip(2500, title, text, icon);
    }
    private void OpenLast()
    {
        if (lastImage != null && File.Exists(lastImage))
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{lastImage}\"") { UseShellExecute = true });
        else Notify("尚未保存图片", "先在桌面或文件夹中按 Ctrl + V 保存一张图片。", ToolTipIcon.Info);
    }
    private void OpenToolLocation()
    {
        try
        {
            string path = Environment.ProcessPath ?? throw new InvalidOperationException("无法获取当前程序路径。");
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            AppLog.Write(ex);
            Notify("无法打开工具所在位置", ex.Message, ToolTipIcon.Warning);
        }
    }
    protected override void ExitThreadCore()
    {
        exiting = true;
        updateCancellation.Cancel();
        hook.Enabled = false;
        if (!busy) base.ExitThreadCore();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { updateCancellation.Dispose(); hook.Dispose(); cursor.Dispose(); tray.Visible = false; tray.Dispose(); dispatcher.Dispose(); }
        base.Dispose(disposing);
    }
}
