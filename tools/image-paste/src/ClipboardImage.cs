using System.Buffers.Binary;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace ImagePaste;

internal sealed record ClipboardSnapshot(byte[]? Png, byte[]? Dib, Bitmap? Bitmap) : IDisposable
{
    public void Dispose() => Bitmap?.Dispose();
}

internal static class ClipboardImage
{
    private const int MaxBytes = 256 * 1024 * 1024;

    internal static async Task<ClipboardSnapshot> CaptureAsync(uint version)
    {
        for (int attempt = 0; attempt < 6; attempt++)
        {
            if (Native.GetClipboardSequenceNumber() != version)
                throw new InvalidOperationException("剪贴板内容已变化，请重新粘贴。");
            if (Native.OpenClipboard(0))
            {
                try
                {
                    if (Native.GetClipboardSequenceNumber() != version || Native.HasFiles())
                        throw new InvalidOperationException("剪贴板内容已变化，请重新粘贴。");
                    byte[]? png = ReadBytes(Native.Png);
                    byte[]? dib = ReadBytes(Native.CF_DIBV5) ?? ReadBytes(Native.CF_DIB);
                    Bitmap? bitmap = null;
                    if (png == null && dib == null)
                    {
                        nint handle = Native.GetClipboardData(Native.CF_BITMAP);
                        if (handle != 0) bitmap = Image.FromHbitmap(handle);
                    }
                    if (png == null && dib == null && bitmap == null)
                        throw new InvalidOperationException("未能读取剪贴板中的图片，请重新复制后再试。");
                    return new(png, dib, bitmap);
                }
                finally { Native.CloseClipboard(); }
            }
            await Task.Delay(35 * (attempt + 1));
        }
        throw new InvalidOperationException("剪贴板正被其他程序占用，请稍后重试。");
    }

    private static byte[]? ReadBytes(uint format)
    {
        if (!Native.IsClipboardFormatAvailable(format)) return null;
        nint handle = Native.GetClipboardData(format);
        if (handle == 0) return null;
        ulong size = Native.GlobalSize(handle);
        if (size == 0) return null;
        if (size > MaxBytes) throw new InvalidOperationException("图片数据超过 256 MB，暂不支持。");
        nint pointer = Native.GlobalLock(handle);
        if (pointer == 0) return null;
        try { byte[] bytes = new byte[(int)size]; Marshal.Copy(pointer, bytes, 0, bytes.Length); return bytes; }
        finally { Native.GlobalUnlock(handle); }
    }

    internal static byte[] Encode(ClipboardSnapshot snapshot)
    {
        if (snapshot.Png != null)
        {
            try
            {
                using var stream = new MemoryStream(snapshot.Png);
                using var source = Image.FromStream(stream, false, true);
                ValidateSize(source.Width, source.Height);
                return ToPng(source);
            }
            catch (Exception ex) when ((ex is ArgumentException or ExternalException) && snapshot.Dib != null) { }
        }
        if (snapshot.Dib != null)
        {
            using var bitmap = DecodeDib(snapshot.Dib);
            return ToPng(bitmap);
        }
        if (snapshot.Bitmap != null)
        {
            ValidateSize(snapshot.Bitmap.Width, snapshot.Bitmap.Height);
            return ToPng(snapshot.Bitmap);
        }
        throw new InvalidOperationException("图片格式无法解码。");
    }

    private static byte[] ToPng(Image image)
    {
        using var stream = new MemoryStream();
        image.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }

    private static void ValidateSize(int width, int height)
    {
        if (width <= 0 || height <= 0 || (long)width * height > 64_000_000)
            throw new InvalidOperationException("图片尺寸无效或超过 6400 万像素。");
    }

