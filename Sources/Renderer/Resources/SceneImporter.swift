import Foundation
import simd

private struct SceneData: Codable {
    let sceneMetaData: SceneMetaData?
    let assets: [SceneAsset]?
    let camera: SceneCamera?
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
    let name: String?
    let version: String?
    let ambientColor: Vec3?
}

private struct SceneAsset: Codable {
    let source: String?
    let children: [SceneAssetChild]?
}

private struct SceneAssetChild: Codable {
    let name: String?
    let position: Vec3?
    let rotation: Vec3?
    let size: Vec3?
    let material: SceneAssetMaterial?
}

private struct SceneAssetMaterial: Codable {
    let ambientColor: Vec3?
    let dissolve: Float?
}

private struct SceneCamera: Codable {
    let position: Vec3?
    let rotation: Vec3?
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

    if let posValue = sceneData.camera?.position?.value { scene.camera.position = posValue }
    if let rotValue = sceneData.camera?.rotation?.value { scene.camera.makeOrientation(from: rotValue) }

    for asset in sceneData.assets ?? [] {
        guard let source = asset.source else { continue }
        var object = objectImporter.importObject(filePath: source)
        
        // Set Mesh Transformation here 
        for child in asset.children ?? [] { // Submesh
            for index in object.meshes.indices {
                if object.meshes[index].name != child.name { continue }
                if let material = child.material {
                    if let ambientColor = material.ambientColor?.value { object.materials[index].ambientColor = ambientColor }
                    if let dissolve = material.dissolve { object.materials[index].dissolve = dissolve }
                }
                if let posValue = child.position?.value { object.meshes[index].position = posValue }
                if let rotValue = child.rotation?.value { object.meshes[index].rotation = rotValue }
                if let sizeValue = child.size?.value { object.meshes[index].size = sizeValue }
            }
        }

        scene.addAsset(object)
    }

    return scene
}