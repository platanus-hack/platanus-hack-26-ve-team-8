// Genera el icono de la app en apps/macos/Icon/AppIcon.icns (más una vista previa PNG). Uso: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("apps/macos/Icon/AppIcon.icns")

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Cuadrícula de macOS de Apple: cuerpo de 824 pt con margen de 100 pt en un lienzo de 1024 pt.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.08, blue: 0.20, alpha: 1),
                        NSColor(srgbRed: 0.16, green: 0.25, blue: 0.62, alpha: 1)])!
        .draw(in: tile, angle: 90)

    let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let size = symbol.size
    symbol.draw(in: NSRect(x: (CGFloat(px) - size.width) / 2, y: (CGFloat(px) - size.height) / 2,
                           width: size.width, height: size.height))
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try render(1024).write(to: output.deletingPathExtension().appendingPathExtension("png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(output.path)
