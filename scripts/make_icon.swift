// Regenerate the original Concept C artwork without launching an app:
// CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swift scripts/make_icon.swift [output-root]
// Default output root is the repository. Builds use the committed .icns, never this script.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count == 2
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : repository
if CommandLine.arguments.count > 2 {
    fputs("Usage: swift scripts/make_icon.swift [output-root]\n", stderr)
    exit(2)
}
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}
func bitmap(width: Int, height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}
func render(size: Int) -> CGImage {
    let context = bitmap(width: size, height: size)
    let scale = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    // Shadows use device-space units, even after scaling and flipping the canvas.
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale),
        blur: max(1, 28 * scale), color: color(0x000000, alpha: 0.30))
    context.addPath(body)
    context.setFillColor(color(0x4E8C72))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(body)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
        colors: [color(0x4E8C72), color(0x2D5E4B)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100),
        end: CGPoint(x: 0, y: 924), options: [])
    let light = CGGradient(colorsSpace: colorSpace,
        colors: [color(0xFFFFFF, alpha: 0.20), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(light, start: CGPoint(x: 0, y: 100),
        end: CGPoint(x: 0, y: 512), options: [])
    context.restoreGState()

    // Exact paths and nodes from .team/ux/silkweb-1.53-concept-c.svg.
    context.setStrokeColor(color(0xF7F1E3))
    context.setLineWidth(52)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 370, y: 300))
    context.addLine(to: CGPoint(x: 370, y: 640))
    context.addQuadCurve(to: CGPoint(x: 440, y: 710), control: CGPoint(x: 370, y: 710))
    context.addLine(to: CGPoint(x: 650, y: 710))
    context.strokePath()
    context.move(to: CGPoint(x: 370, y: 440))
    context.addQuadCurve(to: CGPoint(x: 440, y: 510), control: CGPoint(x: 370, y: 510))
    context.addLine(to: CGPoint(x: 650, y: 510))
    context.strokePath()
    let nodes: [(CGFloat, CGFloat, CGFloat, Int)] = [
        (370, 300, 64, 0xF7F1E3), (650, 510, 50, 0xF7F1E3), (650, 710, 50, 0xF28C6B)
    ]
    for (x, y, radius, hex) in nodes {
        context.saveGState()
        if size >= 128 {
            context.setShadow(offset: CGSize(width: 0, height: -6 * scale),
                blur: 16 * scale, color: color(0x000000, alpha: 0.18))
        }
        context.setFillColor(color(hex))
        context.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
            width: radius * 2, height: radius * 2))
        context.restoreGState()
    }
    context.setStrokeColor(color(0x000000, alpha: 0.08))
    context.setLineWidth(1)
    context.addPath(CGPath(roundedRect: CGRect(x: 100.5, y: 100.5, width: 823, height: 823),
        cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
    context.strokePath()
    return context.makeImage()!
}
func writePNG(_ image: CGImage, to url: URL) throws {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "SilkwebIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.path)"])
    }
}
let representations = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
let iconset = output.appendingPathComponent(".build/icon-generation/Silkweb.iconset")
let scripts = output.appendingPathComponent("scripts")
let qa = output.appendingPathComponent(".team/qa/silkweb-1.53")
for directory in [iconset, scripts, qa] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
var images: [Int: CGImage] = [:]
for (name, size) in representations {
    let image = images[size] ?? render(size: size)
    images[size] = image
    try writePNG(image, to: iconset.appendingPathComponent(name))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", scripts.appendingPathComponent("Silkweb.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 {
    // Some restricted hosts reject valid iconsets in iconutil. ICNS is a big-endian
    // chunk container; embed the same PNGs in its ten standard representation slots.
    // This fallback is validated by ImageIO below and by the app's packaging tests.
    fputs("iconutil failed; writing the equivalent PNG-backed ICNS container.\n", stderr)
    let types = ["icp4", "ic11", "icp5", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"]
    func bigEndian(_ value: Int) -> Data {
        var integer = UInt32(value).bigEndian
        return withUnsafeBytes(of: &integer) { Data($0) }
    }
    var chunks = Data()
    for (type, representation) in zip(types, representations) {
        let png = try Data(contentsOf: iconset.appendingPathComponent(representation.0))
        chunks.append(Data(type.utf8))
        chunks.append(bigEndian(png.count + 8))
        chunks.append(png)
    }
    var container = Data("icns".utf8)
    container.append(bigEndian(chunks.count + 8))
    container.append(chunks)
    try container.write(to: scripts.appendingPathComponent("Silkweb.icns"), options: .atomic)
}
let source = CGImageSourceCreateWithURL(scripts.appendingPathComponent("Silkweb.icns") as CFURL, nil)!
let expectedSizes = representations.map { $0.1 }.sorted()
let actualSizes = (0..<CGImageSourceGetCount(source)).map { index -> Int in
    let image = CGImageSourceCreateImageAtIndex(source, index, nil)!
    precondition(image.width == image.height)
    return image.width
}.sorted()
precondition(actualSizes == expectedSizes, "ICNS must contain all ten representations")

// True-size originals alongside a 512 px overview, 8x nearest-neighbor enlargements,
// and a two-icon mock Dock row. All gutters are 48 px; no labels or desktop UI.
for (name, background) in [("light", 0xECECEC), ("dark", 0x1E1E1E)] {
    let context = bitmap(width: 1600, height: 700)
    context.setFillColor(color(background))
    context.fill(CGRect(x: 0, y: 0, width: 1600, height: 700))
    func draw(_ pixels: Int, x: CGFloat, y: CGFloat, side: CGFloat, magnified: Bool = false) {
        context.interpolationQuality = magnified ? .none : .high
        context.draw(images[pixels]!, in: CGRect(x: x, y: y, width: side, height: side))
    }
    draw(1024, x: 48, y: 94, side: 512)
    draw(32, x: 608, y: 334, side: 32)
    draw(16, x: 688, y: 342, side: 16)
    draw(32, x: 752, y: 222, side: 256, magnified: true)
    draw(16, x: 1056, y: 286, side: 128, magnified: true)
    for x in [CGFloat(1232), CGFloat(1408)] { draw(128, x: x, y: 286, side: 128) }
    try writePNG(context.makeImage()!, to: qa.appendingPathComponent("icon-preview-\(name).png"))
}
// Unscaled source renders for QA to inspect or composite independently.
for size in [16, 32, 1024] {
    try writePNG(images[size]!, to: qa.appendingPathComponent("icon-\(size).png"))
}
print("Generated Silkweb.icns, 10 iconset PNGs, and QA previews under \(output.path)")
