// Generates Resources/AppIcon.icns: a white waveform on a blue rounded square, echoing the menu
// bar icon. Run with `swift scripts/make-icon.swift` from the repo root after changing it.
//
// The waveform is drawn here as plain bars rather than taken from SF Symbols: Apple's SF Symbols
// terms allow the symbols inside an app's interface but not in app icons or logos.
//
// The app is an accessory (LSUIElement), so this icon never appears in the Dock; it is what
// Finder, Spotlight and the /Applications listing show.
import AppKit

let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

/// Bar heights as a share of the tallest bar, left to right: a rise to the centre and a longer
/// fall away from it, mirrored about the midline when drawn.
let envelope: [CGFloat] = [0.28, 0.58, 0.86, 1.0, 0.72, 0.5, 0.3]

func icon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    // Apple's icon grid insets the artwork; a full-bleed square looks oversized beside stock icons.
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237          // the macOS corner-radius ratio
    NSColor.systemBlue.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

    // The bars span about two thirds of the tile's width and, at the centre, well over half its
    // height, so the waveform reads at Finder's small sizes too.
    let barWidth = rect.width * 0.062
    let gap = rect.width * 0.042
    let tallest = rect.height * 0.58
    let total = CGFloat(envelope.count) * barWidth + CGFloat(envelope.count - 1) * gap
    var x = rect.midX - total / 2
    NSColor.white.setFill()
    for share in envelope {
        let height = tallest * share
        let bar = NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    image.unlockFocus()
    return image
}

func write(_ image: NSImage, to path: String) throws {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// The sizes `iconutil` expects, each in its 1x and 2x form.
for base in [16, 32, 128, 256, 512] {
    try write(icon(size: CGFloat(base)), to: "\(iconset)/icon_\(base)x\(base).png")
    try write(icon(size: CGFloat(base * 2)), to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

try FileManager.default.removeItem(atPath: iconset)
print("wrote Resources/AppIcon.icns")
