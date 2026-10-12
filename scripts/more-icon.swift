import AppKit
// Grey ellipsis for the More conversations row; transparent background so it reads as a control, not a chat.
let image = NSImage(size: NSSize(width: 256, height: 256))
image.lockFocus()
NSColor(calibratedWhite: 0.56, alpha: 1).setFill()
for x in [56.0, 128.0, 200.0] { NSBezierPath(ovalIn: NSRect(x: x - 22, y: 106, width: 44, height: 44)).fill() }
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
