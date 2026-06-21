import Foundation
import simd

private struct SceneData: Codable {
    let sceneMetaData: SceneMetaData
    let assets: [SceneAsset]
    let camera: SceneCamera
}

private struct Vec3: Codable {
    let value: simd_float3
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Float.self)
        let y = try container.decode(Float.self)
        let z = try container.decode(Float.self)
        value = simd_float3(x, y, z)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(value.x)
        try container.encode(value.y)
        try container.encode(value.z)
    }
}

private struct SceneMetaData: Codable {
    let name: String
    let version: String
    let ambientColor: Vec3
}

private struct SceneAsset: Codable {
    let source: String
    let children: [SceneAssetChild]
}

private struct SceneAssetChild: Codable {
    let name: String
    let position: Vec3
    let rotation: Vec3
    let size: Vec3
}

private struct SceneCamera: Codable {
    let position: Vec3
    let rotation: Vec3
}

public func importScene(filePath: String, objectImporter: ObjectImporter) -> Scene? {
    guard let resolvedFilePath = resolveFilePath(filePath: filePath) else {
        print("Failed loading file: \(filePath), not found in directory!")
        return nil
    }

    let url = URL(fileURLWithPath: resolvedFilePath)
    guard let data = try? Data(contentsOf: url) else { 
        print("Failed opening file at: \(resolvedFilePath)")
        return nil
    }

    guard let sceneData = try? JSONDecoder().decode(SceneData.self, from: data) else {
        print("Scene data could not be json-decoded at: \(resolvedFilePath)")
        return nil
    }

    let scene = Scene()

    scene.camera.position = sceneData.camera.position.value
    scene.camera.makeOrientation(from: sceneData.camera.rotation.value)

    for asset in sceneData.assets {
        var object = objectImporter.importObject(filePath: asset.source)
        
        // Set Mesh Transformation here 
        for child in asset.children {
            for index in object.meshes.indices {
                if object.meshes[index].name != child.name { continue }
                object.meshes[index].position = child.position.value
                object.meshes[index].rotation = child.rotation.value
                object.meshes[index].size = child.size.value
            }
        }

        scene.addAsset(object)
    }

    return scene
}