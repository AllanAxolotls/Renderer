import Metal
import MetalKit
import Foundation

// Settings
private let useClockWiseTriangles: Bool = false
private let importAtOrigin: Bool = true

private final class FileResolver {

    private let fileManager = FileManager.default
    private let root: URL

    private var cache: [String: String] = [:]
    private var didBuildIndex = false

    init() {
        self.root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    }

    func resolveFilePath(fileName: String) -> String? {
        print("Resolving \(fileName)")

        // fast path
        if let cached = cache[fileName] {
            return cached
        }

        buildIndexIfNeeded()

        // 1. direct hit
        if let path = cache[fileName] {
            return path
        }

        // 2. _diff variant fallback
        if let variant = makeVariant(fileName),
           let path = cache[variant] {
            cache[fileName] = path
            return path
        }

        return nil
    }

    private func buildIndexIfNeeded() {
        guard !didBuildIndex else { return }
        didBuildIndex = true

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }

        for case let url as URL in enumerator {
            cache[url.lastPathComponent] = url.path
        }
    }

    private func makeVariant(_ name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        guard let idx = base.lastIndex(of: "_") else { return nil }

        let stripped = String(base[..<idx])
        return ext.isEmpty ? stripped : "\(stripped).\(ext)"
    }
}
nonisolated(unsafe) private let resolver = FileResolver()

