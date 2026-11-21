#!/usr/bin/env swift
// Renders the system's icon for an app bundle at 1024/128/32/16, in light and dark, for review.
// Usage: swift scripts/render-icon.swift <App.app> <output.png>
import AppKit

let app = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let icon = NSWorkspace.shared.icon(forFile: app)
let sizes: [CGFloat] = [512, 128, 64, 32, 16]
let pad: CGFloat = 40
let width = sizes.reduce(pad) { $0 + $1 + pad }
let height = (512 + pad * 2) * 2
let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
	for (row, appearanceName) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
		let y = CGFloat(row) * (512 + pad * 2)
		(appearanceName == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
		NSRect(x: 0, y: y, width: width, height: 512 + pad * 2).fill()
		NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
			var x = pad
			for size in sizes {
				icon.draw(in: NSRect(x: x, y: y + pad + (512 - size) / 2, width: size, height: size),
					from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
					hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
				x += size + pad
			}
		}
	}
	return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: output)
