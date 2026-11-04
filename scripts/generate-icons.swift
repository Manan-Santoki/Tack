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
//  A white clipboard with two text lines on graphite, on Apple's standard icon grid: the
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

    // Board
    let boardWidth = body.width * 0.46
    let boardHeight = body.width * 0.58
    let board = CGRect(x: s / 2 - boardWidth / 2, y: s / 2 - boardHeight / 2 - s * 0.015,
                       width: boardWidth, height: boardHeight)
    let boardRadius = boardWidth * 0.17
    let white = CGColor(gray: 1, alpha: 1)
    let ink = CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    c.addPath(CGPath(roundedRect: board, cornerWidth: boardRadius, cornerHeight: boardRadius, transform: nil))
    c.setFillColor(white)
    c.fillPath()

    // Clip, set off from the board by a gap in the background colour
    let clipWidth = boardWidth * 0.46
    let clipHeight = boardWidth * 0.20
    let clip = CGRect(x: board.midX - clipWidth / 2, y: board.maxY - clipHeight * 0.45,
                      width: clipWidth, height: clipHeight)
    let gap = boardWidth * 0.055
    let halo = clip.insetBy(dx: -gap, dy: -gap)
    c.addPath(CGPath(roundedRect: halo, cornerWidth: halo.height / 2, cornerHeight: halo.height / 2, transform: nil))
    c.setFillColor(CGColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1))
    c.fillPath()
    c.addPath(CGPath(roundedRect: clip, cornerWidth: clip.height / 2, cornerHeight: clip.height / 2, transform: nil))
    c.setFillColor(white)
    c.fillPath()

    // Two text lines
    let lineHeight = boardWidth * 0.085
    for (index, fraction) in [1.0, 0.62].enumerated() {
        let line = CGRect(x: board.minX + boardWidth * 0.22,
                          y: board.midY - boardHeight * 0.02 - CGFloat(index) * lineHeight * 2.6,
                          width: boardWidth * 0.56 * fraction, height: lineHeight)
        c.addPath(CGPath(roundedRect: line, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        c.setFillColor(ink)
        c.fillPath()
    }
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
