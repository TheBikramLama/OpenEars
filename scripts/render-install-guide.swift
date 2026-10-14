// Draws assets/install-guide.gif: an illustrated walkthrough of opening an app macOS couldn't verify.
// Run scripts/render-art.sh rather than this file directly.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments[1]
let appIcon = NSImage(contentsOfFile: CommandLine.arguments[2])!

let W: CGFloat = 800
let H: CGFloat = 500
let scale: CGFloat = 2
let stageHeight: CGFloat = 430 // Everything above the caption bar.

// Flat colours keep the GIF palette clean.
func gray(_ white: CGFloat) -> NSColor { NSColor(white: white, alpha: 1) }
let desktop = NSColor(red: 0.12, green: 0.13, blue: 0.18, alpha: 1)
let windowFill = gray(0.17)
let sidebarFill = gray(0.14)
let cardFill = gray(0.22)
let buttonFill = gray(0.31)
let blue = NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1)
let teal = NSColor(red: 0.16, green: 0.71, blue: 0.75, alpha: 1)
let textPrimary = gray(0.95)
let textSecondary = gray(0.65)

// MARK: Drawing helpers (top-left origin)

func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func stroke(_ rect: CGRect, _ color: NSColor, radius: CGFloat, width: CGFloat) {
    color.setStroke()
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.lineWidth = width
    path.stroke()
}

func text(_ string: String, _ rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = textPrimary, align: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 2
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]).draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
}

func image(_ image: NSImage, _ rect: CGRect) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func symbol(_ name: String, size: CGFloat, color: NSColor? = nil, multicolor: Bool = false) -> NSImage {
    var config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    if multicolor { config = config.applying(.preferringMulticolor()) }
    if let color { config = config.applying(.init(paletteColors: [color])) }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

func symbol(_ name: String, centeredIn rect: CGRect, size: CGFloat, color: NSColor? = nil, multicolor: Bool = false) {
    let img = symbol(name, size: size, color: color, multicolor: multicolor)
    image(img, CGRect(x: rect.midX - img.size.width / 2, y: rect.midY - img.size.height / 2,
                      width: img.size.width, height: img.size.height))
}

func button(_ title: String, _ rect: CGRect, color: NSColor = buttonFill, size: CGFloat = 13) {
    fill(rect, color, radius: rect.height / 2)
    text(title, CGRect(x: rect.minX, y: rect.midY - size * 0.62, width: rect.width, height: size * 1.5),
         size: size, weight: .medium, align: .center)
}

func highlight(_ rect: CGRect, radius: CGFloat? = nil) {
    let ring = rect.insetBy(dx: -5, dy: -5)
    stroke(ring, blue.withAlphaComponent(0.35), radius: radius ?? ring.height / 2, width: 7)
    stroke(ring, blue, radius: radius ?? ring.height / 2, width: 2.5)
}

// Drawn by hand: NSCursor's image isn't available to a command-line script.
func cursor(on rect: CGRect) {
    let tip = CGPoint(x: rect.midX + rect.width * 0.18, y: rect.midY + 2)
    let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4.5, 13), (7.5, 20), (10, 19), (7, 12.5), (12.5, 12.5)]
    let arrow = NSBezierPath()
    for (i, point) in points.enumerated() {
        let p = CGPoint(x: tip.x + point.0 * 1.3, y: tip.y + point.1 * 1.3)
        if i == 0 { arrow.move(to: p) } else { arrow.line(to: p) }
    }
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 1.5
    NSColor.black.setFill()
    arrow.fill()
    NSColor.white.setStroke()
    arrow.stroke()
}

func appIconWithWarning(at origin: CGPoint) {
    image(appIcon, CGRect(x: origin.x - 6, y: origin.y - 6, width: 76, height: 76))
    symbol("exclamationmark.triangle.fill", centeredIn: CGRect(x: origin.x + 40, y: origin.y + 38, width: 30, height: 30),
           size: 24, multicolor: true)
}

func caption(step: Int, _ string: String) {
    fill(CGRect(x: 0, y: stageHeight, width: W, height: H - stageHeight), gray(0.07))
    let pill = CGRect(x: 24, y: stageHeight + 21, width: 92, height: 28)
    fill(pill, blue, radius: 14)
    text("Step \(step) of 5", CGRect(x: pill.minX, y: pill.minY + 5, width: pill.width, height: 20),
         size: 13, weight: .semibold, align: .center)
    text(string, CGRect(x: 132, y: stageHeight + 23, width: W - 156, height: 26), size: 16, weight: .medium)
}

func dialog(_ rect: CGRect) {
    fill(rect, windowFill, radius: 18)
    stroke(rect, gray(0.32), radius: 18, width: 1)
}

// MARK: Scenes

let blockedMessage = "Apple could not verify “OpenEar” is free of malware that may harm your Mac or compromise your privacy."

