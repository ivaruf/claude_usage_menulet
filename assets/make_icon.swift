// Renders the app icon: a coral six-spoke asterisk inside a 72% usage ring
// on a dark squircle. Outputs AppIcon.iconset/ (all sizes) and icon.png (512px
// for the README).
//
// Regenerate with:
//   cd assets
//   swift make_icon.swift
//   iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset
import AppKit
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, a])!
}

let coral = rgba(217, 119, 87)          // Claude terracotta #D97757
let creamTrack = rgba(240, 238, 230, 0.16)
let bgTop = rgba(56, 51, 47)            // warm charcoal
let bgBottom = rgba(26, 24, 22)

// All geometry is in 1024-point space; render() scales it to each pixel size.
func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px,
                        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Squircle (824pt, Apple's macOS icon grid) with a baked-in soft shadow.
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 24 * s, color: rgba(0, 0, 0, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(bgBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Usage ring at 72%, clockwise from 12 o'clock.
    let center = CGPoint(x: 512, y: 512)
    ctx.setLineWidth(56)
    ctx.setLineCap(.round)

    ctx.setStrokeColor(creamTrack)
    ctx.addArc(center: center, radius: 312, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()

    let start = CGFloat.pi / 2
    ctx.setStrokeColor(coral)
    ctx.addArc(center: center, radius: 312, startAngle: start,
               endAngle: start - 2 * .pi * 0.72, clockwise: true)
    ctx.strokePath()

    // Six-spoke asterisk: three lines through the center, 60° apart.
    ctx.setStrokeColor(coral)
    ctx.setLineWidth(62)
    for k in 0..<3 {
        let angle = CGFloat.pi / 2 + CGFloat(k) * .pi / 3
        let dx = 172 * cos(angle), dy = 172 * sin(angle)
        ctx.move(to: CGPoint(x: center.x + dx, y: center.y + dy))
        ctx.addLine(to: CGPoint(x: center.x - dx, y: center.y - dy))
    }
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write \(path)") }
}

let iconsetDir = "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    writePNG(render(size), to: "\(iconsetDir)/icon_\(size)x\(size).png")
    writePNG(render(size * 2), to: "\(iconsetDir)/icon_\(size)x\(size)@2x.png")
}
writePNG(render(512), to: "icon.png")
print("Wrote \(iconsetDir)/ and icon.png")
