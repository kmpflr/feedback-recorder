// Draws the entirely synthetic editor used by the walkthrough; never captures the desktop.
// Run from the repository root: swift scripts/render-demo.swift
import AppKit

let canvas = NSSize(width: 1000, height: 620)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1240,
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = canvas
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func box(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 15,
          weight: NSFont.Weight = .regular, color: NSColor = NSColor(white: 0.15, alpha: 1)) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
box(NSRect(origin: .zero, size: canvas), NSColor(white: 0.94, alpha: 1))
text("SYNTHETIC REVIEW EXAMPLE", x: 42, y: 578, size: 12, weight: .semibold,
     color: NSColor(white: 0.4, alpha: 1))
box(NSRect(x: 30, y: 35, width: 940, height: 510), .white, radius: 14)
box(NSRect(x: 30, y: 495, width: 940, height: 50), NSColor(white: 0.975, alpha: 1), radius: 14)
text("Workbench", x: 55, y: 510, size: 17, weight: .semibold)
text("Parts editor", x: 220, y: 510)
text("Example data only", x: 805, y: 512, size: 12, color: .gray)
text("Parts", x: 60, y: 444, size: 27, weight: .bold)
text("Choose a workspace before saving changes.", x: 60, y: 416, size: 14, color: .gray)
text("Workspace", x: 60, y: 372, size: 12, weight: .semibold)
box(NSRect(x: 60, y: 325, width: 490, height: 38), NSColor(white: 0.96, alpha: 1), radius: 6)
text("Choose workspace…", x: 74, y: 336, color: .gray)
box(NSRect(x: 840, y: 325, width: 90, height: 38), .systemBlue, radius: 7)
text("Save", x: 864, y: 336, size: 15, weight: .semibold, color: .white)
text("The enabled Save button is the bug discussed in the sample transcript.", x: 60, y: 294,
     size: 12, color: NSColor(white: 0.4, alpha: 1))
box(NSRect(x: 60, y: 236, width: 870, height: 36), NSColor(white: 0.965, alpha: 1), radius: 4)
text("Part", x: 75, y: 248, size: 12, weight: .semibold)
text("Description", x: 245, y: 248, size: 12, weight: .semibold)
text("Quantity", x: 795, y: 248, size: 12, weight: .semibold)
let rows = [("P-101", "Example mounting bracket", "12"),
            ("P-102", "Example panel fastener", "24"),
            ("P-103", "Example support plate", "8")]
for (index, row) in rows.enumerated() {
    let y = CGFloat(200 - index * 45)
    box(NSRect(x: 60, y: y - 9, width: 870, height: 1), NSColor(white: 0.92, alpha: 1))
    text(row.0, x: 75, y: y)
    text(row.1, x: 245, y: y)
    text(row.2, x: 810, y: y)
}
text("Illustration of an imaginary application, not a real customer screenshot.",
     x: 60, y: 64, size: 12, color: .gray)
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: "skill/tests/fixtures/session/shots/001.png")
try rep.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote synthetic walkthrough image")
