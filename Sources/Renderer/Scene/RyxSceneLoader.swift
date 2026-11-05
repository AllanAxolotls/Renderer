import Foundation

public final class SceneLoader {
    private unowned let engine: Ryx

    init(engine: Ryx) {
        self.engine = engine
    }

    func loadScene(url: URL) throws -> Scene {
        let ext = url.pathExtension.lowercased()
        let scene: Scene

        switch ext {
        case "json":
            scene = loadSceneWithJson(url: url)
        case "ryx":
            scene = loadSceneWithRyx(url: url)
        default:
            throw NSError(domain: "SceneLoader", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unsupported file extension: .\(ext)"])
        }

        return scene
    }

    func loadSceneWithJson(url: URL) -> Scene {
        let scene = Scene()

        return scene
    }

    func loadSceneWithRyx(url: URL) -> Scene {
        let scene = Scene()

        

        return scene
    }
}