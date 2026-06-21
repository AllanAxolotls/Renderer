import Metal
import MetalKit
import Foundation

// Settings
private let useClockWiseTriangles: Bool = false
private let importAtOrigin: Bool = false
private let printResolves: Bool = true


// Unused, should be used for material merging in the future
private func areMaterialsEqual(materialA: Material, materialB: Material) -> Bool {
    if !simd_equal(materialA.ambientColor, materialB.ambientColor) { return false }
    if materialA.ambientTextureIndex != materialB.ambientTextureIndex { return false }
    if materialA.dissolve != materialB.dissolve { return false }
    return true
}

private func toByte(_ x: Float) -> UInt8 {
    let safe = x.isNaN || x.isInfinite ? 0 : x
    let clamped = min(max(safe, 0), 255)
    return UInt8(clamped)
}

private func make1x1Texture(device: MTLDevice, textures: inout [MTLTexture], colorIndexCache: inout [simd_float3 : Int32], colorTextureCache: inout [simd_float3: MTLTexture], color: simd_float3) -> (MTLTexture, Int32) {
    if let existing = colorTextureCache[color] { return (existing, colorIndexCache[color]!) }

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: 1,
        height: 1,
        mipmapped: false
    )

    desc.usage = .shaderRead

    let texture = device.makeTexture(descriptor: desc)!

    var rgbColor: [UInt8] = [toByte(color.x * 255), toByte(color.y * 255), toByte(color.z * 255), 255] // RGBA
    texture.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: &rgbColor,
        bytesPerRow: 4
    )

    colorTextureCache[color] = texture
    let index = Int32(truncatingIfNeeded: textures.count)
    textures.append(texture)
    colorIndexCache[color] = index

    return (texture, index)
}


private class TextureImporter {
    public var textures: [MTLTexture] = []
    public var nameToIndices: [String : Int32] = [:]
    public var fallbackTexture: MTLTexture
    private let device: MTLDevice
    private let mtkTextureLoader: MTKTextureLoader

    private var colorTextureCache: [simd_float3: MTLTexture] = [:]
    private var colorIndexCache: [simd_float3: Int32] = [:]

    init(device: MTLDevice) {
        self.device = device
        self.mtkTextureLoader = MTKTextureLoader(device: device)
        (self.fallbackTexture, _) = make1x1Texture(device: device, textures: &textures, colorIndexCache: &colorIndexCache, colorTextureCache: &colorTextureCache, color: simd_float3(1, 1, 1))
    }

    public func getTexture(_ filePath: String) -> (MTLTexture?, Int32?) {
        if let index = nameToIndices[filePath] {
            return (textures[Int(index)], index)
        }
        return (nil, nil)
    }
    public func getTextureIndex(_ filePath: String) -> Int32? {
        return nameToIndices[filePath]
    }

    private func loadTexture(filePath: String) -> MTLTexture? {
        if let fixedPath = resolveFilePath(filePath: filePath) {
            let textureURL = URL(fileURLWithPath: fixedPath)
            let options: [MTKTextureLoader.Option: Any] = [
                .origin: MTKTextureLoader.Origin.bottomLeft, // important for OBJ UVs
                .SRGB: true
            ]
            
            do {
                let texture = try mtkTextureLoader.newTexture(URL: textureURL, options: options)
                return texture
            } catch {
                print("An error occured while trying to load texture \(fixedPath)")
                return nil
            }
        } else {
            print("Loading texture '\(filePath)' failed, not found in directory")
            return nil
        }
    }

    public func importTexture(filePath: String) -> (MTLTexture, Int32) {
        let (existingTexture, existingIndex) = getTexture(filePath)
        if existingTexture != nil { return (existingTexture!, existingIndex!) }
        if let texture = loadTexture(filePath: filePath) {
            let index = Int32(truncatingIfNeeded: textures.count)
            nameToIndices[filePath] = index
            textures.append(texture)
            return (texture, index)
        }
        nameToIndices[filePath] = 0 // fallback texture
        return (textures[0], 0)
    }

    public func getColorTexture(color: simd_float3) -> (MTLTexture, Int32) {
        return make1x1Texture(device: device, textures: &textures, colorIndexCache: &colorIndexCache, colorTextureCache: &colorTextureCache, color: color)
    }
}

