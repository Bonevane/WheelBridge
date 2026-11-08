import AppKit
import SwiftUI

// Draws WheelBridge's app icon at every size macOS needs, into an .iconset that
// iconutil turns into AppIcon.icns. The wheel comes from WheelGlyph, the same
// shape the menu bar uses, so the two can never drift apart.
//
// Built with scripts/make-icon.sh.

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

// Racing green: the same structure as Bridge's navy, in its own colour.
let top = rgb(0x14, 0x3D, 0x2C)
let bottom = rgb(0x0A, 0x26, 0x19)

func png(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext

    // Apple's grid: the rounded square is 824/1024 of the canvas, corner 185/1024.
    let inset = s * (1 - 824.0 / 1024) / 2
    let square = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    context.saveGState()
    context.addPath(CGPath(roundedRect: square, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil))
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.minY), options: [])
    context.restoreGState()

    // The wheel at about 60% of the square, like Bridge's mark. WheelGlyph is
    // drawn top-down, and this context runs bottom-up, so flip it.
    let markRect = square.insetBy(dx: square.width * 0.20, dy: square.height * 0.20)
    context.saveGState()
    context.translateBy(x: 0, y: s)
    context.scaleBy(x: 1, y: -1)
    let flipped = CGRect(x: markRect.minX, y: s - markRect.maxY, width: markRect.width, height: markRect.height)
    context.addPath(WheelGlyph().path(in: flipped).cgPath)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath(using: .evenOdd)
    context.restoreGState()

    return rep.representation(using: .png, properties: [:])!
}

let folder = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                     ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                     ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(size).write(to: URL(fileURLWithPath: "\(folder)/icon_\(name).png"))
}
