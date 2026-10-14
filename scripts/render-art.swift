// Renders the app icon and the DMG window background into assets/.
// Run scripts/render-art.sh rather than this file directly.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"

let teal = NSColor(red: 0.16, green: 0.71, blue: 0.75, alpha: 1)
let indigo = NSColor(red: 0.29, green: 0.31, blue: 0.80, alpha: 1)

func render(width: Int, height: Int, to path: String, draw: (CGSize) -> Void) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGSize(width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        .applying(.init(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func drawCentered(_ image: NSImage, at center: CGPoint) {
    let size = image.size
    image.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
}

// App icon: macOS-style rounded square with a white ear and sound waves.
func drawIcon(_ size: CGSize) {
    let scale = size.width / 1024
    // Apple's icon grid: 824pt body inside a 1024pt canvas.
    let body = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.set()
    NSGradient(starting: teal, ending: indigo)!.draw(in: shape, angle: -60)
    NSGraphicsContext.restoreGraphicsState()

    // Soft highlight across the top half.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.18)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    drawCentered(symbol("ear.and.waveform", pointSize: 430 * scale, color: .white), at: CGPoint(x: body.midX, y: body.midY))
}

// DMG background. Finder places the icons at (180, 215) and (480, 215) from the top-left of a 660x400 window.
func drawBackground(_ size: CGSize) {
    let scale = size.width / 660
    let rect = CGRect(origin: .zero, size: size)

    NSGradient(
        starting: NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1),
        ending: NSColor(red: 0.89, green: 0.93, blue: 0.98, alpha: 1)
    )!.draw(in: rect, angle: -90)

    // Faint brand glow behind each icon slot.
    for x in [180.0, 480.0] {
        let center = CGPoint(x: x * scale, y: (400 - 215) * scale)
        let glow = NSGradient(colors: [teal.withAlphaComponent(0.12), teal.withAlphaComponent(0)])!
        glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: 120 * scale, options: [])
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let title = NSAttributedString(string: "Install OpenEar", attributes: [
        .font: NSFont.systemFont(ofSize: 26 * scale, weight: .bold),
        .foregroundColor: NSColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    title.draw(in: CGRect(x: 0, y: (400 - 70) * scale, width: size.width, height: 36 * scale))

    let subtitle = NSAttributedString(string: "Drag OpenEar into your Applications folder", attributes: [
        .font: NSFont.systemFont(ofSize: 14 * scale, weight: .regular),
        .foregroundColor: NSColor(red: 0.35, green: 0.38, blue: 0.48, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    subtitle.draw(in: CGRect(x: 0, y: (400 - 98) * scale, width: size.width, height: 22 * scale))

    // Dashed arrow from the app to Applications.
    let y = (400 - 205) * scale
    let arrowColor = indigo.withAlphaComponent(0.55)
    arrowColor.set()
    let line = NSBezierPath()
    line.move(to: CGPoint(x: 262 * scale, y: y))
    line.line(to: CGPoint(x: 388 * scale, y: y))
    line.lineWidth = 4 * scale
    line.lineCapStyle = .round
    line.setLineDash([10 * scale, 9 * scale], count: 2, phase: 0)
    line.stroke()

    let head = NSBezierPath()
    head.move(to: CGPoint(x: 384 * scale, y: y + 13 * scale))
    head.line(to: CGPoint(x: 400 * scale, y: y))
    head.line(to: CGPoint(x: 384 * scale, y: y - 13 * scale))
    head.lineWidth = 4 * scale
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let footer = NSAttributedString(string: "First launch: System Settings › Privacy & Security › Open Anyway", attributes: [
        .font: NSFont.systemFont(ofSize: 11 * scale, weight: .regular),
        .foregroundColor: NSColor(red: 0.45, green: 0.48, blue: 0.56, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    footer.draw(in: CGRect(x: 0, y: 26 * scale, width: size.width, height: 18 * scale))
}

render(width: 1024, height: 1024, to: "\(outDir)/icon-1024.png", draw: drawIcon)
render(width: 660, height: 400, to: "\(outDir)/dmg-background.png", draw: drawBackground)
render(width: 1320, height: 800, to: "\(outDir)/dmg-background@2x.png", draw: drawBackground)