private func resolveFilePath(fileName: String) -> String? {
    resolver.resolveFilePath(fileName: fileName)
}

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

    public func getTexture(_ fileName: String) -> (MTLTexture?, Int32?) {
        if let index = nameToIndices[fileName] {
            return (textures[Int(index)], index)
        }
        return (nil, nil)
    }
    public func getTextureIndex(_ fileName: String) -> Int32? {
        return nameToIndices[fileName]
    }

    private func loadTexture(fileName: String) -> MTLTexture? {
        if let fixedPath = resolveFilePath(fileName: fileName) {
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
            print("Loading texture '\(fileName)' failed, not found in directory")
            return nil
        }
    }

    public func importTexture(fileName: String) -> (MTLTexture, Int32) {
        let (existingTexture, existingIndex) = getTexture(fileName)
        if existingTexture != nil { return (existingTexture!, existingIndex!) }
        if let texture = loadTexture(fileName: fileName) {
            let index = Int32(truncatingIfNeeded: textures.count)
            nameToIndices[fileName] = index
            textures.append(texture)
            return (texture, index)
        }
        nameToIndices[fileName] = 0 // fallback texture
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

    public func importMaterial(fileName: String) -> (materials: [Material], materialNameIndices: [String : Int32]) {
        var materials: [Material] = []
        var materialNameIndices: [String : Int32] = [:]

        guard let resolvedFilePath = resolveFilePath(fileName: fileName) else {
            print("Failed loading file: \(fileName), not found in directory!")
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

        if let contents = try? String(contentsOfFile: resolvedFilePath, encoding: .utf8) {
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
                    (_, currentMaterial.ambientTextureIndex) = textureImporter.importTexture(fileName: tokens[1])
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
        } else {
            print("Material file \(fileName) could not be found in directory!")
        }

        return (materials: materials, materialNameIndices: materialNameIndices)
    }

    public func getTextures() -> [MTLTexture] {
        return textureImporter.textures
    }
}

public class ObjectImporter {
    public var materialImporter: MaterialImporter

    init(device: MTLDevice) {
        materialImporter = MaterialImporter(device: device)
    }

    func importObject(fileName: String) -> (
        vertices: [Vertex], faces: [Face], materials: [Material], textures: [MTLTexture], 
        subMeshes: [SubMesh], meshes: [Mesh]
    ) {
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
        guard let resolvedFilePath = resolveFilePath(fileName: fileName) else {
            print("Failed loading file: \(fileName), not found in directory!")
            return (vertices: vertices, faces: faces, materials: materials, 
                textures: materialImporter.getTextures(), subMeshes: subMeshes, meshes: meshes
        )
        }

        if let contents = try? String(contentsOfFile: resolvedFilePath, encoding: .utf8) {
            // Parse .obj
            var currentVertexOffset: Int32 = 0
            var currentVertexCount: Int32 = 0
            var currentFaceOffset: Int32 = 0
            var currentFaceCount: Int32 = 0
            var currentSubMeshOffset: Int32 = 0
            var currentSubMeshCount: Int32 = 0
            var currentMaterialIndex: Int32? = nil

            func pushSubMesh() {
                if currentVertexCount == 0 { return }
                let subMesh = SubMesh(
                    vertexOffset: currentVertexOffset, 
                    vertexCount: currentVertexCount, 
                    faceOffset: currentFaceOffset, 
                    faceCount: currentFaceCount,
                    materialIndex: currentMaterialIndex ?? -1, 
                )
                subMeshes.append(subMesh)
                currentSubMeshCount += 1
                currentVertexOffset += currentVertexCount
                currentFaceOffset += currentFaceCount
                currentVertexCount = 0
                currentFaceCount = 0
                currentMaterialIndex = nil
            }

            func pushMesh() {
                if currentSubMeshCount == 0 { return }
                let mesh = Mesh(subMeshOffset: currentSubMeshOffset, subMeshCount: currentSubMeshCount)
                meshes.append(mesh)
                currentSubMeshOffset += currentSubMeshCount
                currentSubMeshCount = 0
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
                        currentVertexCount += 1
                    }

                    func newTriangle() {
                        faces.append(Face(
                            vertexIndices: simd_uint3(baseIndex, baseIndex + (!useClockWiseTriangles ? 1 : 2), baseIndex + (!useClockWiseTriangles ? 2 : 1)), 
                            subMeshIndex: currentSubMeshOffset
                        ))
                        currentFaceCount += 1
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
                        currentFaceCount += 2
                    }
                    
                    if vertexAttributes4 == nil { newTriangle() } else { newQuad() }

                    /*
                    let attributeCount = vertexAttributes1.count
                    let position1 = vertexPositions[Int(vertexAttributes1[0])! - 1]
                    let position2 = vertexPositions[Int(vertexAttributes2[0])! - 1]
                    let position3 = vertexPositions[Int(vertexAttributes3[0])! - 1]
                    let uv1 = attributeCount >= 2 ? vertexUVs[Int(vertexAttributes1[1])! - 1] : simd_float2(0, 0)
                    let uv2 = attributeCount >= 2 ? vertexUVs[Int(vertexAttributes2[1])! - 1] : simd_float2(0, 1)
                    let uv3 = attributeCount >= 2 ? vertexUVs[Int(vertexAttributes3[1])! - 1] : simd_float2(1, 0)
                    let triangleNormal = attributeCount < 3 ? simd_normalize(simd_cross(position2 - position1, position3 - position1)) : nil
                    let normal1 = attributeCount >= 3 ? vertexNormals[Int(vertexAttributes1[2])! - 1] : triangleNormal!
                    let normal2 = attributeCount >= 3 ? vertexNormals[Int(vertexAttributes2[2])! - 1] : triangleNormal!
                    let normal3 = attributeCount >= 3 ? vertexNormals[Int(vertexAttributes3[2])! - 1] : triangleNormal!
                    let vertex1 = Vertex(position: position1, uv: uv1, normal: normal1)
                    let vertex2 = Vertex(position: position2, uv: uv2, normal: normal2)
                    let vertex3 = Vertex(position: position3, uv: uv3, normal: normal3)
                    let baseIndex = Int32(truncatingIfNeeded: vertices.count)
                    vertices.append(contentsOf: !useClockWiseTriangles ? [vertex1,vertex2,vertex3] : [vertex1,vertex3,vertex2])
                    faces.append(Face(
                        vertexIndices: simd_int3(baseIndex, baseIndex + (!useClockWiseTriangles ? 1 : 2), baseIndex + (!useClockWiseTriangles ? 2 : 1)),
                        subMeshIndex: currentSubMeshOffset
                    ))
                    
                    currentVertexCount += 3
                    currentFaceCount += 1

                    if tokens.count == 5 && !tokens[4].isEmpty {
                        let vertexAttributes4 = tokens[4].components(separatedBy: "/")
                        let position4 = vertexPositions[Int(vertexAttributes4[0])! - 1]
                        let uv4 = attributeCount >= 2 ? vertexUVs[Int(vertexAttributes4[1])! - 1] : simd_float2(1, 1)
                        let normal4 = attributeCount >= 3 ? vertexNormals[Int(vertexAttributes4[2])! - 1] : triangleNormal!
                        let vertex4 = Vertex(position: position4, uv: uv4, normal: normal4)
                        vertices.append(contentsOf: !useClockWiseTriangles ? [vertex1,vertex3,vertex4] : [vertex1,vertex4,vertex3])
                        faces.append(Face(
                            vertexIndices: simd_int3(baseIndex, baseIndex + (!useClockWiseTriangles ? 2 : 3), baseIndex + (!useClockWiseTriangles ? 3 : 2)),
                            subMeshIndex: currentSubMeshOffset
                        ))
                        currentVertexCount += 1
                        currentFaceCount += 1
                    }
                    */
                case "o": continue parseLine // Model
                case "g":
                    pushSubMesh()
                    pushMesh()
                case "usemtl":
                    currentMaterialIndex = materialNameIndices[tokens[1]]
                    if currentMaterialIndex == nil {
                        print("Material \(tokens[1]) was not found!")
                    }
                    pushSubMesh()
                case "mtllib":
                    let (newMaterials, newMaterialNameIndices) = materialImporter.importMaterial(fileName: tokens[1])
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
        } else {
            print("Failed opening file at: \(resolvedFilePath)")
        }

        // Centering
        if importAtOrigin {
            var vertexSum = simd_float3(0, 0, 0)
            for vertexPosition in vertexPositions { vertexSum += vertexPosition }
            let vertexAverage = vertexSum / Float(vertexPositions.count)
            for i in 0..<vertices.count { vertices[i].position -= vertexAverage }
        }

        return (vertices: vertices, faces: faces, materials: materials, 
            textures: materialImporter.getTextures(), subMeshes: subMeshes, meshes: meshes
        )
    }
}