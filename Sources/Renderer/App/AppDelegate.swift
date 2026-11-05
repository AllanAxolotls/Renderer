import Cocoa

final class AppDelegate : NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var windowDelegate: WindowDelegate!

    var engine: Ryx!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        window = NSWindow()
        windowDelegate = WindowDelegate()
        engine = Ryx()

        initMenu()
        initWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        engine = nil // Required for Engine.deinit to run
    }
    
    @MainActor private func initWindow() {
        window.setContentSize(WindowConstants.initialSize)
        window.styleMask = [ .titled, .closable, .miniaturizable, .resizable ]
        window.title = WindowConstants.initialTitle

        window.level = .normal
        window.delegate = windowDelegate
        window.center()

        let view = window.contentView!
        engine.viewController.view.frame = view.bounds
        engine.viewController.view.autoresizingMask = [.width, .height]
        window.contentViewController = engine.viewController
        window.makeKeyAndOrderFront(nil)
    }

}