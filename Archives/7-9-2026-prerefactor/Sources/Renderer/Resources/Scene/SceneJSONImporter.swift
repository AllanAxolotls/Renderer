import Foundation
import simd

private struct SceneData: Codable {
    let sceneMetaData: SceneMetaData?
    let assets: [SceneAsset]?
    let camera: SceneCamera?
    let sphereLights: [SceneSphereLight]?
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
    let diffuseColor: Vec3?
}

private struct SceneAsset: Codable {
    let source: String?
    let importAtOrigin: Bool?
    let importOffset: Vec3? // Even with importAtOrigin, will offset
    let importCCWFaces: Bool?
    let recomputeNormals: Bool?
    let flipX: Bool?
    let flipY: Bool?
    let flipZ: Bool?
    let children: [SceneAssetChild]?
}

private struct SceneAssetChild: Codable {
    let name: String?
    let position: Vec3?
    let rotation: Vec3?
    let scale: Vec3?
    let material: SceneAssetMaterial?
}

private struct SceneAssetMaterial: Codable {
    let diffuseColor: Vec3?
    let dissolve: Float?
    let diffuseTextureIndex: Int?
    let isSky: Bool?
}

private struct SceneCamera: Codable {
    let position: Vec3?
    let rotation: Vec3?
    let moveSpeed: Float?
}

private struct SceneSphereLight: Codable {
    let position: Vec3
    let emission: Vec3
    let radius: Float
}

public func importToScene(scene: inout Scene, filePath: String, objectImporter: ObjectImporter) {
    guard let resolvedFilePath = resolveFilePath(filePath: filePath) else {
        print("Failed loading file: \(filePath), not found in directory!")
        return
    }

    let url = URL(fileURLWithPath: resolvedFilePath)
    guard let data = try? Data(contentsOf: url) else { 
        print("Failed opening file at: \(resolvedFilePath)")
        return
    }

    guard let sceneData = try? JSONDecoder().decode(SceneData.self, from: data) else {
        print("Scene data could not be json-decoded at: \(resolvedFilePath)")
        return
    }

    if let posValue = sceneData.camera?.position?.value { scene.camera.position = posValue }
    if let rotValue = sceneData.camera?.rotation?.value { scene.camera.makeOrientation(from: rotValue) }
    if let moveSpeedValue = sceneData.camera?.moveSpeed { scene.camera.moveSpeed = moveSpeedValue }

    for asset in sceneData.assets ?? [] {
        guard let source = asset.source else { continue }
        objectImporter.importAtOrigin = asset.importAtOrigin ?? false
        objectImporter.importCCWFaces = asset.importCCWFaces ?? false
        objectImporter.importOffset = asset.importOffset?.value ?? simd_float3(0, 0, 0)
        objectImporter.recomputeNormals = asset.recomputeNormals ?? false
        objectImporter.flipX = asset.flipX ?? false
        objectImporter.flipY = asset.flipY ?? false
        objectImporter.flipZ = asset.flipZ ?? true

        let (_, _, _, _, newMeshStart) = scene.importObject(objectImporter: objectImporter, filePath: source)
        
        for child in asset.children ?? [] { // Submesh
            var found: Bool = false
            for mesh in scene.meshes[newMeshStart...] {
                guard mesh.name == child.name else { continue }
                found = true

                if let material = child.material {
                    for subMesh in mesh.subMeshes {
                        let matIdx = Int(subMesh.materialIndex)
                        guard matIdx >= 0 && matIdx < scene.materialDatas.count else { continue }

                        if let diffuseColor = material.diffuseColor?.value { 
                            scene.materialDatas[matIdx].diffuseColor.x = diffuseColor.x
                            scene.materialDatas[matIdx].diffuseColor.y = diffuseColor.y
                            scene.materialDatas[matIdx].diffuseColor.z = diffuseColor.z
                        }
                        if let dissolve = material.dissolve { 
                            scene.materialDatas[matIdx].diffuseColor.w = dissolve 
                        }
                        if let diffuseTextureIndex = material.diffuseTextureIndex {
                            scene.materialDatas[matIdx].diffuseTextureIndex = UInt16(diffuseTextureIndex)
                        }
                        if let isSky = material.isSky { 
                            scene.materialDatas[matIdx].params.w = isSky ? Float.init(bitPattern: 1) : Float.init(bitPattern: 0)
                        }
                    }
                }
                
                if let posValue = child.position?.value { mesh.position = posValue }
                if let rotValue = child.rotation?.value { mesh.rotation = rotValue }
                if let scaleValue = child.scale?.value  { mesh.scale = scaleValue }
            }

            if (!found) {
                if let child_name = child.name {
                    print("\(child_name) does not seem to exist in the obj file!")
                }
            }
        }
    }

/*
    for sphereLight in sceneData.sphereLights ?? [] {
        scene.sphereLights.append(SphereLight(
            position: sphereLight.position.value, 
            emission: sphereLight.emission.value,
            radius: sphereLight.radius
        ))
    }*/
}