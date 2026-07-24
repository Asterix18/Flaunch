#!/usr/bin/env swift
// Generates a 1024x1024 PNG app icon using AppKit/Core Graphics.
// A crisp SF Symbol is rendered (as a vector) onto a warm gradient tile, so it
// stays sharp at every iconset size instead of softening like drawn text did.
// Usage: swift generate-icon.swift <output.png>
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: generate-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let dimension: CGFloat = 1024
let canvas = CGSize(width: dimension, height: dimension)

let image = NSImage(size: canvas)
image.lockFocus()

// MARK: Rounded square clip
let cornerRadius: CGFloat = 230   // matches Apple's ~22.5% rule for macOS icons
let bounds = CGRect(origin: .zero, size: canvas)
let clipPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
clipPath.addClip()

// MARK: Gradient background (Claude-ish warm orange)
let topColor    = NSColor(red: 0.98, green: 0.62, blue: 0.34, alpha: 1.0)
let bottomColor = NSColor(red: 0.80, green: 0.30, blue: 0.16, alpha: 1.0)
NSGradient(starting: topColor, ending: bottomColor)!.draw(in: bounds, angle: -90)

// MARK: Crisp SF Symbol, tinted white and centered
let symbolName = "terminal"
let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)
guard let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
    FileHandle.standardError.write("failed to load SF Symbol '\(symbolName)'\n".data(using: .utf8)!)
    exit(1)
}

// Tint the (template) symbol white by compositing a white fill over its shape.
let symbolSize = baseSymbol.size
let whiteSymbol = NSImage(size: symbolSize)
whiteSymbol.lockFocus()
baseSymbol.draw(in: CGRect(origin: .zero, size: symbolSize))
NSColor.white.set()
CGRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
whiteSymbol.unlockFocus()

let symbolOrigin = CGPoint(
    x: (dimension - symbolSize.width) / 2,
    y: (dimension - symbolSize.height) / 2
)
whiteSymbol.draw(at: symbolOrigin, from: .zero, operation: .sourceOver, fraction: 1.0)

image.unlockFocus()

// MARK: Encode as PNG and write to disk
guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}

let outURL = URL(fileURLWithPath: outputPath)
try png.write(to: outURL)
print("wrote \(outURL.path)")