// TODO: Add material merging if names are the same
public class MaterialImporter {
    private var textureImporter: TextureImporter

    init(device: MTLDevice) {
        textureImporter = TextureImporter(device: device)
    }

    // Tracks all imported materials
    //var importedMaterials = [Material]()

    public func importMaterial(filePath: String) -> (materials: [Material], materialNameIndices: [String : Int32]) {
        var materials: [Material] = []
        var materialNameIndices: [String : Int32] = [:]

        guard let resolvedFilePath = resolveFilePath(filePath: filePath) else {
            print("Failed loading file: \(filePath), not found in directory!")
            return (materials: materials, materialNameIndices: materialNameIndices)
        }

        var materialIndex: Int32 = -1
        var currentMaterial = Material()
        var currentMaterialHasTexture: Bool = false

        func pushMaterial() {
            if !currentMaterialHasTexture {
                (_, currentMaterial.ambientTextureIndex) = self.textureImporter.getColorTexture(color: currentMaterial.ambientColor)
            }
            materials.append(currentMaterial)
            currentMaterial = Material()
            currentMaterialHasTexture = false
        }

        guard let contents = try? String(contentsOfFile: resolvedFilePath, encoding: .utf8) else {
            print("Material file \(filePath) could not be found in directory!")
            return (materials: materials, materialNameIndices: materialNameIndices)
        }

        let mtlDirURL = URL(fileURLWithPath: resolvedFilePath).deletingLastPathComponent()
        let lines = contents.components(separatedBy: .newlines)
        parseLine: for line in lines {
            if line.isEmpty { continue }
            let tokens = line.components(separatedBy: " ")
            let command = tokens[0]

            switch command {
            case "#": continue parseLine
            case "Ka": currentMaterial.ambientColor = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!)
            case "d": currentMaterial.dissolve = Float(tokens[1])!
            case "map_Ka":
                (_, currentMaterial.ambientTextureIndex) = textureImporter.importTexture(filePath: mtlDirURL.appendingPathComponent(tokens[1]).path)
                currentMaterialHasTexture = true
            case "newmtl":
                if materialIndex != -1 {
                    pushMaterial()
                }
                materialIndex += 1
                materialNameIndices[tokens[1]] = materialIndex
            default: continue parseLine
            }
        }
        // Finalise
        pushMaterial()

        return (materials: materials, materialNameIndices: materialNameIndices)
    }

    public func getTextures() -> [MTLTexture] {
        return textureImporter.textures
    }
}

public struct ObjectAsset {
    var vertices: [Vertex]
    var faces: [Face]
    var materials: [Material]
    var textures: [MTLTexture]
    var subMeshes: [SubMesh]
    var meshes: [Mesh]
}

public class ObjectImporter {
    public var materialImporter: MaterialImporter

    init(device: MTLDevice) {
        materialImporter = MaterialImporter(device: device)
    }

