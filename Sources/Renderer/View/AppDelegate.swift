import Foundation
import Cocoa

@MainActor private var screenWidth: CGFloat = 1920
@MainActor private var screenHeight: CGFloat = 1080

@MainActor public func setScreenSize(newWidth: CGFloat, newHeight: CGFloat) {
    screenWidth = newWidth
    screenHeight = newHeight
}

@MainActor public func getScreenSize() -> (width: CGFloat, height: CGFloat) {
    return (width: screenWidth, height: screenHeight)
}

class WindowDelegate : NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(self)
    }
}

@MainActor class AppDelegate : NSObject, NSApplicationDelegate {
    let window = NSWindow()
    let windowDelegate = WindowDelegate()
    public var viewController: ViewController?

    public var scene = Scene()
    public var importer: ObjectImporter!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.setContentSize(NSSize(width: screenWidth, height: screenHeight))
        window.styleMask = [ .titled, .closable, .miniaturizable, .resizable ]
        window.title = "[ Rasterizer - Raytracer ]"
    
        window.level = .normal
        window.delegate = windowDelegate
        window.center()

        let device = MTLCreateSystemDefaultDevice()!
        importer = ObjectImporter(device: device)
        scene.addAsset(importer.importObject(filePath: "Assets/SkyPavillion/SkyPavMap.obj"))
        //scene.addAsset(importer.importObject(filePath: "Assets/RobloxWorld2/RobloxWorld2.obj"))
        scene.rebuildBVH() // Mandatory

        let view = window.contentView!
        viewController = ViewController(device: device, scene: scene)
        viewController!.view.frame = view.bounds
        viewController!.view.autoresizingMask = [.width, .height]
        window.contentViewController = viewController

        window.makeKeyAndOrderFront(window)
        NSApp.activate(ignoringOtherApps: true)
    }
}