func notOpenedScene(active: Bool) {
    fill(CGRect(x: 0, y: 0, width: W, height: stageHeight), desktop)
    let box = CGRect(x: 260, y: 64, width: 280, height: 300)
    dialog(box)
    appIconWithWarning(at: CGPoint(x: 284, y: 88))
    text("“OpenEar” Not Opened", CGRect(x: 284, y: 172, width: 240, height: 22), size: 15, weight: .bold)
    text(blockedMessage, CGRect(x: 284, y: 198, width: 236, height: 80), size: 12.5, color: textSecondary)
    button("Move to Trash", CGRect(x: 276, y: 282, width: 248, height: 30))
    let done = CGRect(x: 276, y: 320, width: 248, height: 30)
    button("Done", done)
    if active {
        highlight(done)
        cursor(on: done)
    }
    caption(step: 1, "Click Done. Not Move to Trash")
}

let openAnywayButton = CGRect(x: 566, y: 186, width: 112, height: 28)

func settingsWindow(highlightOpenAnyway: Bool) {
    fill(CGRect(x: 0, y: 0, width: W, height: stageHeight), desktop)
    let window = CGRect(x: 90, y: 36, width: 620, height: 364)
    fill(window, windowFill, radius: 12)
    fill(CGRect(x: window.minX, y: window.minY, width: 184, height: window.height), sidebarFill, radius: 12)
    fill(CGRect(x: window.minX + 172, y: window.minY, width: 12, height: window.height), sidebarFill)
    stroke(window, gray(0.3), radius: 12, width: 1)

    for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        fill(CGRect(x: 106 + CGFloat(i) * 20, y: 52, width: 12, height: 12), color, radius: 6)
    }
    fill(CGRect(x: 104, y: 76, width: 156, height: 24), gray(0.22), radius: 7)
    symbol("magnifyingglass", centeredIn: CGRect(x: 108, y: 76, width: 20, height: 24), size: 11, color: textSecondary)
    text("Search", CGRect(x: 130, y: 80, width: 100, height: 18), size: 12, color: textSecondary)

    let items: [(String, String, NSColor)] = [
        ("General", "gearshape.fill", .systemGray),
        ("Appearance", "circle.lefthalf.filled", .darkGray),
        ("Accessibility", "accessibility", .systemBlue),
        ("Control Center", "switch.2", .systemGray),
        ("Desktop & Dock", "dock.rectangle", .darkGray),
        ("Displays", "sun.max.fill", .systemBlue),
        ("Privacy & Security", "hand.raised.fill", .systemBlue),
        ("Touch ID & Password", "touchid", .systemPink),
        ("Users & Groups", "person.2.fill", .systemBlue),
    ]
    for (i, item) in items.enumerated() {
        let y = 114 + CGFloat(i) * 30
        if item.0 == "Privacy & Security" {
            fill(CGRect(x: 100, y: y - 4, width: 164, height: 26), blue, radius: 7)
        }
        let tile = CGRect(x: 108, y: y, width: 18, height: 18)
        fill(tile, item.2, radius: 5)
        symbol(item.1, centeredIn: tile, size: 10, color: .white)
        text(item.0, CGRect(x: 134, y: y + 1, width: 128, height: 18), size: 12.5)
    }

    text("Privacy & Security", CGRect(x: 292, y: 50, width: 300, height: 22), size: 15, weight: .bold)
    text("Security", CGRect(x: 292, y: 96, width: 200, height: 18), size: 12, weight: .semibold, color: textSecondary)

    let card = CGRect(x: 290, y: 120, width: 400, height: 112)
    fill(card, cardFill, radius: 10)
    text("Allow applications from", CGRect(x: 306, y: 134, width: 200, height: 18), size: 13)
    text("App Store & Known Developers", CGRect(x: 480, y: 135, width: 196, height: 18), size: 12,
         color: textSecondary, align: .right)
    fill(CGRect(x: 306, y: 166, width: 368, height: 1), gray(0.3))
    text("“OpenEar” was blocked to protect your Mac.", CGRect(x: 306, y: 184, width: 240, height: 40), size: 13)
    button("Open Anyway", openAnywayButton, size: 12.5)

    let fileVault = CGRect(x: 290, y: 248, width: 400, height: 44)
    fill(fileVault, cardFill, radius: 10)
    text("FileVault", CGRect(x: 306, y: 261, width: 200, height: 18), size: 13)
    text("Off", CGRect(x: 600, y: 262, width: 74, height: 18), size: 12, color: textSecondary, align: .right)

    if highlightOpenAnyway {
        highlight(openAnywayButton)
        cursor(on: openAnywayButton)
    }
}

func dimmedSettings() {
    settingsWindow(highlightOpenAnyway: false)
    fill(CGRect(x: 0, y: 0, width: W, height: stageHeight), NSColor.black.withAlphaComponent(0.5))
}

func settingsScene(active: Bool) {
    settingsWindow(highlightOpenAnyway: active)
    caption(step: 2, "System Settings › Privacy & Security. Scroll down, click Open Anyway")
}

