// Draws the Striple app icon with CoreGraphics and writes AppIcon.icns.
//
// Usage: swift scripts/make-icon.swift <outdir>
// Output: <outdir>/AppIcon.iconset/*.png and <outdir>/AppIcon.icns
//
// The icon is a macOS style rounded square with a horizontal strip of three
// columns. The middle column is the focused one. Every size is drawn from the
// same vector code at its exact pixel size, so small sizes stay sharp.
// Same input gives the same pixels: no fonts, no randomness, no time stamps.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <outdir>\n".data(using: .utf8)!)
    exit(2)
}

let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let fileManager = FileManager.default
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, a])!
}

/// Draws the icon in a 1024 x 1024 design space, scaled to `pixels`.
func drawIcon(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)

    // Apple icon grid: 824 x 824 body centered on a 1024 canvas, corner radius about 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body. Shadow sizes are in device pixels, so scale them.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: color(0, 0, 0, 0.30))
    context.addPath(bodyPath)
    context.setFillColor(color(30, 34, 64))
    context.fillPath()
    context.restoreGState()

    // Body: indigo at the top to blue at the bottom.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(98, 92, 230), color(24, 78, 204)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
    )

    // Soft light on the top half.
    let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(255, 255, 255, 0.16), color(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: []
    )

    // The strip: three columns. The outer two run past the body edge and are
    // clipped, which shows that the strip scrolls.
    let columnY: CGFloat = 300
    let columnHeight: CGFloat = 440
    let sideWidth: CGFloat = 250
    let middleWidth: CGFloat = 300
    let gap: CGFloat = 36
    let middleX = 512 - middleWidth / 2
    let radius: CGFloat = 44

    let left = CGRect(x: middleX - gap - sideWidth, y: columnY + 30, width: sideWidth, height: columnHeight - 60)
    let right = CGRect(x: middleX + middleWidth + gap, y: columnY + 30, width: sideWidth, height: columnHeight - 60)
    for frame in [left, right] {
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(color(255, 255, 255, 0.30))
        context.fillPath()
    }

    // Focused middle column with a shadow and a title bar.
    let middle = CGRect(x: middleX, y: columnY, width: middleWidth, height: columnHeight)
    let middlePath = CGPath(roundedRect: middle, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 36 * scale, color: color(10, 14, 60, 0.45))
    context.addPath(middlePath)
    context.setFillColor(color(255, 255, 255))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(middlePath)
    context.clip()
    context.setFillColor(color(228, 233, 250))
    context.fill(CGRect(x: middle.minX, y: middle.maxY - 64, width: middle.width, height: 64))
    context.restoreGState()

    let lightColors = [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)]
    for (index, lightColor) in lightColors.enumerated() {
        let center = CGPoint(x: middle.minX + 40 + CGFloat(index) * 34, y: middle.maxY - 32)
        context.setFillColor(lightColor)
        context.fillEllipse(in: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))
    }

    // Scroll position under the strip: a long lit pill between two dim dots.
    let indicators: [(x: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (440, 22, 0.40), (480, 64, 0.95), (562, 22, 0.40),
    ]
    for indicator in indicators {
        context.addPath(CGPath(
            roundedRect: CGRect(x: indicator.x, y: 214, width: indicator.width, height: 22),
            cornerWidth: 11, cornerHeight: 11, transform: nil
        ))
        context.setFillColor(color(255, 255, 255, indicator.alpha))
        context.fillPath()
    }
    context.restoreGState()

    // Thin inner edge so the body reads on light and dark backgrounds.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    context.addPath(bodyPath)
    context.setStrokeColor(color(255, 255, 255, 0.14))
    context.setLineWidth(6)
    context.strokePath()
    context.restoreGState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
}

// iconutil needs these exact names.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

var cache: [Int: CGImage] = [:]
for entry in entries {
    let image = cache[entry.pixels] ?? drawIcon(pixels: entry.pixels)
    cache[entry.pixels] = image
    writePNG(image, to: iconset.appendingPathComponent("\(entry.name).png"))
}

let icns = outDir.appendingPathComponent("AppIcon.icns")
try? fileManager.removeItem(at: icns)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed with status \(iconutil.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
print(icns.path)
