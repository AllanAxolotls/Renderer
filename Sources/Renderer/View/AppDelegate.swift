import Foundation
import Cocoa

@MainActor var screenWidth: CGFloat = 1920
@MainActor var screenHeight: CGFloat = 1080

@MainActor func setScreenSize(newWidth: CGFloat, newHeight: CGFloat) {
    screenWidth = newWidth
    screenHeight = newHeight
}

@MainActor func getScreenSize() -> (width: CGFloat, height: CGFloat) {
    return (width: screenWidth, height: screenHeight)
}

class WindowDelegate : NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(self)
    }
}

@MainActor
class AppDelegate : NSObject, NSApplicationDelegate {
    let window = NSWindow()
    let windowDelegate = WindowDelegate()
    var viewController: NSViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.setContentSize(NSSize(width: screenWidth, height: screenHeight))
        window.styleMask = [ .titled, .closable, .miniaturizable, .resizable ]
        window.title = "Metal Triangles"
    
        window.level = .normal
        window.delegate = windowDelegate
        window.center()

        let view = window.contentView!
        viewController = ViewController(nibName: nil, bundle: nil)
        viewController!.view.frame = view.bounds
        viewController!.view.autoresizingMask = [.width, .height]
        window.contentViewController = viewController

        window.makeKeyAndOrderFront(window)
        NSApp.activate(ignoringOtherApps: true)
    }
}