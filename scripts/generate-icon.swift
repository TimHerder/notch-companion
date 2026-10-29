#!/usr/bin/env swift
// Original native vector icon using the companion's existing silhouette/eyes.
// Regenerate from any directory: xcrun swift /path/to/scripts/generate-icon.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
let output = root.appendingPathComponent("app/AppIcon.icns")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func renderIcon(pixels: Int, name: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setAllowsAntialiasing(true)
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let tile = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = color(0.12, 0.13, 0.11, 0.18)
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.shadowBlurRadius = 18
    tileShadow.set()
    color(0.94, 0.935, 0.885).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.93, 0.93, 0.88), ending: color(0.985, 0.98, 0.94))?.draw(in: tile, angle: 90)
    color(1, 1, 1, 0.75).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    // One equal-height silhouette, wider on the right to suggest the hardware
    // notch. The left-side face occupies the same continuous matte black shape.
    let silhouette = NSBezierPath()
    silhouette.move(to: NSPoint(x: 203, y: 659))
    silhouette.line(to: NSPoint(x: 821, y: 659))
    silhouette.curve(to: NSPoint(x: 857, y: 623), controlPoint1: NSPoint(x: 843, y: 659), controlPoint2: NSPoint(x: 857, y: 645))
    silhouette.line(to: NSPoint(x: 857, y: 454))
    silhouette.curve(to: NSPoint(x: 781, y: 378), controlPoint1: NSPoint(x: 857, y: 404), controlPoint2: NSPoint(x: 831, y: 378))
    silhouette.line(to: NSPoint(x: 243, y: 378))
    silhouette.curve(to: NSPoint(x: 167, y: 454), controlPoint1: NSPoint(x: 193, y: 378), controlPoint2: NSPoint(x: 167, y: 404))
    silhouette.line(to: NSPoint(x: 167, y: 623))
    silhouette.curve(to: NSPoint(x: 203, y: 659), controlPoint1: NSPoint(x: 167, y: 645), controlPoint2: NSPoint(x: 181, y: 659))
    silhouette.close()
    NSGraphicsContext.saveGraphicsState()
    let silhouetteShadow = NSShadow()
    silhouetteShadow.shadowColor = color(0.07, 0.08, 0.065, 0.15)
    silhouetteShadow.shadowOffset = NSSize(width: 0, height: -16)
    silhouetteShadow.shadowBlurRadius = 20
    silhouetteShadow.set()
    color(0.055, 0.062, 0.056).setFill()
    silhouette.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.035, 0.041, 0.036), ending: color(0.075, 0.082, 0.073))?.draw(in: silhouette, angle: 90)

    // Slightly larger eyes at small sizes preserve the mascot's legibility.
    let eyeWidth: CGFloat = pixels <= 32 ? 52 : 37
    let eyeHeight: CGFloat = pixels <= 32 ? 88 : 78
    color(0.98, 0.975, 0.90).setFill()
    for centerX: CGFloat in [291, 362] {
        NSBezierPath(roundedRect: NSRect(x: centerX - eyeWidth / 2, y: 523 - eyeHeight / 2,
            width: eyeWidth, height: eyeHeight), xRadius: eyeWidth / 2, yRadius: eyeWidth / 2).fill()
    }

    // A small sage glint echoes the interface's quiet active-state accent.
    color(0.66, 0.75, 0.63).setFill()
    let glint: CGFloat = pixels <= 32 ? 20 : 14
    NSBezierPath(ovalIn: NSRect(x: 751 - glint / 2, y: 523 - glint / 2, width: glint, height: glint)).fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon PNG")
    }
    try png.write(to: iconset.appendingPathComponent(name), options: .atomic)
}

for points in [16, 32, 128, 256, 512] {
    try renderIcon(pixels: points, name: "icon_\(points)x\(points).png")
    try renderIcon(pixels: points * 2, name: "icon_\(points)x\(points)@2x.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated original icon: \(output.path)")
print("Preview: \(iconset.appendingPathComponent("icon_512x512@2x.png").path)")
