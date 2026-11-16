import AppKit

// Draws the app icon at every size an .icns needs, plus docs/icon.png for the README.
//
// A dark, softly lit squircle with a picture on it: a sunset over two hills, and the edge of the next picture peeking
// out behind, for browsing a folder.
//
// Usage: swift make-icon.swift <iconset-dir> [<readme-png>]
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// Apple's icon shape is a superellipse rather than a rounded rectangle: the curve eases into the straight edges.
func squircle(_ rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// Everything is laid out on Apple's 1024 grid and scaled to the size asked for.
func draw(in ctx: CGContext) {
    // Body: 824 × 824, centred, with the standard drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x15161D))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    // Deep graphite, a little lighter at the top, like light falling on glass.
    ctx.drawLinearGradient(gradient([color(0x3A3D4E), color(0x1E1F29), color(0x111218)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)]),
                           startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()

    // A fine rim, brighter along the top edge.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.30), color(0xFFFFFF, 0.04), color(0xFFFFFF, 0.10)], [0, 0.6, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The picture, about 3:2. It sits a little left of and below centre, so with the one behind it the pair is centred.
    let photo = CGRect(x: 512 - 280 - 18, y: 512 - 186 - 16, width: 560, height: 372)
    let corner: CGFloat = 34

    // The next picture, peeking out behind and to the right.
    ctx.saveGState()
    ctx.translateBy(x: photo.midX + 40, y: photo.midY + 34)
    ctx.rotate(by: -0.12)
    let behind = CGRect(x: -photo.width / 2, y: -photo.height / 2, width: photo.width, height: photo.height)
    ctx.addPath(CGPath(roundedRect: behind, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.16))
    ctx.fillPath()
    ctx.restoreGState()

    let photoPath = CGPath(roundedRect: photo, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.5))
    ctx.addPath(photoPath)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(photoPath)
    ctx.clip()
    // Sky: a warm sunset.
    ctx.drawLinearGradient(gradient([color(0xFF5F6D), color(0xFF9A5A), color(0xFFC977)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: photo.minY), options: [])
    // Sun.
    let sun = CGPoint(x: photo.midX + 100, y: photo.minY + 166)
    ctx.drawRadialGradient(gradient([color(0xFFF4D6, 0.9), color(0xFFF4D6, 0)]),
                           startCenter: sun, startRadius: 40, endCenter: sun, endRadius: 140, options: [])
    ctx.setFillColor(color(0xFFF7E4))
    ctx.fillEllipse(in: CGRect(x: sun.x - 46, y: sun.y - 46, width: 92, height: 92))
    // Far hill.
    let far = CGMutablePath()
    far.move(to: CGPoint(x: photo.minX, y: photo.minY + 110))
    far.addCurve(to: CGPoint(x: photo.maxX, y: photo.minY + 150),
                 control1: CGPoint(x: photo.minX + 200, y: photo.minY + 250),
                 control2: CGPoint(x: photo.minX + 360, y: photo.minY + 60))
    far.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
    far.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
    far.closeSubpath()
    ctx.addPath(far)
    ctx.setFillColor(color(0x8E3B5C))
    ctx.fillPath()
    // Near hill.
    let near = CGMutablePath()
    near.move(to: CGPoint(x: photo.minX, y: photo.minY + 40))
    near.addCurve(to: CGPoint(x: photo.maxX, y: photo.minY + 90),
                  control1: CGPoint(x: photo.minX + 170, y: photo.minY + 30),
                  control2: CGPoint(x: photo.minX + 330, y: photo.minY + 200))
    near.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
    near.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
    near.closeSubpath()
    ctx.addPath(near)
    ctx.setFillColor(color(0x3B2140))
    ctx.fillPath()
    ctx.restoreGState()

    // A thin light edge on the picture.
    ctx.addPath(photoPath)
    ctx.setLineWidth(3)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.strokePath()
}

func render(_ size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(size).write(to: output.appendingPathComponent("icon_\(name).png"))
}
if CommandLine.arguments.count > 2 {
    try! render(512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
