#!/usr/bin/env swift
//
// Renders the SpeakClean app-icon artwork to a 1024x1024 PNG.
//
// Usage: swift scripts/render-icon.swift <output-path>
//
// Composition matches docs/superpowers/specs/2026-04-23-app-icon-design.md:
//   - 1024x1024 canvas with ~100 px transparent bleed
//   - 824x824 squircle centered, continuous (Apple Big Sur+) corner
//   - #ffffff -> #c9ccd2 vertical gradient clipped to the squircle
//   - Glyph from MenuBarIcon.idle (I-beam + 4-bar waveform), 36-unit coord
//     system mapped linearly onto a 560x560 inner region.

import AppKit
import SwiftUI

let canvas: CGFloat = 1024
let squircle: CGFloat = 824
let squircleRadius: CGFloat = 185   // ~22.5% of 824 — matches continuous-style macOS app icon curvature
let glyphBox: CGFloat = 560
let menuUnit: CGFloat = 36        // menu-bar icon coordinate system
let strokeWidth: CGFloat = 2.5 * (glyphBox / menuUnit)  // ≈ 38.9 at 1024

struct IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: squircleRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 1.0, blue: 1.0),
                        Color(red: 0xc9/255.0, green: 0xcc/255.0, blue: 0xd2/255.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: squircle, height: squircle)

            Glyph()
                .frame(width: glyphBox, height: glyphBox)
        }
        .frame(width: canvas, height: canvas)
    }
}

struct Glyph: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let s = geo.size.width / menuUnit
                // MenuBarIcon uses bottom-up coords; SwiftUI is top-down. Flip y.
                func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                    CGPoint(x: x * s, y: (menuUnit - y) * s)
                }

                // I-beam text cursor (matches MenuBarIcon.idle)
                path.move(to: p(6, 6));  path.addLine(to: p(6, 30))
                path.move(to: p(2, 6));  path.addLine(to: p(10, 6))
                path.move(to: p(2, 30)); path.addLine(to: p(10, 30))

                // 4-bar waveform (matches MenuBarIcon.idle)
                let bars: [(CGFloat, CGFloat, CGFloat)] = [
                    (16, 14, 22), (21, 8, 28), (26, 11, 25), (31, 14, 22),
                ]
                for bar in bars {
                    path.move(to: p(bar.0, bar.1))
                    path.addLine(to: p(bar.0, bar.2))
                }
            }
            .stroke(
                Color(red: 0x11/255.0, green: 0x11/255.0, blue: 0x11/255.0),
                style: StrokeStyle(
                    lineWidth: strokeWidth * geo.size.width / glyphBox,
                    lineCap: .round
                )
            )
        }
    }
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: render-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(2)
}
let outputPath = CommandLine.arguments[1]

@MainActor
func render(to path: String) throws {
    let renderer = ImageRenderer(content: IconView())
    renderer.scale = 1.0

    guard let cgImage = renderer.cgImage else {
        FileHandle.standardError.write("ImageRenderer returned no CGImage\n".data(using: .utf8)!)
        exit(1)
    }

    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG encoding failed\n".data(using: .utf8)!)
        exit(1)
    }

    try pngData.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(cgImage.width)x\(cgImage.height))")
}

MainActor.assumeIsolated {
    do {
        try render(to: outputPath)
    } catch {
        FileHandle.standardError.write("render failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
