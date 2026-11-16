import AppKit

let directory = CommandLine.arguments[1]
let sizes = [16, 32, 128, 256, 512]
func makeIcon(_ pixels: Int, path: String) throws {
    let dimension = CGFloat(pixels)
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    let scale = dimension / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 208, yRadius: 208)
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.22, blue: 0.31, alpha: 1),
        ending: NSColor(srgbRed: 0.07, green: 0.10, blue: 0.17, alpha: 1))!.draw(in: background, angle: -90)
    let text = "Ctrl" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 260, weight: .semibold), .foregroundColor: NSColor.white
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (1024 - textSize.width) / 2, y: 490), withAttributes: attributes)
    NSColor(srgbRed: 0.22, green: 0.82, blue: 0.43, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 290, y: 238, width: 444, height: 208), xRadius: 104, yRadius: 104).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 550, y: 264, width: 156, height: 156)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
for size in sizes {
    try makeIcon(size, path: "\(directory)/icon_\(size)x\(size).png")
    try makeIcon(size * 2, path: "\(directory)/icon_\(size)x\(size)@2x.png")
}

// Package the PNG representations directly, keeping the build independent of iconutil services.
let representations: [(String, String)] = [
    ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
]
func sizeData(_ size: Int) -> Data {
    var value = UInt32(size).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var body = Data()
for (type, filename) in representations {
    let png = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/\(filename)"))
    body.append(Data(type.utf8))
    body.append(sizeData(png.count + 8))
    body.append(png)
}
var icon = Data("icns".utf8)
icon.append(sizeData(body.count + 8))
icon.append(body)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
