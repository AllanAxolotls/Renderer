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

    private let device = MTLCreateSystemDefaultDevice()!
    public var scene = Scene(name: "Untitled")
    
    public var mouseDownSubscription: AnyCancellable? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
        setSceneByURL(URL(fileURLWithPath: "Saves/Typical.rrscn"))

        window.makeKeyAndOrderFront(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        //scene.serializeRRSCN(URL(fileURLWithPath: "Saves/"))
    }

    @objc func loadRRSCNPanel() {
        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["rrscn"]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false

        openPanel.begin { [weak self] result in
            guard let self = self else { return }
            if result == .OK, let url = openPanel.url {
                setSceneByURL(url)
                self.viewController?.gameView.setNeedsDisplay(self.viewController?.gameView.bounds ?? .zero)
            }
        }
    }

    @objc func loadJSONPanel() {
        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["json"]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false

        openPanel.begin { [weak self] result in
            guard let self = self else { return }
            if result == .OK, let url = openPanel.url {
                let objectImporter = ObjectImporter()
                self.viewController?.gameView.window?.title = "Importing Scene ..."
                let urlWithoutExtension = url.deletingPathExtension()
                self.scene = Scene(name: urlWithoutExtension.lastPathComponent)
                self.scene.createTextureHandler(device: device)
                importToScene(scene: &scene, filePath: url.path, objectImporter: objectImporter)
                self.viewController?.scene = self.scene
                self.viewController?.gameView.setNeedsDisplay(self.viewController?.gameView.bounds ?? .zero)
            }
        }
    }

    @objc func importOBJPanel() {
        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["obj"]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false

        openPanel.begin { [weak self] result in
            guard let self = self else { return }
            if result == .OK, let url = openPanel.url {
                self.viewController?.gameView.window?.title = "Importing Object ..."
                if scene.textureHandler == nil { scene.createTextureHandler(device: device) }
                let objectImporter = ObjectImporter()
                self.scene.importObject(objectImporter: objectImporter, filePath: url.path)
            }
        }
    }

    @objc func importMTLPanel() {
       let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["mtl"]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false

        openPanel.begin { [weak self] result in
            guard let self = self else { return }
            if result == .OK, let url = openPanel.url {
                self.viewController?.gameView.window?.title = "Importing Material ..."
                let materialImporter = MaterialImporter()
                let (materials, materialDatas, _) = materialImporter.importMaterial(filePath: url.path)
                self.scene.materials.append(contentsOf: materials)
                self.scene.materialDatas.append(contentsOf: materialDatas)
            }
        } 
    }

    @objc func saveScenePanel() {
        self.scene.serializeRRSCN()
    }

    @objc func saveSceneAsPanel() {
        let savePanel = NSSavePanel()
        savePanel.allowedFileTypes = ["rrscn"]
        savePanel.nameFieldStringValue = "Untitled.rrscn"

        savePanel.begin { [weak self] result in
            guard let self = self else { return }
            if result == .OK, let url = savePanel.url {
                self.scene.serializeRRSCN(url)
            }
        }
    }

    func setupMenu() {
        let mainMenu = NSMenu()

        // File menu
        let fileMenu = NSMenu(title: "File")

        let loadRRSCNMenuItem = NSMenuItem( title: "Load Scene (.rrscn)",         action: #selector(loadRRSCNPanel),   keyEquivalent: "o" )
        let loadJSONMenuItem =  NSMenuItem( title: "Load Scene (.json)",          action: #selector(loadJSONPanel),    keyEquivalent: "j" )
        let saveMenuItem =      NSMenuItem( title: "Save Scene",                  action: #selector(saveScenePanel),   keyEquivalent: "s" )
        let saveAsMenuItem =    NSMenuItem( title: "SaveAs Scene",                action: #selector(saveSceneAsPanel), keyEquivalent: ""  )
        let importOBJMenuItem = NSMenuItem( title: "Import Wavefront OBJ (.obj)", action: #selector(importOBJPanel),   keyEquivalent: "i" )
        let importMTLMenuItem = NSMenuItem( title: "Import Wavefront MTL (.mtl)", action: #selector(importMTLPanel),   keyEquivalent: ""  )

        fileMenu.addItem(loadRRSCNMenuItem)
        fileMenu.addItem(loadJSONMenuItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(saveMenuItem)
        fileMenu.addItem(saveAsMenuItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(importOBJMenuItem)
        fileMenu.addItem(importMTLMenuItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu

        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func setupWindow() {
        window.setContentSize(NSSize(width: screenWidth, height: screenHeight))
        window.styleMask = [ .titled, .closable, .miniaturizable, .resizable ]
        window.title = "[ Rasterizer - Raytracer ]"
    
        window.level = .normal
        window.delegate = windowDelegate
        window.center()

        let view = window.contentView!
        viewController = ViewController(device: device, scene: scene)
        viewController!.view.frame = view.bounds
        viewController!.view.autoresizingMask = [.width, .height]
        window.contentViewController = viewController
    }

    func setSceneByURL(_ sceneURL: URL) {
        self.viewController?.gameView.window?.title = "Importing Scene ..."
        if self.scene.textureHandler == nil { self.scene.createTextureHandler(device: self.device) }
        self.scene.deserializeRRSCN(sceneURL)
        self.viewController?.scene = self.scene
    }

    func raycastMouseClickCode() {
        /*
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

            // getting a mesh from this is terrible
            // use faceIndex to find the RaytraceTriangleGPU, find submesh that has faceindex in range
            let result: RaycastResult? = self.scene.tlas.raycast(origin: rayOrigin, direction: rayDirection)
            
            if let result = result {
                if result.faceIndex != -1 {
                    //let face: Face = self.scene.tlas.faces[Int(result.faceIndex)]
                    //let subMesh: SubMesh = self.scene.subMeshes[Int(face.subMeshIndex)]
                    //let mesh: Mesh = self.scene.meshes[Int(subMesh.meshIndex)]
                    //print(mesh.name)
                    // TODO: print material name

                    /*
                    // Mesh toevoegen na scene al gebouwd is werkt nog niet omdat de TLAS gerformed worden
                    objectImporter.importAtOrigin = true
                    let asset = objectImporter.importObject(filePath: "Assets/FriedChicken/FriedChicken.obj")
                    for mesh in asset.meshes {
                        mesh.position = hit.hit
                    }
                    scene.addAsset(asset)
                    scene.rebuildTLAS()*/
                }
            }
        }*/
    }

    func rotateSceneCode() {
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
}