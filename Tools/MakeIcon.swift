#!/usr/bin/env swift
// Draws the app icon and writes an .iconset directory.
// Run:  swift Tools/MakeIcon.swift <output-iconset-directory>
//
// A play mark on a dark ground, with a plus badge in the upper right. The badge
// carries a ring of the background colour so it stays separate from the mark
// behind it — that separation is what keeps the icon readable at 32px.

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/YouTubePlus.iconset"

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let red = NSColor(calibratedRed: 1.00, green: 0.00, blue: 0.00, alpha: 1)
let deepRed = NSColor(calibratedRed: 0.79, green: 0.00, blue: 0.00, alpha: 1)
let ink = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)

func plusPath(centre: CGPoint, arm: CGFloat, thickness: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.append(NSBezierPath(
        roundedRect: CGRect(x: centre.x - arm / 2, y: centre.y - thickness / 2,
                            width: arm, height: thickness),
        xRadius: thickness / 2, yRadius: thickness / 2))
    path.append(NSBezierPath(
        roundedRect: CGRect(x: centre.x - thickness / 2, y: centre.y - arm / 2,
                            width: thickness, height: arm),
        xRadius: thickness / 2, yRadius: thickness / 2))
    return path
}

func drawIcon(size: Int) -> Data? {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return nil
    }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons sit inset in their canvas behind a superellipse mask.
    let inset = side * 0.055
    let canvas = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = canvas.width * 0.2237
    NSBezierPath(roundedRect: canvas, xRadius: radius, yRadius: radius).addClip()

    ink.setFill()
    canvas.fill()

    // The rounded "screen" carrying the play triangle.
    let unit = canvas.width
    let screenWidth = unit * 0.62
    let screenHeight = screenWidth * 0.70
    let screen = CGRect(x: canvas.midX - screenWidth / 2,
                        y: canvas.midY - screenHeight / 2,
                        width: screenWidth, height: screenHeight)
    let screenRadius = screenHeight * 0.29
    NSGradient(colors: [red, deepRed])?.draw(
        in: NSBezierPath(roundedRect: screen, xRadius: screenRadius, yRadius: screenRadius),
        angle: -90)

    // White play triangle, nudged right so it sits optically centred.
    let triangleHeight = screenHeight * 0.46
    let triangleWidth = triangleHeight * 0.86
    let centreX = screen.midX + triangleWidth * 0.10
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: centreX - triangleWidth / 2, y: screen.midY - triangleHeight / 2))
    triangle.line(to: NSPoint(x: centreX + triangleWidth / 2, y: screen.midY))
    triangle.line(to: NSPoint(x: centreX - triangleWidth / 2, y: screen.midY + triangleHeight / 2))
    triangle.close()
    triangle.lineJoinStyle = .round
    NSColor.white.setFill()
    triangle.fill()

    // Plus badge, upper right.
    let badgeRadius = unit * 0.155
    let badge = CGRect(x: canvas.maxX - badgeRadius * 2 - unit * 0.06,
                       y: canvas.maxY - badgeRadius * 2 - unit * 0.06,
                       width: badgeRadius * 2, height: badgeRadius * 2)
    ink.setFill()
    NSBezierPath(ovalIn: badge.insetBy(dx: -unit * 0.022, dy: -unit * 0.022)).fill()
    red.setFill()
    NSBezierPath(ovalIn: badge).fill()
    NSColor.white.setFill()
    plusPath(centre: CGPoint(x: badge.midX, y: badge.midY),
             arm: badgeRadius * 0.95, thickness: badgeRadius * 0.30).fill()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    bitmap.size = NSSize(width: side, height: side)
    return bitmap.representation(using: .png, properties: [:])
}

let directory = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for (size, name) in sizes {
    guard let data = drawIcon(size: size) else {
        FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: directory.appendingPathComponent("\(name).png"))
}

print("Wrote \(sizes.count) icon images to \(outputPath)")