func confirmScene(active: Bool) {
    dimmedSettings()
    let box = CGRect(x: 260, y: 64, width: 280, height: 300)
    dialog(box)
    appIconWithWarning(at: CGPoint(x: 284, y: 88))
    text("Open “OpenEar”?", CGRect(x: 284, y: 172, width: 240, height: 22), size: 15, weight: .bold)
    text(blockedMessage, CGRect(x: 284, y: 198, width: 236, height: 80), size: 12.5, color: textSecondary)
    let openAnyway = CGRect(x: 276, y: 282, width: 248, height: 30)
    button("Open Anyway", openAnyway)
    button("Done", CGRect(x: 276, y: 320, width: 248, height: 30))
    if active {
        highlight(openAnyway)
        cursor(on: openAnyway)
    }
    caption(step: 3, "Click Open Anyway again")
}

func authScene(active: Bool) {
    dimmedSettings()
    let box = CGRect(x: 270, y: 64, width: 260, height: 300)
    dialog(box)
    let fingerprint = CGRect(x: 366, y: 88, width: 68, height: 68)
    symbol("touchid", centeredIn: fingerprint, size: 52, color: .systemPink)
    text("Privacy & Security", CGRect(x: 286, y: 170, width: 228, height: 22), size: 15, weight: .bold, align: .center)
    text("Touch ID or enter your password to allow this.", CGRect(x: 296, y: 196, width: 208, height: 40),
         size: 12.5, color: textSecondary, align: .center)
    button("Use Password…", CGRect(x: 286, y: 282, width: 228, height: 30))
    button("Cancel", CGRect(x: 286, y: 320, width: 228, height: 30))
    if active { highlight(fingerprint, radius: 22) }
    caption(step: 4, "Confirm with Touch ID or your password")
}

func doneScene(active: Bool) {
    fill(CGRect(x: 0, y: 0, width: W, height: stageHeight), desktop)

    // Menu bar
    fill(CGRect(x: 0, y: 0, width: W, height: 26), gray(0.2))
    symbol("apple.logo", centeredIn: CGRect(x: 10, y: 0, width: 24, height: 26), size: 13, color: textPrimary)
    text("Finder", CGRect(x: 40, y: 5, width: 80, height: 18), size: 13, weight: .bold)
    text("Thu 9:41", CGRect(x: W - 92, y: 5, width: 80, height: 18), size: 13, align: .right)
    symbol("battery.75percent", centeredIn: CGRect(x: W - 136, y: 0, width: 30, height: 26), size: 13, color: textPrimary)
    symbol("wifi", centeredIn: CGRect(x: W - 166, y: 0, width: 26, height: 26), size: 13, color: textPrimary)
    let ear = CGRect(x: W - 200, y: 1, width: 28, height: 24)
    if active { fill(ear, gray(0.35), radius: 5) }
    symbol(active ? "ear.fill" : "ear", centeredIn: ear, size: 14, color: active ? teal : textPrimary)

    // OpenEar menu
    let menu = CGRect(x: W - 330, y: 34, width: 300, height: 128)
    if active {
        fill(menu, windowFill, radius: 12)
        stroke(menu, gray(0.32), radius: 12, width: 1)
        text("On, no time limit", CGRect(x: menu.minX + 16, y: menu.minY + 16, width: 200, height: 20), size: 14, weight: .bold)
        let toggle = CGRect(x: menu.maxX - 54, y: menu.minY + 14, width: 38, height: 22)
        fill(toggle, .systemGreen, radius: 11)
        fill(CGRect(x: toggle.maxX - 20, y: toggle.minY + 2, width: 18, height: 18), .white, radius: 9)
        for (i, label) in ["15m", "30m", "1h", "∞"].enumerated() {
            let chip = CGRect(x: menu.minX + 16 + CGFloat(i) * 68, y: menu.minY + 56, width: 60, height: 28)
            button(label, chip, color: label == "∞" ? blue : buttonFill, size: 12.5)
        }
        text("Listening through MacBook Pro Microphone", CGRect(x: menu.minX + 16, y: menu.minY + 100, width: 270, height: 18),
             size: 11.5, color: textSecondary)
    } else {
        cursor(on: ear)
    }

    image(appIcon, CGRect(x: 60, y: 160, width: 120, height: 120))
    text("OpenEar is ready", CGRect(x: 196, y: 186, width: 300, height: 34), size: 28, weight: .bold)
    text("Find it in your menu bar", CGRect(x: 198, y: 224, width: 300, height: 22), size: 15, color: textSecondary)

    caption(step: 5, "Done! Click the ear in the menu bar, then allow microphone access")
}

// MARK: Render

func renderFrame(_ draw: () -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: H * scale)
    context.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

let scenes: [(Bool) -> Void] = [notOpenedScene, settingsScene, confirmScene, authScene, doneScene]
var frames: [(image: CGImage, delay: Double)] = []
for (i, scene) in scenes.enumerated() {
    frames.append((renderFrame { scene(false) }, 1.0))
    frames.append((renderFrame { scene(true) }, i == scenes.count - 1 ? 4.0 : 2.4))
}

let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: output) as CFURL, UTType.gif.identifier as CFString, frames.count, nil
)!
CGImageDestinationSetProperties(destination, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)
for frame in frames {
    CGImageDestinationAddImage(destination, frame.image, [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: frame.delay,
            kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
        ],
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(output)") }
