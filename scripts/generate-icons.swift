#!/usr/bin/env swift
/// Generates AppIcon.iconset/ at all required sizes using CoreGraphics.
/// Usage:  swift scripts/generate-icons.swift <output-dir>
import AppKit   // for NSBitmapImageRep PNG export
import Foundation

// Initialise AppKit so NSBitmapImageRep works (no dock icon, no UI)
let _app = NSApplication.shared
_app.setActivationPolicy(.prohibited)

// ─── helpers ──────────────────────────────────────────────────────────────────

func ctx(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func pngData(_ c: CGContext) -> Data {
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ c: CGContext, to path: String) {
    try! pngData(c).write(to: URL(fileURLWithPath: path))
}

// ─── app icon drawing ─────────────────────────────────────────────────────────
//
//  A single white thumbtack on graphite, on Apple's standard icon grid: the
//  body takes up 824/1024 of the canvas, leaving room for the shadow.

func drawAppIcon(_ c: CGContext, px: Int) {
    let s = CGFloat(px)
    let rgb = CGColorSpaceCreateDeviceRGB()
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                color: CGColor(gray: 0, alpha: 0.3))
    c.addPath(bodyPath)
    c.setFillColor(CGColor(gray: 0.12, alpha: 1))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(bodyPath)
    c.clip()
    let top = CGColor(red: 0.20, green: 0.20, blue: 0.21, alpha: 1)
    let bottom = CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    let gradient = CGGradient(colorsSpace: rgb, colors: [top, bottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: s / 2, y: body.maxY),
                         end: CGPoint(x: s / 2, y: body.minY), options: [])
    c.restoreGState()

    // Thumbtack, drawn upright around the centre and then tilted
    let unit = body.width
    let white = CGColor(gray: 1, alpha: 1)
    c.saveGState()
    c.translateBy(x: s / 2, y: s / 2)
    c.rotate(by: -.pi / 5.5)
    c.setFillColor(white)

    let capWidth = unit * 0.34, capHeight = unit * 0.075
    let capTop = unit * 0.31
    let cap = CGRect(x: -capWidth / 2, y: capTop - capHeight, width: capWidth, height: capHeight)
    c.addPath(CGPath(roundedRect: cap, cornerWidth: capHeight / 2, cornerHeight: capHeight / 2, transform: nil))
    c.fillPath()

    // Barrel between the cap and the collar
    let gap = unit * 0.022
    let barrelTop = cap.minY - gap
    let barrelBottom = barrelTop - unit * 0.19
    // Barrel, collar and needle as one shape, so no seams show between them
    let collarBottom = barrelBottom - unit * 0.12
    let needleWidth = unit * 0.034
    c.move(to: CGPoint(x: -unit * 0.095, y: barrelTop))
    c.addLine(to: CGPoint(x: unit * 0.095, y: barrelTop))
    c.addLine(to: CGPoint(x: unit * 0.095, y: barrelBottom))
    c.addLine(to: CGPoint(x: unit * 0.19, y: collarBottom))
    c.addLine(to: CGPoint(x: needleWidth / 2, y: collarBottom))
    c.addLine(to: CGPoint(x: 0, y: -unit * 0.40))
    c.addLine(to: CGPoint(x: -needleWidth / 2, y: collarBottom))
    c.addLine(to: CGPoint(x: -unit * 0.19, y: collarBottom))
    c.addLine(to: CGPoint(x: -unit * 0.095, y: barrelBottom))
    c.closePath()
    c.fillPath()
    c.restoreGState()
}

// ─── main ─────────────────────────────────────────────────────────────────────

let outDir      = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetPath = outDir + "/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(pts: Int, scale: Int)] = [
    (16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)
]

for (pts, scale) in sizes {
    let px  = pts * scale
    let c   = ctx(px)
    drawAppIcon(c, px: px)
    let name = scale == 1 ? "icon_\(pts)x\(pts).png" : "icon_\(pts)x\(pts)@2x.png"
    write(c, to: iconsetPath + "/" + name)
    print("  ✓ \(name)  (\(px)px)")
}

print("✓  iconset → \(iconsetPath)")
