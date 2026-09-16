$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$frames = @()
foreach ($size in @(16, 32, 48, 256)) {
    $bitmap = New-Object System.Drawing.Bitmap($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.ScaleTransform($size / 32.0, $size / 32.0)
    $ink = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(35, 53, 70))
    $paper = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(243, 249, 252))
    $green = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(23, 171, 122))
    $graphics.FillRectangle($ink, 5, 3, 22, 27)
    $graphics.FillRectangle($paper, 7, 5, 18, 22)
    $graphics.FillRectangle($ink, 11, 2, 10, 5)
    $graphics.FillEllipse($green, 17, 10, 5, 5)
    $points = [System.Drawing.PointF[]]@([System.Drawing.PointF]::new(9, 24), [System.Drawing.PointF]::new(14, 15), [System.Drawing.PointF]::new(18, 20), [System.Drawing.PointF]::new(21, 17), [System.Drawing.PointF]::new(24, 24))
    $graphics.FillPolygon($green, $points)
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $frames += ,@{ Size = $size; Bytes = $stream.ToArray() }
    $stream.Dispose(); $green.Dispose(); $paper.Dispose(); $ink.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$iconPath = Join-Path $PSScriptRoot '..\src\app.ico'
$file = [System.IO.File]::Create($iconPath)
$writer = New-Object System.IO.BinaryWriter($file)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$frame.Bytes.Length); $writer.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
} finally { $writer.Dispose(); $file.Dispose() }
