// Uso: swift scripts/make-dmg-background.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("apps/macos/Installer/dmg-background.png")
let size = NSSize(width: 642, height: 406)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1284, pixelsHigh: 812,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.06, blue: 0.19, alpha: 1),
                    NSColor(srgbRed: 0.22, green: 0.12, blue: 0.36, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: 35)

func centeredText(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (text as NSString).draw(in: NSRect(x: 32, y: y, width: 578, height: 40),
                           withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
}

centeredText("Arkangel", y: 318, font: .systemFont(ofSize: 28, weight: .semibold), color: .white)
centeredText("Arrastra Arkangel a Aplicaciones para instalar.", y: 64,
             font: .systemFont(ofSize: 17), color: .white.withAlphaComponent(0.85))

// Finder places icons from the top; AppKit draws from the bottom.
let arrowY: CGFloat = size.height - 180
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 294, y: arrowY))
arrow.line(to: NSPoint(x: 348, y: arrowY))
arrow.move(to: NSPoint(x: 338, y: arrowY + 10))
arrow.line(to: NSPoint(x: 348, y: arrowY))
arrow.line(to: NSPoint(x: 338, y: arrowY - 10))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor.white.withAlphaComponent(0.6).setStroke()
arrow.stroke()

NSGraphicsContext.current = nil
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Fondo del instalador guardado en \(output.path)")
