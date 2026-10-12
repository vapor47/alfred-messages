import AppKit
let image = NSImage(size: NSSize(width: 256, height: 256))
image.lockFocus()
NSColor(calibratedRed: 0.13, green: 0.72, blue: 0.34, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 240, height: 240), xRadius: 54, yRadius: 54).fill()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 44, y: 63, width: 168, height: 134)).fill()
let tail = NSBezierPath(); tail.move(to: NSPoint(x: 75, y: 87)); tail.line(to: NSPoint(x: 55, y: 48)); tail.line(to: NSPoint(x: 108, y: 75)); tail.close(); tail.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
