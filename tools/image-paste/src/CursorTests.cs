using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace ImagePaste;

internal static class CursorTests
{
    internal static int Run(string report)
    {
        var checks = new List<string>();
        try
        {
            void Check(bool passed, string message)
            {
                if (!passed) throw new InvalidOperationException(message);
                checks.Add(message);
            }
            string original = Signature(32512);
            string wait = Signature(32514);
            using (var cursor = new BusyCursor())
            {
                cursor.Begin();
                Check(Signature(32512) == wait, "Normal pointer becomes the native wait cursor");
                cursor.Begin();
                cursor.End();
                Check(Signature(32512) == original, "Repeated begin then end restores original pointer");
                cursor.Begin();
            }
            Check(Signature(32512) == original, "Disposing while busy restores original pointer");
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
            start.ArgumentList.Add("--cursor-orphan-test");
            using var orphan = Process.Start(start)!;
            Check(orphan.WaitForExit(8000) && orphan.ExitCode == 0, "Abrupt-parent-exit fixture ran successfully");
            var deadline = Stopwatch.StartNew();
            while (Signature(32512) != original && deadline.ElapsedMilliseconds < 3000) Thread.Sleep(100);
            Check(Signature(32512) == original, "Recovery process restores pointer after parent exits without cleanup");
            File.WriteAllText(report, JsonSerializer.Serialize(new { passed = checks.Count, failed = 0, checks }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception ex)
        {
            File.WriteAllText(report, JsonSerializer.Serialize(new { passed = checks.Count, failed = 1, checks, error = ex.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
            return 1;
        }
    }

    private static string Signature(int cursorId)
    {
        using var bitmap = new Bitmap(64, 64, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.White);
            nint hdc = graphics.GetHdc();
            try
            {
                if (!DrawIconEx(hdc, 0, 0, CursorReplacement.LoadCursor(0, (nint)cursorId), 64, 64, 0, 0, 3))
                    throw new InvalidOperationException("无法读取系统光标图像。");
            }
            finally { graphics.ReleaseHdc(hdc); }
        }
        using var stream = new MemoryStream();
        bitmap.Save(stream, ImageFormat.Png);
        return Convert.ToHexString(SHA256.HashData(stream.ToArray()));
    }
    [DllImport("user32.dll")] private static extern bool DrawIconEx(nint dc, int x, int y, nint icon, int width, int height, uint step, nint brush, uint flags);
}
