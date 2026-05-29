import Metal
import MetalKit
import Foundation

// TODO: Make it so vertex normals are not [0, 1, 0] on default but calculated if missing

// Settings
private let useClockWiseTriangles: Bool = false
private let bakedVertexShift = simd_float3(-100, -20, -250)
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
                    let vertexAttributes1 = tokens[1].components(separatedBy: "/")
                    let vertexAttributes2 = tokens[2].components(separatedBy: "/")
                    let vertexAttributes3 = tokens[3].components(separatedBy: "/")
                    let attributeCount = vertexAttributes1.count
                    let position1 = vertexPositions[Int(vertexAttributes1[0])! - 1]
                    let position2 = vertexPositions[Int(vertexAttributes2[0])! - 1]
                    let position3 = vertexPositions[Int(vertexAttributes3[0])! - 1]
                    let uv1 = attributeCount >= 2 ? vertexUVs[Int(vertexAttributes1[1])! - 1] : simd_float2(0, 0)
                    let uv2 = attributeCount >= 2 ? vertexUVs[Int(vertexAttributes2[1])! - 1] : simd_float2(0, 1)
                    let uv3 = attributeCount >= 2 ? vertexUVs[Int(vertexAttributes3[1])! - 1] : simd_float2(1, 0)
                    let normal1 = attributeCount >= 3 ? vertexNormals[Int(vertexAttributes1[2])! - 1] : simd_float3(0, 1, 0)
                    let normal2 = attributeCount >= 3 ? vertexNormals[Int(vertexAttributes2[2])! - 1] : simd_float3(0, 1, 0)
                    let normal3 = attributeCount >= 3 ? vertexNormals[Int(vertexAttributes3[2])! - 1] : simd_float3(0, 1, 0)
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
                        let normal4 = attributeCount >= 3 ? vertexNormals[Int(vertexAttributes4[2])! - 1] : simd_float3(0, 1, 0)
                        let vertex4 = Vertex(position: position4, uv: uv4, normal: normal4)
                        vertices.append(contentsOf: !useClockWiseTriangles ? [vertex1,vertex3,vertex4] : [vertex1,vertex4,vertex3])
                        faces.append(Face(
                            vertexIndices: simd_int3(baseIndex, baseIndex + (!useClockWiseTriangles ? 2 : 3), baseIndex + (!useClockWiseTriangles ? 3 : 2)),
                            subMeshIndex: currentSubMeshOffset
                        ))
                        currentVertexCount += 1
                        currentFaceCount += 1
                    }
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
/*

private func makeWhiteTexture(device: MTLDevice) -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: 1,
        height: 1,
        mipmapped: false
    )

    desc.usage = .shaderRead

    let texture = device.makeTexture(descriptor: desc)!

    var white: [UInt8] = [255, 255, 255, 255] // RGBA
    texture.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: &white,
        bytesPerRow: 4
    )

    return texture
}

func resolveTexturePath(_ path: String) -> String {
    for pathVariant in [path, "Assets/\(path)"] {
        let url = URL(fileURLWithPath: pathVariant)

        let candidates = [
            url,
            url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_diff.png"),
            url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png"),
            url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: "_diff", with: "")),
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        } 
    }
    return path
}

func loadTexture(device: MTLDevice, texturePath: String) throws -> MTLTexture? {
    let textureLoader = MTKTextureLoader(device: device)
    let fixedPath = resolveTexturePath(texturePath)
    let textureURL = URL(fileURLWithPath: fixedPath)
    let options: [MTKTextureLoader.Option: Any] = [
        .origin: MTKTextureLoader.Origin.bottomLeft, // important for OBJ UVs
        .SRGB: true
    ]
    
    if let texture = try? textureLoader.newTexture(URL: textureURL, options: options) { return texture }
    print("Loading texture '\(fixedPath)' failed, not found in directory")
    return nil
}

class TextureManager {
    private var textures: [String: MTLTexture] = [:]
    private let device: MTLDevice
    
    init(device: MTLDevice) {
        self.device = device
    }
    
    func load(name: String, path: String) throws -> MTLTexture? {
        if let existing = textures[name] {
            return existing
        }
        
        if let texture = try? loadTexture(device: device, texturePath: path) {
            textures[name] = texture
            return texture
        }

        return nil
    }
    
    func get(_ name: String) -> MTLTexture? {
        return textures[name]
    }
}

class MTLImporter {
    let device: MTLDevice!
    let defaultTexture: MTLTexture!
    let textureManager: TextureManager!

    init(device: MTLDevice, textureManager: TextureManager) {
        self.device = device
        self.defaultTexture = makeWhiteTexture(device: device)
        self.textureManager = textureManager
    }

    func makeDefaultMaterial() -> Material {
        return Material(
            name: "DefaultMaterial", Ka: [1, 1, 1], Kd: [1, 1, 1], Ks: [0, 0, 0], Ke: 0, 
            Ns: 0, Ni: 0, illum: 0, d: 1, map_Ka: defaultTexture, map_Kd: defaultTexture, map_Ks: defaultTexture, map_Bump: defaultTexture
        )
    }

    func importMaterial(path: String) -> [Material] {
        var materials: [Material] = []
        let contents = try? String(contentsOfFile: "Assets/\(path)", encoding: .utf8)

        var current_material: Material = makeDefaultMaterial()
        var first_material: Bool = true

        if let text = contents {
            let lines = text.components(separatedBy: .newlines)

            for line in lines {
                let tokens = line.components(separatedBy: " ")
                let command = tokens[0]

                if line.isEmpty { continue }
                if command == "#" { continue }

                if command == "Material" {} // Type of material, like Plastic, Metal
                else if command == "Ka" { current_material.Ka = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!) }
                else if command == "Kd" { current_material.Kd = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!) }
                else if command == "Ks" { current_material.Ks = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!) }
                else if command == "Ke" { current_material.Ke = Float(tokens[1])! }
                else if command == "Ns" { current_material.Ns = Float(tokens[1])! }
                else if command == "Ni" { current_material.Ni = Float(tokens[1])! }
                else if command == "d" { current_material.d = Float(tokens[1])! }
                else if command == "illum" { current_material.illum = Float(tokens[1])! }
                else if command == "map_Ka" { current_material.map_Ka = (try? textureManager.load(name: tokens[1], path: tokens[1])) ?? defaultTexture }
                else if command == "map_Kd" { current_material.map_Kd = (try? textureManager.load(name: tokens[1], path: tokens[1])) ?? defaultTexture }
                else if command == "map_Ks" { current_material.map_Ks = (try? textureManager.load(name: tokens[1], path: tokens[1])) ?? defaultTexture }
                else if command == "map_Bump" { current_material.map_Bump = (try? textureManager.load(name: tokens[1], path: tokens[1])) ?? defaultTexture }
                else if command == "newmtl" {
                    if (!first_material) { materials.append(current_material) }
                    first_material = false
                    current_material = makeDefaultMaterial()
                    current_material.name = tokens[1]
                }
            }

            materials.append(current_material)

            return materials
        }

        print("Material file \"\(path)\" does not exist!\n")
        return materials
    }
}

class OBJMTLImporter {
    let mtlImporter: MTLImporter!

    init(device: MTLDevice, textureManager: TextureManager) {
        mtlImporter = MTLImporter(device: device, textureManager: textureManager)
    }

    func importObject(path: String) -> [Mesh] {
        let contents = try? String(contentsOfFile: path, encoding: .utf8)

        var materials: [Material] = []
        var meshes: [Mesh] = []

        var current_mesh: Mesh = Mesh(
            name: "Mesh",
            position: simd_float3(0,0,0),
            rotation: simd_float3(0,0,0),
            size: simd_float3(1,1,1),
            subMeshes: [],
            
        )
        var current_submesh: SubMesh = SubMesh(triangles: [], material: nil)
        var current_material: Material = mtlImporter.makeDefaultMaterial()

        let centerSubmesh = {
            var averagePosition = simd_float3(0, 0, 0)
            if importAtOrigin {
                var vertexCount: Int = 0
                for triangle in current_submesh.triangles {
                    for vertex in triangle.vertices { averagePosition += vertex.position }
                    vertexCount += triangle.vertices.count
                }

                if vertexCount != 0 { averagePosition /= Float(vertexCount) }
            }

            for t in current_submesh.triangles.indices {
                for v in current_submesh.triangles[t].vertices.indices {
                    current_submesh.triangles[t].vertices[v].position -= averagePosition
                    current_submesh.triangles[t].vertices[v].position += bakedVertexShift
                }
            }
        }

        if let text = contents {
            var listed_verts: [simd_float3] = []
            var listed_normals: [simd_float3] = []
            var listed_uvs: [simd_float2] = []

            let lines = text.components(separatedBy: .newlines)

            for line in lines {
                //let new_line = String(line.dropLast())
                let tokens = line.components(separatedBy: " ")
                let command = tokens[0]

                if line.isEmpty { continue }
                if command == "#" { continue }

                if command == "v" {
                    listed_verts.append(simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!))
                } else if command == "vt" {
                    listed_uvs.append(simd_float2(Float(tokens[1])!, Float(tokens[2])!))
                } else if command == "vn" {
                    listed_normals.append(simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!))
                } else if command == "s" { // Smooth Shading
                } else if command == "f" {
                    let segments1 = tokens[1].components(separatedBy: "/")
                    let segments2 = tokens[2].components(separatedBy: "/")
                    let segments3 = tokens[3].components(separatedBy: "/")
                    let segment_count = segments1.count

                    let position1: simd_float3 = listed_verts[Int(segments1[0])! - 1]
                    let position2: simd_float3 = listed_verts[Int(segments2[0])! - 1]
                    let position3: simd_float3 = listed_verts[Int(segments3[0])! - 1]
                    let uv1: simd_float2? = segment_count >= 2 ? listed_uvs[Int(segments1[1])! - 1] : nil
                    let uv2: simd_float2? = segment_count >= 2 ? listed_uvs[Int(segments2[1])! - 1] : nil
                    let uv3: simd_float2? = segment_count >= 2 ? listed_uvs[Int(segments3[1])! - 1] : nil
                    let normal1: simd_float3? = segment_count >= 3 ? listed_normals[Int(segments1[2])! - 1] : nil
                    let normal2: simd_float3? = segment_count >= 3 ? listed_normals[Int(segments2[2])! - 1] : nil
                    let normal3: simd_float3? = segment_count >= 3 ? listed_normals[Int(segments3[2])! - 1] : nil
                    
                    let vertex1 = Vertex(position: position1, uv: uv1 ?? simd_float2(1, 0), normal: normal1)
                    let vertex2 = Vertex(position: position2, uv: uv2 ?? simd_float2(0, 1), normal: normal2)
                    let vertex3 = Vertex(position: position3, uv: uv3 ?? simd_float2(1, 1), normal: normal3)

                    current_submesh.triangles.append(Triangle(
                        vertices: !useClockWiseTriangles ? [vertex1, vertex2, vertex3] : [vertex1, vertex3, vertex2],
                        subMesh: current_submesh
                    ))

                    if tokens.count == 5 && !tokens[4].isEmpty {
                        let segments4 = tokens[4].components(separatedBy: "/")
                        let position4: simd_float3 = listed_verts[Int(segments4[0])! - 1]
                        let uv4: simd_float2? = segment_count >= 2 ? listed_uvs[Int(segments4[1])! - 1] : nil
                        let normal4: simd_float3? = segment_count >= 3 ? listed_normals[Int(segments4[2])! - 1] : nil
                        let vertex4 =  Vertex(position: position4, uv: uv4 ?? simd_float2(1, 1), normal: normal4)

                        current_submesh.triangles.append(Triangle(
                            vertices: !useClockWiseTriangles ? [vertex1, vertex3, vertex4] : [vertex1, vertex4, vertex3],
                            subMesh: current_submesh
                        ))
                    }
                // o = Model in roblox
                } else if command == "o" { // Higher on hierarchy than "g": subgroup

                // g = Mesh
                } else if command == "g" {
                    if current_mesh.subMeshes.count > 0 {
                        meshes.append(current_mesh)
                    }
                    current_mesh = Mesh(
                        name: tokens[1],
                        position: simd_float3(0,0,0),
                        rotation: simd_float3(0,0,0),
                        size: simd_float3(1,1,1),
                        subMeshes: []
                    )
                } else if command == "usemtl" { // Use Material from loaded material list
                    for material in materials {
                        if material.name == tokens[1] {
                            current_material = material
                        }
                    }
                    if current_submesh.triangles.count > 0 {
                        centerSubmesh()
                        current_mesh.subMeshes.append(current_submesh)
                        current_submesh = SubMesh(triangles: [], material: current_material)
                    }
                    current_submesh.material = current_material
                } else if command == "mtllib" { // Load Material File
                    materials.append(contentsOf: mtlImporter.importMaterial(path: tokens[1]))
                }
            }

            if current_submesh.triangles.count > 0 {
                centerSubmesh()
                current_mesh.subMeshes.append(current_submesh)
            }
            if current_mesh.subMeshes.count > 0 {
                meshes.append(current_mesh)
            }

            return meshes
        }

        print("Object file \"\(path)\" does not exist!\n")
        return meshes
    }
}

*/