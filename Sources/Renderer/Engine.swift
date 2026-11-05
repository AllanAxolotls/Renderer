import Metal
import Foundation
import QuartzCore

@MainActor final class Ryx {
    let device: MTLDevice = MTLCreateSystemDefaultDevice()!

    let resourceManager  : ResourceManager
    let collisionManager : CollisionManager
    let renderManager    : RenderManager
    let sceneManager     : SceneManager
    let inputManager     : InputManager
    let audioManager     : AudioManager

    let inputController  : InputController
    let cameraController : CameraController

    let gameView         : GameView
    var viewController   : ViewController!


    init() {
        print("\n\nStarting RyxEngine")
        print("------------------------------------------------------------------------------------------------------------------------------------------------------------")

        // App
        gameView         = GameView         (frame: .zero, device: device)
        viewController   = ViewController   (gameView: gameView)

        // Managers & Systems
        sceneManager     = SceneManager     ()
        inputManager     = InputManager     (gameView: gameView)
        inputController  = InputController  (inputManager: inputManager, gameView: gameView)
        cameraController = CameraController (sceneManager: sceneManager, inputManager: inputManager)
        resourceManager  = ResourceManager  (device: device)
        collisionManager = CollisionManager (device: device, sceneManager: sceneManager)
        renderManager    = RenderManager    (device: device, sceneManager: sceneManager, resourceManager: resourceManager, collisionManager: collisionManager, inputController: inputController)
        audioManager     = AudioManager     ()

        sceneManager.currentScene = Scene(name: "Hello World")
        viewController.setCallbacks(
            updateCallback: { self.update() },
            renderCallback: { self.renderManager.render(in: $0) },
            drawableSizeChangedCallback: { self.renderManager.gameScreenSize = $0 }
        )

        Task {
            do {
                @MainActor func loadObject(_ urlstring: String) async throws {
                    let url = URL(fileURLWithPath: urlstring)
                    let meshLibraryResource = try await resourceManager.loadMeshLibraryResourceAsync(url: url)
                    sceneManager.addObjectsToScene(meshLibraryResource.resource.meshes)
                }

                
                let Typical = try await resourceManager.loadMeshLibraryResourceAsync(url: URL(fileURLWithPath: "Assets/Typical/Typical.obj"))
                sceneManager.addObjectsToScene(Typical.resource.meshes)
                sceneManager.currentScene?.currentCamera.position = SIMD3<Float>(x: 0.0, y: 0.6798707, z: -1.2788746)
                

                /*
                try await loadObject("Assets/Poolrooms/Poolrooms.obj")
                sceneManager.currentScene?.addChildren(robloxRoom.resource.meshes)
                sceneManager.currentScene?.currentCamera.position = SIMD3<Float>(x: 0.0, y: 2.6683977, z: 1.9970803)
                */

                /*
                let robloxRoom = try await resourceManager.loadMeshLibraryResourceAsync(url: URL(fileURLWithPath: "Assets/RobloxRoom/Room.obj"))
                sceneManager.currentScene?.addChildren(robloxRoom.resource.meshes)
                sceneManager.currentScene?.currentCamera.position = SIMD3<Float>(x: 22.1575, y: 22.59988, z: -33.470524)
                */

                /*
                let robloxWorld = try await resourceManager.loadMeshLibraryResourceAsync(url: URL(fileURLWithPath: "Assets/RobloxWorld2/RobloxWorld2.obj"))
                sceneManager.currentScene?.addChildren(robloxWorld.resource.meshes)
                sceneManager.currentScene?.currentCamera.rotate(yaw: 180, pitch: 0)
                sceneManager.currentScene?.currentCamera.position = SIMD3<Float>(x: 146.8336, y: 11.764056, z: -238.32405)
                */

                /*
                let area0map = try await resourceManager.loadMeshLibraryResourceAsync(url: URL(fileURLWithPath: "Assets/Pokepark/Area0/FdAr01Zn01Map01/FdAr01Zn01Map01.obj"))
                sceneManager.currentScene?.addChildren(area0map.resource.meshes)
                let area0plant = try await resourceManager.loadMeshLibraryResourceAsync(url: URL(fileURLWithPath: "Assets/Pokepark/Area0/FdAr01Zn01Plants01/FdAr01Zn01Plants01.obj"))
                sceneManager.currentScene?.addChildren(area0plant.resource.meshes)
                let area0env = try await resourceManager.loadMeshLibraryResourceAsync(url: URL(fileURLWithPath: "Assets/Pokepark/Area0/PeFdAr01Zn01Env01/PeFdAr01Zn01Env01.obj"))
                sceneManager.currentScene?.addChildren(area0env.resource.meshes)
                */

                /*
                let dream = try await resourceManager.loadMeshLibraryResourceAsync(url: URL(fileURLWithPath: "Assets/Dream/Dream.obj"))
                sceneManager.currentScene?.addChildren(dream.resource.meshes)
                */

                /*
                let shop = try await resourceManager.loadMeshLibraryResourceAsync(url: URL(fileURLWithPath: "Assets/Shop/Shop.obj"))
                sceneManager.currentScene?.addChildren(shop.resource.meshes)
                */

                collisionManager.buildTlas()

            } catch {
                print("Failed to load object: \(error)")
            }
        }

        
        /*
            audioManager.loadBackgroundMusic(url: URL(fileURLWithPath: "Assets/Sound/background.mp3"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.audioManager.playBackgroundMusic()
            }
        */
    }

    var lastUpdate = CACurrentMediaTime()
    func update() {
        let time = CACurrentMediaTime()
        let deltaTime = time - lastUpdate
        lastUpdate = time

        resourceManager.update(deltaTime: deltaTime)

        cameraController.update(deltaTime: deltaTime)

        if inputManager.isKeyDown(KeyCode.P) {
            print(sceneManager.currentScene?.currentCamera.position ?? "nil")
        }
    }

    func stop() {
        print("\n\nStopping RyxEngine")
        print("------------------------------------------------------------------------------------------------------------------------------------------------------------")
    }
}