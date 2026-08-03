#!/usr/bin/env swift
// Renders Resources/AppIcon.icns. Run via tools/make-icon.sh — nothing else depends on it.

import AppKit

let canvas: CGFloat = 1024
// macOS icons leave the outer ~10% empty so the squircle matches system icons.
let inset: CGFloat = 100
let radius: CGFloat = 185

let paperTop = NSColor(srgbRed: 1.00, green: 0.91, blue: 0.55, alpha: 1)
let paperBottom = NSColor(srgbRed: 1.00, green: 0.81, blue: 0.29, alpha: 1)
let ink = NSColor(srgbRed: 0.23, green: 0.19, blue: 0.07, alpha: 1)

func drawIcon(into context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let body = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Paper
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [paperTop.cgColor, paperBottom.cgColor] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: body.maxY),
                               end: CGPoint(x: 0, y: body.minY),
                               options: [])
    context.restoreGState()

    // Three checklist rows, top one completed.
    let boxSize: CGFloat = 118
    let boxX = body.minX + 108
    let lineX = boxX + boxSize + 58
    let lineEnd = body.maxX - 108
    let lineHeight: CGFloat = 56
    let rowYs: [CGFloat] = [body.maxY - 265, body.midY - boxSize / 2, body.minY + 209]

    for (index, y) in rowYs.enumerated() {
        let box = CGRect(x: boxX, y: y, width: boxSize, height: boxSize)
        let boxPath = CGPath(roundedRect: box, cornerWidth: 26, cornerHeight: 26, transform: nil)
        let done = index == 0

        if done {
            context.addPath(boxPath)
            context.setFillColor(ink.cgColor)
            context.fillPath()

            context.setStrokeColor(paperTop.cgColor)
            context.setLineWidth(20)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: box.minX + 26, y: box.midY + 2))
            context.addLine(to: CGPoint(x: box.midX - 6, y: box.minY + 28))
            context.addLine(to: CGPoint(x: box.maxX - 22, y: box.maxY - 28))
            context.strokePath()
        } else {
            context.addPath(boxPath)
            context.setStrokeColor(ink.withAlphaComponent(0.75).cgColor)
            context.setLineWidth(18)
            context.strokePath()
        }

        let width = index == 2 ? (lineEnd - lineX) * 0.62 : (lineEnd - lineX)
        let bar = CGRect(x: lineX, y: y + (boxSize - lineHeight) / 2, width: width, height: lineHeight)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        context.setFillColor(ink.withAlphaComponent(done ? 0.3 : 0.72).cgColor)
        context.fillPath()

        if done {   // strike it through
            context.setStrokeColor(ink.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(16)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: bar.minX + 6, y: bar.midY))
            context.addLine(to: CGPoint(x: bar.maxX - 6, y: bar.midY))
            context.strokePath()
        }
    }
}

func png(at pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let context = gc.cgContext
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    drawIcon(into: context)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try! png(at: base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! png(at: base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
print("wrote \(outDir)")
