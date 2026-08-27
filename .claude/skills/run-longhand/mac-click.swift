// Synthetic click for driving the Mac app: XCUITest has no target here, and
// `System Events`' `click at` is ignored by SwiftUI. Coordinates are in screen
// POINTS (a Retina screenshot's pixels ÷ 2).
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: mac-click <x> <y>\n".utf8))
    exit(2)
}
let point = CGPoint(x: x, y: y)
func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}
post(.mouseMoved); usleep(150_000)
post(.leftMouseDown); usleep(80_000)
post(.leftMouseUp)
