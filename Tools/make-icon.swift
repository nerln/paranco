// Draws the paranco mark at every size an .icns wants. Same drawing as
// docs/img/mark.svg, in Core Graphics, because the only SVG converter to hand
// is a thumbnailer that crops.
//
//   swiftc -O -parse-as-library make-icon.swift -o make-icon && ./make-icon <dir>

import AppKit
import CoreGraphics
import Foundation

let ink = CGColor(red: 0x0E / 255, green: 0x0D / 255, blue: 0x0C / 255, alpha: 1)
let amber = CGColor(red: 0xE0 / 255, green: 0xA4 / 255, blue: 0x58 / 255, alpha: 1)
let paper = CGColor(red: 0xED / 255, green: 0xE8 / 255, blue: 0xDE / 255, alpha: 1)

func draw(size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // macOS insets its icons inside the tile; filling it edge to edge is the one
    // thing that makes an icon look like it was made by somebody who never
    // shipped a Mac application.
    let inset = CGFloat(size) * 0.09
    let side = CGFloat(size) - inset * 2
    let u = side / 64
    func x(_ v: CGFloat) -> CGFloat { inset + v * u }
    func y(_ v: CGFloat) -> CGFloat { inset + (64 - v) * u }

    ctx.setFillColor(ink)
    ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
                       cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil))
    ctx.fillPath()

    ctx.setStrokeColor(paper)
    ctx.setLineWidth(5 * u)
    ctx.strokeEllipse(in: CGRect(x: x(32 - 8), y: y(21 + 8), width: 16 * u, height: 16 * u))

    ctx.setFillColor(amber)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x(29.5), y: y(43), width: 5 * u, height: 14 * u),
                       cornerWidth: 2.5 * u, cornerHeight: 2.5 * u, transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: x(19), y: y(49), width: 26 * u, height: 6 * u),
                       cornerWidth: 3 * u, cornerHeight: 3 * u, transform: nil))
    ctx.fillPath()
    return ctx.makeImage()
}

@main
struct Main {
    static func main() {
        guard CommandLine.arguments.count > 1 else { print("usage: make-icon <dir>"); exit(1) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tiles: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, size) in tiles {
            guard let image = draw(size: size),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { print("failed at \(size)"); exit(2) }
            try? data.write(to: out.appendingPathComponent("\(name).png"))
        }
        print("wrote \(tiles.count) tiles")
    }
}
