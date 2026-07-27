import Foundation
import Cocoa
import simd
import Combine

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
    
    public var mouseDownSubscription: AnyCancellable? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.setContentSize(NSSize(width: screenWidth, height: screenHeight))
        window.styleMask = [ .titled, .closable, .miniaturizable, .resizable ]
        window.title = "[ Rasterizer - Raytracer ]"
    
        window.level = .normal
        window.delegate = windowDelegate
        window.center()

        let device = MTLCreateSystemDefaultDevice()!
        objectImporter = ObjectImporter(device: device)

        //scene = createScene(objectImporter: objectImporter)

        //objectImporter.importAtOrigin = true
        //scene.addAsset(objectImporter.importObject(filePath: "Assets/Spawnlocation/Spawnlocation.obj"))
        scene = importScene(filePath: "Scenes/Area0.json", objectImporter: objectImporter)
        //scene = importScene(filePath: "Scenes/Area7.json", objectImporter: objectImporter)

        //scene.addAsset(objectImporter.importObject(filePath: "Assets/FdAr07Zn01/FdAr07Zn01.obj"))
        //scene.addAsset(objectImporter.importObject(filePath: "Assets/RobloxRoom/Room.obj"))
        //scene = importScene(filePath: "Scenes/Typical.json", objectImporter: objectImporter)
        //scene = importScene(filePath: "Scenes/scene1.json", objectImporter: objectImporter)
        //scene = importScene(filePath: "Scenes/RobloxWorld2.json", objectImporter: objectImporter)
        //scene.addAsset(objectImporter.importObject(filePath: "Assets/RobloxWorld2/RobloxWorld2.obj"))

        scene.buildAccelerationStructures() // Mandatory

        let view = window.contentView!
        viewController = ViewController(device: device, scene: scene)
        viewController!.view.frame = view.bounds
        viewController!.view.autoresizingMask = [.width, .height]
        window.contentViewController = viewController

        mouseDownSubscription = viewController!.gameView.mouseDownBinding.sink { [weak viewController, weak self] event in 
            guard let viewController = viewController, let self = self else { return }

            let mouseLocation = event.locationInWindow
            let viewSize = viewController.gameView.bounds.size
            let ndcX: Float = (Float(mouseLocation.x) / Float(viewSize.width)) * 2.0 - 1.0
            let ndcY: Float = 1.0 - (1.0 - (Float(mouseLocation.y) / Float(viewSize.height))) * 2.0
            let aspectRatio: Float = Float(viewSize.width / viewSize.height)
            let projectedX: Float = ndcX * aspectRatio * tan(FOVRad * 0.5)
            let projectedY: Float = ndcY * tan(FOVRad * 0.5)

            let rayOrigin = self.scene.camera.position
            let rayDirection = simd_normalize(self.scene.camera.forward + projectedX * self.scene.camera.right + projectedY * self.scene.camera.up)

            let result: RaycastResult? = self.scene.tlas?.raycast(origin: rayOrigin, direction: rayDirection)
            
            if let result = result {
                if result.faceIndex != -1 {
                    let face: Face = self.scene.faces[Int(result.faceIndex)]
                    let subMesh: SubMesh = self.scene.subMeshes[Int(face.subMeshIndex)]
                    let mesh: Mesh = self.scene.meshes[Int(subMesh.meshIndex)]
                    print(mesh.name)

                    /*
            // Mesh toevoegen na scene al gebouwd is werkt nog niet omdat de TLAS gerformed worden
            objectImporter.importAtOrigin = true
            let asset = objectImporter.importObject(filePath: "Assets/FriedChicken/FriedChicken.obj")
            for mesh in asset.meshes {
                mesh.position = hit.hit
            }
            scene.addAsset(asset)
            // TODO: when calling addAsset, it should queue a TLAS reform
            // TODO: fully rebuilding a TLAS is terrible, there should be a function for adding a TlasInstance and reforming
            scene.rebuildTLAS()*/
                }
            }
        }

        window.makeKeyAndOrderFront(window)
        NSApp.activate(ignoringOtherApps: true)

        /*//Rotation Code (Rotates every mesh around its own axis)
        Task.detached(priority: .userInitiated) { [weak self] in
            while true {
                // self?.scene.updateTransforms()
                // self?.tlas.reform()
                await MainActor.run { [weak self] in
                    for mesh in self?.scene.meshes ?? [] {
                        mesh.rotation += simd_float3(0, 0.5, 0)
                    }
                }
                
                try? await Task.sleep(nanoseconds: 16_666_667) // ~60 FPS (1/60th of a second)
            }
        }*/
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // TODO: Save TLAS here, serialize it
    }
}