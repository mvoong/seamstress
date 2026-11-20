#!/usr/bin/env swift
import Cocoa
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func render(size px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let inset = s * 0.08
    let card = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = s * 0.22
    let cardPath = CGPath(roundedRect: card, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Deep slate gradient background
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let bgColors = [
        CGColor(red: 0.11, green: 0.13, blue: 0.18, alpha: 1),
        CGColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Subtle pane tiles inside
    let pad = s * 0.16
    let inner = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let splitX = inner.minX + inner.width * 0.52
    let splitY = inner.minY + inner.height * 0.48
    let paneRadius = max(2, s * 0.04)

    let leftPane = CGRect(x: inner.minX, y: inner.minY, width: splitX - inner.minX - s * 0.025, height: inner.height)
    let topRight = CGRect(x: splitX + s * 0.025, y: splitY + s * 0.025, width: inner.maxX - splitX - s * 0.025, height: inner.maxY - splitY - s * 0.025)
    let botRight = CGRect(x: splitX + s * 0.025, y: inner.minY, width: inner.maxX - splitX - s * 0.025, height: splitY - inner.minY - s * 0.025)

    ctx.setFillColor(CGColor(red: 0.22, green: 0.62, blue: 0.98, alpha: 0.28))
    ctx.addPath(CGPath(roundedRect: leftPane, cornerWidth: paneRadius, cornerHeight: paneRadius, transform: nil))
    ctx.fillPath()

    ctx.setFillColor(CGColor(red: 0.40, green: 0.78, blue: 1.0, alpha: 0.22))
    ctx.addPath(CGPath(roundedRect: topRight, cornerWidth: paneRadius, cornerHeight: paneRadius, transform: nil))
    ctx.fillPath()

    ctx.setFillColor(CGColor(red: 0.62, green: 0.48, blue: 0.98, alpha: 0.24))
    ctx.addPath(CGPath(roundedRect: botRight, cornerWidth: paneRadius, cornerHeight: paneRadius, transform: nil))
    ctx.fillPath()

    // Glowing vertical & horizontal seam lines
    let seamWidth = max(1.5, s * 0.024)
    ctx.setStrokeColor(CGColor(red: 0.34, green: 0.80, blue: 1.0, alpha: 0.95))
    ctx.setLineWidth(seamWidth)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: splitX, y: inner.minY))
    ctx.addLine(to: CGPoint(x: splitX, y: inner.maxY))
    ctx.move(to: CGPoint(x: splitX, y: splitY))
    ctx.addLine(to: CGPoint(x: inner.maxX, y: splitY))
    ctx.strokePath()

    // Center grip pill on the main seam
    let pillW = max(3, s * 0.055)
    let pillH = max(8, s * 0.20)
    let pill = CGRect(x: splitX - pillW * 0.5, y: inner.midY - pillH * 0.5, width: pillW, height: pillH)
    ctx.setFillColor(CGColor(red: 0.94, green: 0.98, blue: 1.0, alpha: 0.98))
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pillW * 0.5, cornerHeight: pillW * 0.5, transform: nil))
    ctx.fillPath()

    ctx.restoreGState()

    // Subtle crisp outer rim
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.addPath(cardPath)
    ctx.strokePath()

    let cgImg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in specs {
    try render(size: px).write(to: outDir.appendingPathComponent(name))
}
