import Foundation
import Cocoa
import simd

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
    public var objectImporter: ObjectImporter!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.setContentSize(NSSize(width: screenWidth, height: screenHeight))
        window.styleMask = [ .titled, .closable, .miniaturizable, .resizable ]
        window.title = "[ Rasterizer - Raytracer ]"
    
        window.level = .normal
        window.delegate = windowDelegate
        window.center()

        let device = MTLCreateSystemDefaultDevice()!
        objectImporter = ObjectImporter(device: device)
        scene = importScene(filePath: "Saves/scene1.json", objectImporter: objectImporter) ?? Scene()
        //scene.addAsset(importer.importObject(filePath: "Assets/SkyPavillion/SkyPavMap.obj"))
        //scene.addAsset(importer.importObject(filePath: "Assets/RobloxWorld2/RobloxWorld2.obj"))
        scene.buildAccelerationStructures() // Mandatory

        let view = window.contentView!
        viewController = ViewController(device: device, scene: scene)
        viewController!.view.frame = view.bounds
        viewController!.view.autoresizingMask = [.width, .height]
        window.contentViewController = viewController

        window.makeKeyAndOrderFront(window)
        NSApp.activate(ignoringOtherApps: true)

        // Add it here:
        if #available(macOS 10.15, *) {
            Task.detached(priority: .userInitiated) { [weak self] in
                while true {
                    // 1. Do your asynchronous heavy lifting here (e.g., raytracing updates, scene mutations)
                    // self?.scene.updateTransforms()
                    // self?.tlas.reform()
                    await MainActor.run { [weak self] in
                        for mesh in self?.scene.meshes ?? [] {
                            mesh.rotation += simd_float3(0, 0.5, 0)
                        }
                    }
                    
                    // 2. Co-operatively yield the thread or sleep so the CPU can breathe
                    try? await Task.sleep(nanoseconds: 16_666_667) // ~60 FPS (1/60th of a second)
                }
            }
        } else {
            // Fallback on earlier versions
        }
    }
}