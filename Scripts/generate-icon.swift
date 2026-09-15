// Run from the repository root with: swift Scripts/generate-icon.swift
// Uses the same SF Symbol as the native Control Center control.
import AppKit

let output = URL(fileURLWithPath: "build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.62, blue: 1, alpha: 1),
                   ending: NSColor(srgbRed: 0.02, green: 0.30, blue: 0.88, alpha: 1))!
            .draw(in: tile, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: 540, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        let symbolSize = symbol.size
        let fit = min(650 / symbolSize.width, 610 / symbolSize.height)
        let width = symbolSize.width * fit
        let height = symbolSize.height * fit
        symbol.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2,
                              width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", output.path, "-o", "Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "iconutil failed")