    internal static Bitmap DecodeDib(byte[] data)
    {
        if (data.Length < 40) throw new InvalidDataException("图片头不完整。");
        uint header = U32(data, 0);
        if (header is not (40 or 52 or 56 or 108 or 124) || header > data.Length)
            throw new InvalidDataException("不支持的位图头。");
        int width = I32(data, 4), signedHeight = I32(data, 8);
        if (signedHeight == int.MinValue) throw new InvalidDataException("图片高度无效。");
        int height = Math.Abs(signedHeight);
        ValidateSize(width, height);
        int bits = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(14));
        uint compression = U32(data, 16), colors = U32(data, 32);
        if (BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(12)) != 1 || compression is not (0 or 3 or 6))
            throw new InvalidDataException("不支持的位图压缩格式。");
        if (bits is not (1 or 4 or 8 or 16 or 24 or 32)) throw new InvalidDataException("不支持的位图位深。");
        long palette = colors != 0 ? colors : (bits <= 8 ? 1L << bits : 0);
        int externalMasks = header == 40 && compression != 0 ? (compression == 6 ? 16 : 12) : 0;
        int offset = checked((int)(header + externalMasks + palette * 4));
        // A packed DIBV5 may put its color profile between the table and the pixels.
        if (header == 124)
        {
            uint profile = U32(data, 112), profileSize = U32(data, 116);
            if (profileSize != 0 && profile == offset) offset = checked(offset + (int)profileSize);
        }
        int stride = checked((int)(((long)width * bits + 31) / 32 * 4));
        if (offset < 0 || (long)offset + (long)stride * height > data.Length)
            throw new InvalidDataException("图片像素数据不完整。");

        if (bits == 32)
        {
            uint red = 0x00ff0000, green = 0x0000ff00, blue = 0x000000ff, alpha = 0;
            if (compression != 0)
            {
                red = U32(data, 40); green = U32(data, 44); blue = U32(data, 48);
                if (header >= 56 || compression == 6) alpha = U32(data, 52);
            }
            else if (header >= 56) alpha = U32(data, 52);
            bool explicitAlpha = alpha != 0;
            bool hasAlpha = explicitAlpha;
            // Many screenshot tools store meaningful alpha in BI_RGB; all-zero means opaque.
            if (compression == 0 && !hasAlpha)
            {
                for (int y = 0; y < height && !hasAlpha; y++)
                    for (int x = 0; x < width; x++)
                        if (data[offset + y * stride + x * 4 + 3] != 0) { hasAlpha = true; break; }
                alpha = 0xff000000;
            }
            var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            var locked = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try
            {
                byte[] row = new byte[width * 4];
                for (int y = 0; y < height; y++)
                {
                    int source = offset + (signedHeight > 0 ? height - 1 - y : y) * stride;
                    for (int x = 0; x < width; x++)
                    {
                        uint pixel = U32(data, source + x * 4);
                        row[x * 4] = Channel(pixel, blue);
                        row[x * 4 + 1] = Channel(pixel, green);
                        row[x * 4 + 2] = Channel(pixel, red);
                        row[x * 4 + 3] = hasAlpha ? Channel(pixel, alpha) : (byte)255;
                    }
                    Marshal.Copy(row, 0, locked.Scan0 + y * locked.Stride, row.Length);
                }
            }
            finally { bitmap.UnlockBits(locked); }
            return bitmap;
        }

        using var bmp = new MemoryStream();
        using (var writer = new BinaryWriter(bmp, System.Text.Encoding.UTF8, true))
        {
            writer.Write((ushort)0x4d42); writer.Write(checked(data.Length + 14));
            writer.Write(0); writer.Write(checked(offset + 14)); writer.Write(data);
        }
        bmp.Position = 0;
        using var image = Image.FromStream(bmp, false, true);
        return new Bitmap(image);
    }

    private static byte Channel(uint pixel, uint mask)
    {
        if (mask == 0) return 0;
        int shift = System.Numerics.BitOperations.TrailingZeroCount(mask);
        uint max = mask >> shift;
        return (byte)(((ulong)((pixel & mask) >> shift) * 255 + max / 2) / max);
    }
    private static uint U32(byte[] data, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(offset, 4));
    private static int I32(byte[] data, int offset) => BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(offset, 4));
}