    func importObject(filePath: String) -> ObjectAsset {
        var vertexPositions: [simd_float3] = []
        var vertexUVs: [simd_float2] = []
        var vertexNormals: [simd_float3] = []

        var materials: [Material] = []
        var vertices: [Vertex] = []
        var faces: [Face] = []
        var subMeshes: [SubMesh] = []
        var meshes: [Mesh] = []
        var materialNameIndices: [String : Int32] = [:]

        // Find .obj File
        guard let resolvedFilePath = resolveFilePath(filePath: filePath) else {
            print("Failed loading file: \(filePath), not found in directory!")
            return ObjectAsset(vertices: vertices, faces: faces, materials: materials, textures: materialImporter.getTextures(), subMeshes: subMeshes, meshes: meshes)
        }

        guard let contents = try? String(contentsOfFile: resolvedFilePath, encoding: .utf8) else { 
            print("Failed opening file at: \(resolvedFilePath)")
            return ObjectAsset(vertices: vertices, faces: faces, materials: materials, textures: materialImporter.getTextures(), subMeshes: subMeshes, meshes: meshes)
        }

        let objURL = URL(fileURLWithPath: resolvedFilePath)

        var currentMeshVertexOffset: Int32 = 0
        var currentMeshVertexCount: Int32 = 0
        var currentSubMeshVertexOffset: Int32 = 0
        var currentSubMeshVertexCount: Int32 = 0
        var currentMeshFaceOffset: Int32 = 0
        var currentMeshFaceCount: Int32 = 0
        var currentSubMeshFaceOffset: Int32 = 0
        var currentSubMeshFaceCount: Int32 = 0
        var currentSubMeshOffset: Int32 = 0
        var currentSubMeshCount: Int32 = 0
        var currentMaterialIndex: Int32? = nil
        var currentMeshName: String? = nil
        var currentMeshOffset: Int32 = 0

        func pushSubMesh() {
            if currentSubMeshVertexCount == 0 { return }
            let subMesh = SubMesh(
                vertexOffset: currentSubMeshVertexOffset, 
                vertexCount: currentSubMeshVertexCount, 
                faceOffset: currentSubMeshFaceOffset, 
                faceCount: currentSubMeshFaceCount,
                materialIndex: currentMaterialIndex ?? -1, 
                meshIndex: currentMeshOffset,
            )
            subMeshes.append(subMesh)
            currentSubMeshCount += 1
            currentSubMeshVertexOffset += currentSubMeshVertexCount
            currentSubMeshFaceOffset += currentSubMeshFaceCount
            currentSubMeshVertexCount = 0
            currentSubMeshFaceCount = 0
            currentMaterialIndex = nil
        }

        func pushMesh() {
            if currentSubMeshCount == 0 { return }
            var minBounds = simd_float3(repeating: .greatestFiniteMagnitude)
            var maxBounds = simd_float3(repeating: -.greatestFiniteMagnitude)
            for vertexIndex in currentMeshVertexOffset ..< currentMeshVertexOffset + currentMeshVertexCount {
                let vertex = vertices[Int(vertexIndex)]
                minBounds = simd.min(minBounds, vertex.position)
                maxBounds = simd.max(maxBounds, vertex.position)
            }

            var mesh = Mesh(
                subMeshOffset: currentSubMeshOffset, subMeshCount: currentSubMeshCount,
                faceOffset: currentMeshFaceOffset, faceCount: currentMeshFaceCount,
                vertexOffset: currentMeshVertexOffset, vertexCount: currentMeshVertexCount,
                localMinBounds: minBounds, localMaxBounds: maxBounds
            )

            mesh.name = currentMeshName ?? "Mesh"
            mesh.pivot = (minBounds + maxBounds) * 0.5
            meshes.append(mesh)

            currentSubMeshOffset += currentSubMeshCount
            currentSubMeshCount = 0
            currentMeshFaceOffset += currentMeshFaceCount
            currentMeshFaceCount = 0
            currentMeshVertexOffset += currentMeshVertexCount
            currentMeshVertexCount = 0
            currentMeshOffset += 1
        }

        let lines = contents.components(separatedBy: .newlines)
        parseLine: for line in lines {
            if line.isEmpty { continue }

            let tokens = line.components(separatedBy: " ")
            let command = tokens[0]

            switch command {
            case "#": continue parseLine
            case "v": vertexPositions.append(simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!))
            case "vt": vertexUVs.append(simd_float2(Float(tokens[1])!, Float(tokens[2])!))
            case "vn": vertexNormals.append(simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!))
            case "f":
                let vertexAttributes1 = tokens.count >= 2 && !tokens[1].isEmpty ? tokens[1].components(separatedBy: "/") : nil
                let vertexAttributes2 = tokens.count >= 3 && !tokens[2].isEmpty ? tokens[2].components(separatedBy: "/") : nil
                let vertexAttributes3 = tokens.count >= 4 && !tokens[3].isEmpty ? tokens[3].components(separatedBy: "/") : nil
                let vertexAttributes4 = tokens.count >= 5 && !tokens[4].isEmpty ? tokens[4].components(separatedBy: "/") : nil

                var positions: [simd_float3?] = [nil, nil, nil, nil]
                var uvs: [simd_float2?] = [nil, nil, nil, nil]
                var normals: [simd_float3?] = [nil, nil, nil, nil]

                // f 0/0/0 (vertexAttr1) 0/0/0 (vertexAttr2) 0/0/0 (vertexAttr3)
                for (i, vertexAttributes) in [vertexAttributes1, vertexAttributes2, vertexAttributes3, vertexAttributes4].enumerated() {
                    guard let vertexAttributes = vertexAttributes else { continue }
                    let attributeCount = vertexAttributes.count
                    // Check string length for these cases where uvs are ignored: f 1//2 ...
                    let hasPosition: Bool = attributeCount > 0 && vertexAttributes[0].count > 0
                    let hasUV: Bool = attributeCount > 1 && vertexAttributes[1].count > 0 
                    let hasNormal: Bool = attributeCount > 2 && vertexAttributes[2].count > 0
                    if hasPosition { positions[i] = vertexPositions[Int(vertexAttributes[0])! - 1] }
                    if hasUV { uvs[i] = vertexUVs[Int(vertexAttributes[1])! - 1] }
                    if hasNormal { normals[i] = vertexNormals[Int(vertexAttributes[2])! - 1] }
                }

                let baseIndex = UInt32(truncatingIfNeeded: vertices.count)
                let faceNormal: simd_float3 = simd_normalize(simd_cross(positions[1]! - positions[0]!, positions[2]! - positions[0]!))
                for (i, position) in positions.enumerated() {
                    guard let position = position else { continue }
                    vertices.append(Vertex(position: position, uv: uvs[i] ?? simd_float2(0, 0), normal: normals[i] ?? faceNormal))
                    currentSubMeshVertexCount += 1
                    currentMeshVertexCount += 1
                }

                func newTriangle() {
                    faces.append(Face(
                        vertexIndices: simd_uint3(baseIndex, baseIndex + (!useClockWiseTriangles ? 1 : 2), baseIndex + (!useClockWiseTriangles ? 2 : 1)), 
                        subMeshIndex: currentSubMeshOffset
                    ))
                    currentSubMeshFaceCount += 1
                    currentMeshFaceCount += 1
                }

                func newQuad() {
                    faces.append(Face(
                        vertexIndices: simd_uint3(baseIndex, baseIndex + (!useClockWiseTriangles ? 1 : 2), baseIndex + (!useClockWiseTriangles ? 2 : 1)), 
                        subMeshIndex: currentSubMeshOffset
                    ))
                    faces.append(Face(
                        vertexIndices: simd_uint3(baseIndex, baseIndex + (!useClockWiseTriangles ? 2 : 3), baseIndex + (!useClockWiseTriangles ? 3 : 2)), 
                        subMeshIndex: currentSubMeshOffset
                    ))
                    currentSubMeshFaceCount += 2
                    currentMeshFaceCount += 2
                }
                
                if vertexAttributes4 == nil { newTriangle() } else { newQuad() }
            case "o": continue parseLine // Model
            case "g":
                pushSubMesh()
                pushMesh()
                currentMeshName = tokens[1]
            case "usemtl":
                currentMaterialIndex = materialNameIndices[tokens[1]]
                if currentMaterialIndex == nil {
                    print("Material \(tokens[1]) was not found!")
                }
                pushSubMesh()
            case "mtllib":
                let (newMaterials, newMaterialNameIndices) = materialImporter.importMaterial(
                    filePath: objURL.deletingLastPathComponent().appendingPathComponent(tokens[1]).path
                )
                let materialCount = Int32(truncatingIfNeeded: materials.count)
                for (newMaterialName, newMaterialIndex) in newMaterialNameIndices {
                    materialNameIndices[newMaterialName] = newMaterialIndex + materialCount
                }
                materials.append(contentsOf: newMaterials)
            default: continue parseLine
            }
        }

        // Finalise
        pushSubMesh()
        pushMesh()

        // Centering
        if importAtOrigin {
            var vertexSum = simd_float3(0, 0, 0)
            for vertexPosition in vertexPositions { vertexSum += vertexPosition }
            let vertexAverage = vertexSum / Float(vertexPositions.count)
            for i in 0..<vertices.count { vertices[i].position -= vertexAverage }
            for i in 0..<meshes.count { 
                meshes[i].pivot -= vertexAverage 
                meshes[i].localMinBounds -= vertexAverage
                meshes[i].localMaxBounds -= vertexAverage
            }
        }

        return ObjectAsset(vertices: vertices, faces: faces, materials: materials, textures: materialImporter.getTextures(), subMeshes: subMeshes, meshes: meshes)
    }
}