import AppKit

let size = NSSize(width: 640, height: 380)
let image = NSImage(size: size)
image.lockFocus()
let bounds = NSRect(origin: .zero, size: size)
NSGradient(
    starting: NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.14, alpha: 1),
    ending: NSColor(calibratedRed: 0.17, green: 0.24, blue: 0.21, alpha: 1)
)!.draw(in: bounds, angle: -20)

let arrow = NSBezierPath()
arrow.lineWidth = 10
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 266, y: 180))
arrow.line(to: NSPoint(x: 373, y: 180))
arrow.move(to: NSPoint(x: 345, y: 207))
arrow.line(to: NSPoint(x: 373, y: 180))
arrow.line(to: NSPoint(x: 345, y: 153))
NSColor(calibratedRed: 0.57, green: 0.82, blue: 0.69, alpha: 1).setStroke()
arrow.stroke()

let bitmap = NSBitmapImageRep(focusedViewRect: bounds)!
image.unlockFocus()
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
