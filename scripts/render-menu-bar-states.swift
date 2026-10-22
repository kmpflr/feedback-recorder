// Renders docs/images/menu-bar-states.png: the status item in each of its states, captioned, on a
// dark menu bar. Run with `swift scripts/render-menu-bar-states.swift` from the repo root after
// changing how StatusItemController draws the item, and keep the drawing here in step with it.
import AppKit

let symbolSize = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

/// The same two-colour palette rule as `StatusItemController.recordingImage`: glyph, then disc.
func symbol(_ name: String, _ colors: [NSColor]) -> NSImage {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(symbolSize.applying(.init(paletteColors: colors)))!
    image.isTemplate = false
    return image
}

/// The same geometry as `StatusItemController.meteredImage`.
func metered(_ icon: NSImage, bars: [(fraction: CGFloat, colour: NSColor)]) -> NSImage {
    let barWidth: CGFloat = 3, barGap: CGFloat = 2, lead: CGFloat = 4, barHeight: CGFloat = 13
    let width = icon.size.width + lead + CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * barGap
    let height = max(icon.size.height, barHeight)
    return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        icon.draw(in: NSRect(x: 0, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
        var x = icon.size.width + lead
        let y = (height - barHeight) / 2
        for bar in bars {
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: barHeight), xRadius: 1, yRadius: 1).fill()
            bar.colour.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: max(1, barHeight * bar.fraction)), xRadius: 1, yRadius: 1).fill()
            x += barWidth + barGap
        }
        return true
    }
}

let blue = NSColor.systemBlue, teal = NSColor.systemTeal, orange = NSColor.systemOrange, white = NSColor.white
let states: [(image: NSImage, title: String, caption: String)] = [
    (symbol("waveform.circle", [white, white]), "Idle", "click or ⌃⌥⌘R to start"),
    (symbol("waveform.circle", [blue, blue]), "Recording", "nobody heard yet"),
    (symbol("mic.circle.fill", [white, blue]), "Recording", "only your side heard"),
    (symbol("speaker.wave.2.circle.fill", [white, blue]), "Recording", "only the other side heard"),
    (symbol("waveform.circle.fill", [white, blue]), "Recording", "both sides heard"),
    (metered(symbol("waveform.circle.fill", [white, blue]), bars: [(0.7, blue), (0.35, teal)]), "Level meters", "Me blue, Them teal"),
    (symbol("waveform.circle.fill", [white, orange]), "Needs a look", "a side may not be recording"),
    (symbol("stop.circle.fill", [NSColor(white: 0.62, alpha: 1)]), "Stopping", "finishing the transcript"),
]

let cell = NSSize(width: 150, height: 96), barHeight: CGFloat = 40
let canvas = NSSize(width: cell.width * CGFloat(states.count), height: cell.height)
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = canvas
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
NSRect(origin: .zero, size: canvas).fill()
NSColor(calibratedWhite: 0.17, alpha: 1).setFill()
NSRect(x: 0, y: canvas.height - barHeight, width: canvas.width, height: barHeight).fill()
let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(white: 0.92, alpha: 1)]
let captionAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.62, alpha: 1)]
for (i, state) in states.enumerated() {
    let x0 = cell.width * CGFloat(i)
    let size = state.image.size
    state.image.draw(in: NSRect(x: x0 + (cell.width - size.width) / 2, y: canvas.height - barHeight + (barHeight - size.height) / 2,
                                width: size.width, height: size.height))
    for (text, attrs, y) in [(state.title, titleAttrs, CGFloat(30)), (state.caption, captionAttrs, CGFloat(12))] {
        let s = NSAttributedString(string: text, attributes: attrs)
        s.draw(at: NSPoint(x: x0 + (cell.width - s.size().width) / 2, y: y))
    }
}
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/images/menu-bar-states.png"))
print("wrote docs/images/menu-bar-states.png")
