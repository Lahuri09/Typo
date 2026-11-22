import AppKit

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 104, y: 104, width: 816, height: 816),
                        xRadius: 190, yRadius: 190)
NSGradient(starting: NSColor(srgbRed: 0.075, green: 0.13, blue: 0.22, alpha: 1),
           ending: NSColor(srgbRed: 0.018, green: 0.022, blue: 0.035, alpha: 1))!
    .draw(in: tile, angle: -53)
NSGraphicsContext.saveGraphicsState()
tile.addClip()
let context = NSGraphicsContext.current!.cgContext
func bloom(at center: CGPoint, radius: CGFloat, color: NSColor) {
    let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                              locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
}
bloom(at: CGPoint(x: 120, y: 865), radius: 690,
      color: NSColor(srgbRed: 0.13, green: 0.36, blue: 0.59, alpha: 0.80))
bloom(at: CGPoint(x: 907, y: 150), radius: 470,
      color: NSColor(srgbRed: 0.61, green: 0.23, blue: 0.095, alpha: 0.54))

let font = NSFont.systemFont(ofSize: 400, weight: .heavy)
let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 400) } ?? font
let haze = NSShadow()
haze.shadowBlurRadius = 24
haze.shadowColor = NSColor(srgbRed: 0.53, green: 0.73, blue: 1, alpha: 0.25)
let monogram = NSAttributedString(string: "КТ", attributes: [
    .font: rounded, .kern: -20, .foregroundColor: NSColor.white.withAlphaComponent(0.055), .shadow: haze
])
monogram.draw(at: NSPoint(x: (1024 - monogram.size().width) / 2, y: 305))

let wave = NSBezierPath()
let heights: [CGFloat] = [59, 117, 170, 316, 400, 266, 217, 125, 58]
let offsets: [CGFloat] = [-12, -6, 11, 4, 0, -8, -15, -6, -1]
for (index, height) in heights.enumerated() {
    let width: CGFloat = index == 0 || index == heights.count - 1 ? 28 : 40
    let rect = NSRect(x: 512 + CGFloat(index - 4) * 65 - width / 2,
                      y: 512 - height / 2 + offsets[index], width: width, height: height)
    wave.appendRoundedRect(rect, xRadius: width / 2, yRadius: width / 2)
}
NSGradient(starting: NSColor(srgbRed: 1, green: 0.90, blue: 0.73, alpha: 1),
           ending: NSColor(srgbRed: 0.97, green: 0.46, blue: 0.23, alpha: 1))!
    .draw(in: wave, angle: -75)
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.19).setStroke()
tile.lineWidth = 4
tile.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(filePath: CommandLine.arguments[1]))
