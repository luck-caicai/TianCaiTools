using System.Buffers.Binary;
using System.Drawing.Imaging;
using System.Text.Json;

namespace ImagePaste;

internal static class SelfTests
{
    internal static int Run(string report)
    {
        var results = new List<object>();
        int failed = 0;
        void Test(string name, Action action)
        {
            try { action(); results.Add(new { name, passed = true }); }
            catch (Exception ex) { failed++; results.Add(new { name, passed = false, error = ex.ToString() }); }
        }
        Test("Tencent desktop accepts host paste but excludes edits, menus, panels and other apps", () =>
        {
            Assert(PasteTarget.IsTencentDesktopTarget("DesktopMgr64", true, 0, true), "Observed DeskGo desktop rejected");
            Assert(PasteTarget.IsTencentDesktopTarget("DesktopMgr", true, 1, true), "32-bit host rejected");
            Assert(!PasteTarget.IsTencentDesktopTarget("QQ", true, 0, true), "Other Tencent app intercepted");
            Assert(!PasteTarget.IsTencentDesktopTarget("DesktopMgr64", false, 0, true), "Child editor intercepted");
            Assert(!PasteTarget.IsTencentDesktopTarget("DesktopMgr64", true, 4, true), "Menu intercepted");
            Assert(!PasteTarget.IsTencentDesktopTarget("DesktopMgr64", true, 0, false), "Small panel intercepted");
        });
        Test("Desktop host and missing focus allow fallback, edits and foreign focus do not", () =>
        {
            Assert(PasteTarget.AllowsDesktopFallback(0, 10, 20, ""), "Missing desktop focus rejected");
            Assert(PasteTarget.AllowsDesktopFallback(10, 10, 20, "Progman"), "Progman focus rejected");
            Assert(PasteTarget.AllowsDesktopFallback(10, 10, 10, "WorkerW"), "WorkerW focus rejected");
            Assert(PasteTarget.AllowsDesktopFallback(20, 10, 20, "WorkerW"), "Separate desktop host rejected");
            Assert(!PasteTarget.AllowsDesktopFallback(11, 10, 20, "Edit"), "Rename intercepted");
            Assert(!PasteTarget.AllowsDesktopFallback(11, 10, 20, "WorkerW"), "Other host focus intercepted");
            Assert(!PasteTarget.AllowsDesktopFallback(11, 10, 20, "TXMiniSkin"), "Third-party control intercepted");
        });
        Test("Caret blinking is allowed, menus and window moves block paste", () =>
        {
            Assert(PasteTarget.AllowsShortcut(0) && PasteTarget.AllowsShortcut(1), "Caret flag blocks paste");
            foreach (uint flag in new uint[] { 2, 4, 8, 16, 5, 17 })
                Assert(!PasteTarget.AllowsShortcut(flag), "Menu or move flag accepted");
        });
        Test("Updates filter tool, draft, prerelease and missing packages; compare versions numerically", () =>
        {
            object Release(string tag, string version, bool draft = false, bool prerelease = false, bool package = true) => new
            {
                tag_name = tag, draft, prerelease,
                assets = package ? new[] { new { name = $"image-paste-{version}-win-x64.zip", state = "uploaded", size = 100 } } : Array.Empty<object>()
            };
            string json = JsonSerializer.Serialize(new[] {
                Release("other-tool/v99.0.0", "99.0.0"), Release("image-paste/v1.9.0", "1.9.0"),
                Release("image-paste/v1.10.0", "1.10.0"), Release("image-paste/v8.0.0", "8.0.0", draft: true),
                Release("image-paste/v9.0.0", "9.0.0", prerelease: true), Release("image-paste/v7.0.0", "7.0.0", package: false),
                Release("image-paste/v6.0.0-beta", "6.0.0"), Release("image-paste/v5.0.0.0", "5.0.0.0") });
            var latest = UpdateChecker.SelectLatest(json);
            Assert(latest?.Version == new Version(1, 10, 0), "Incorrect release selected");
            Assert(latest!.PageUrl.StartsWith("https://github.com/luck-caicai/TianCaiTools/releases/tag/"), "Untrusted release URL");
            Assert(UpdateChecker.SelectLatest("[]", latest) == latest, "Previous page candidate was lost");
            Assert(UpdateChecker.SelectLatest("[]") == null, "Empty list should not imply current version is latest");
        });
        Test("PNG round trip preserves partial and full transparency", () =>
        {
            using var image = new Bitmap(2, 1, PixelFormat.Format32bppArgb);
            image.SetPixel(0, 0, Color.FromArgb(96, 200, 100, 50));
            image.SetPixel(1, 0, Color.Transparent);
            using var stream = new MemoryStream(); image.Save(stream, ImageFormat.Png);
            using var snapshot = new ClipboardSnapshot(stream.ToArray(), null, null);
            using var output = new MemoryStream(ClipboardImage.Encode(snapshot));
            using var decoded = new Bitmap(output);
            Assert(decoded.GetPixel(0, 0).ToArgb() == image.GetPixel(0, 0).ToArgb(), "Partial alpha changed");
            Assert(decoded.GetPixel(1, 0).A == 0, "Transparency lost");
        });
        Test("BI_RGB all-zero alpha becomes opaque; bottom-up rows flip", () =>
        {
            byte[] dib = Dib(40, 1, 2, 32, 0, new byte[] { 255, 0, 0, 0, 0, 0, 255, 0 });
            using var image = ClipboardImage.DecodeDib(dib);
            Assert(image.GetPixel(0, 0).ToArgb() == Color.Red.ToArgb(), "Top row incorrect");
            Assert(image.GetPixel(0, 1).ToArgb() == Color.Blue.ToArgb(), "Bottom row incorrect");
        });
        Test("Top-down BI_RGB preserves meaningful alpha", () =>
        {
            using var image = ClipboardImage.DecodeDib(Dib(40, 1, -2, 32, 0, new byte[] { 0, 0, 255, 100, 255, 0, 0, 0 }));
            Assert(image.GetPixel(0, 0).A == 100 && image.GetPixel(0, 0).R == 255, "Top-down alpha mismatch");
            Assert(image.GetPixel(0, 1).A == 0, "Transparent pixel mismatch");
        });
        Test("DIBV5 explicit all-zero alpha stays transparent", () =>
        {
            byte[] dib = Dib(124, 1, 1, 32, 3, new byte[] { 100, 20, 200, 0 });
            Put(dib, 40, 0xff0000); Put(dib, 44, 0xff00); Put(dib, 48, 0xff); Put(dib, 52, 0xff000000);
            using var image = ClipboardImage.DecodeDib(dib);
            Assert(image.GetPixel(0, 0).A == 0, "Explicit transparent image became opaque");
        });
        Test("DIBV5 nonstandard channel masks are respected", () =>
        {
            byte[] dib = Dib(124, 1, 1, 32, 3, new byte[] { 255, 0, 0, 128 });
            Put(dib, 40, 0xff); Put(dib, 44, 0xff00); Put(dib, 48, 0xff0000); Put(dib, 52, 0xff000000);
            using var image = ClipboardImage.DecodeDib(dib);
            Assert(image.GetPixel(0, 0).R == 255 && image.GetPixel(0, 0).B == 0 && image.GetPixel(0, 0).A == 128, "Bit masks ignored");
        });
        Test("24-bit bitmap row padding", () =>
        {
            using var image = ClipboardImage.DecodeDib(Dib(40, 1, 1, 24, 0, new byte[] { 0, 255, 0, 0 }));
            Assert(image.GetPixel(0, 0).ToArgb() == Color.Lime.ToArgb(), "24-bit decode failed");
        });
        Test("Malformed and oversized DIB rejected", () =>
        {
            Throws(() => ClipboardImage.DecodeDib(new byte[12]));
            Throws(() => ClipboardImage.DecodeDib(Dib(40, 90000, 90000, 32, 0, Array.Empty<byte>())));
            Throws(() => ClipboardImage.DecodeDib(Dib(40, 2, 2, 32, 0, new byte[4])));
        });
        Test("Invalid PNG falls back to DIB", () =>
        {
            using var snapshot = new ClipboardSnapshot(new byte[] { 1, 2, 3 }, Dib(40, 1, 1, 24, 0, new byte[] { 0, 0, 255, 0 }), null);
            using var output = new MemoryStream(ClipboardImage.Encode(snapshot));
            using var bitmap = new Bitmap(output);
            Assert(bitmap.GetPixel(0, 0).R == 255, "DIB fallback failed");
        });
        Test("Concurrent saves never overwrite and leave no temp files", () =>
        {
            string folder = Path.Combine(Path.GetTempPath(), "ImagePaste-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            try
            {
                File.WriteAllText(Path.Combine(folder, "same.png"), "original");
                Parallel.For(0, 8, index => ImageFile.Save(folder, new byte[] { (byte)index }, "same"));
                Assert(File.ReadAllText(Path.Combine(folder, "same.png")) == "original", "Existing file overwritten");
                Assert(Directory.GetFiles(folder, "*.png").Length == 9, "Concurrent save missing");
                Assert(Directory.GetFiles(folder, "*.tmp").Length == 0, "Temporary files leaked");
            }
            finally { foreach (string file in Directory.GetFiles(folder)) File.Delete(file); Directory.Delete(folder); }
        });
        Test("Missing destination is never created or redirected", () =>
        {
            string folder = Path.Combine(Path.GetTempPath(), "ImagePaste-missing-" + Guid.NewGuid().ToString("N"));
            Throws(() => ImageFile.Save(folder, new byte[] { 1 }));
            Assert(!Directory.Exists(folder), "Missing folder created unexpectedly");
        });
        File.WriteAllText(report, JsonSerializer.Serialize(new { passed = results.Count - failed, failed, results }, new JsonSerializerOptions { WriteIndented = true }));
        return failed == 0 ? 0 : 1;
    }

    private static byte[] Dib(int header, int width, int height, int bits, uint compression, byte[] pixels)
    {
        byte[] data = new byte[header + pixels.Length];
        Put(data, 0, (uint)header); Put(data, 4, unchecked((uint)width)); Put(data, 8, unchecked((uint)height));
        data[12] = 1; data[14] = (byte)bits; Put(data, 16, compression);
        pixels.CopyTo(data, header); return data;
    }
    private static void Put(byte[] data, int offset, uint value) => BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(offset, 4), value);
    private static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static void Throws(Action action)
    {
        try { action(); } catch (Exception) { return; }
        throw new Exception("Expected rejection did not happen");
    }
}
