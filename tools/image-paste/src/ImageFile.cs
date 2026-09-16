namespace ImagePaste;

internal static class ImageFile
{
    internal static string Save(string folder, byte[] png, string? stem = null)
    {
        if (!Path.IsPathFullyQualified(folder) || !Directory.Exists(folder))
            throw new DirectoryNotFoundException("目标文件夹不存在或当前不可访问。");
        stem ??= $"图片_{DateTime.Now:yyyyMMdd_HHmmss_fff}";
        // Complete a private temporary file before exposing the final PNG; never overwrite.
        string temporary = Path.Combine(folder, $".imagepaste-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                stream.Write(png);
            for (int index = 0; index < 10000; index++)
            {
                string path = Path.Combine(folder, stem + (index == 0 ? "" : $" ({index})") + ".png");
                try { File.Move(temporary, path, false); return path; }
                catch (IOException) when (File.Exists(path)) { }
            }
            throw new IOException("同名图片过多，无法生成文件名。");
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
