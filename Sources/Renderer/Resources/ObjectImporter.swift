import Metal
import MetalKit
import Foundation

// Unused, should be used for material merging in the future
private func areMaterialsEqual(materialA: Material, materialB: Material) -> Bool {
    if !simd_equal(materialA.diffuseColor, materialB.diffuseColor) { return false }
    if materialA.diffuseTextureIndex != materialB.diffuseTextureIndex { return false }
    if materialA.dissolveTextureIndex != materialB.dissolveTextureIndex { return false }
    if materialA.dissolve != materialB.dissolve { return false }
    return true
}

private func toByte(_ x: Float) -> UInt8 {
    let safe = x.isNaN || x.isInfinite ? 0 : x
    let clamped = min(max(safe, 0), 255)
    return UInt8(clamped)
}

private func make1x1Texture(device: MTLDevice, textures: inout [MTLTexture], colorIndexCache: inout [simd_float4 : Int16], colorTextureCache: inout [simd_float4: MTLTexture], color: simd_float4) -> (MTLTexture, Int16) {
    if let existing = colorTextureCache[color] { return (existing, colorIndexCache[color]!) }

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm_srgb,
        width: 1,
        height: 1,
        mipmapped: false
    )

    desc.usage = .shaderRead

    let texture = device.makeTexture(descriptor: desc)!

    var rgbColor: [UInt8] = [toByte(color.x * 255), toByte(color.y * 255), toByte(color.z * 255), toByte(color.w * 255)] // RGBA
    texture.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: &rgbColor,
        bytesPerRow: 4
    )

    colorTextureCache[color] = texture
    let index = Int16(textures.count)
    textures.append(texture)
    colorIndexCache[color] = index

    return (texture, index)
}


public class TextureImporter {
    public var textures: [MTLTexture] = []
    public var nameToIndices: [String : Int16] = [:]
    public var defaultRGBA1111Texture: MTLTexture? = nil
    private let device: MTLDevice?
    private var mtkTextureLoader: MTKTextureLoader? = nil

    private var colorTextureCache: [simd_float4: MTLTexture] = [:]
    private var colorIndexCache: [simd_float4: Int16] = [:]

    init(device: MTLDevice?) {
        self.device = device

        if let device = device {
            self.mtkTextureLoader = MTKTextureLoader(device: device)
            (self.defaultRGBA1111Texture, _) = make1x1Texture(device: device, textures: &textures, colorIndexCache: &colorIndexCache, colorTextureCache: &colorTextureCache, color: simd_float4(1, 1, 1, 1))
        }
    }

    public func getTexture(_ filePath: String) -> (MTLTexture?, Int16?) {
        if let index = nameToIndices[filePath] {
            return (textures[Int(index)], index)
        }
        return (nil, nil)
    }
    public func getTextureIndex(_ filePath: String) -> Int16? {
        return nameToIndices[filePath]
    }

    private func loadTexture(filePath: String) -> MTLTexture? {
        guard let mtkTextureLoader = mtkTextureLoader else {
            print("MTKTextureLoader is not initialized, cannot load texture \(filePath)")
            return nil
        }
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

    public func importTexture(filePath: String) -> (MTLTexture?, Int16) {
        let (existingTexture, existingIndex) = getTexture(filePath)
        if existingTexture != nil { return (existingTexture!, existingIndex!) }
        if let texture = loadTexture(filePath: filePath) {
            let index = Int16(textures.count)
            nameToIndices[filePath] = index
            textures.append(texture)
            return (texture, index)
        }
        if defaultRGBA1111Texture != nil {
            nameToIndices[filePath] = 0 // fallback texture
            return (textures[0], 0)
        } else {
            return (nil, -1)
        }
    }

    public func getColorTexture(color: simd_float4) -> (MTLTexture?, Int16) {
        guard let device = device else {
            print("MTLDevice is not initialized, cannot create color texture")
            return (nil, -1)
        }
        return make1x1Texture(device: device, textures: &textures, colorIndexCache: &colorIndexCache, colorTextureCache: &colorTextureCache, color: color)
    }
}

// TODO: Add material merging if names are the same
public class MaterialImporter {
    private var textureImporter: TextureImporter

    init(device: MTLDevice?) {
        textureImporter = TextureImporter(device: device)
    }

    public func importMaterial(filePath: String) -> (materials: [Material], materialNameIndices: [String : Int32]) {
        var materials: [Material] = []
        var materialNameIndices: [String : Int32] = [:]

        guard let resolvedFilePath = resolveFilePath(filePath: filePath) else {
            print("Failed loading file: \(filePath), not found in directory!")
            return (materials: materials, materialNameIndices: materialNameIndices)
        }

        var materialIndex: Int32 = -1
        var currentMaterial = Material()

        func pushMaterial() {
            materials.append(currentMaterial)
            currentMaterial = Material()
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
            //case "Ka": currentMaterial.ambientColor = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!)
            case "Kd": currentMaterial.diffuseColor = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!)
            //case "Ks": currentMaterial.specularColor = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!)
            case "Ke": currentMaterial.emissionColor = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!)
            //case "map_Ka": (_, currentMaterial.ambientTextureIndex) = textureImporter.importTexture(filePath: mtlDirURL.appendingPathComponent(tokens[1]).path)
            case "map_Kd": (_, currentMaterial.diffuseTextureIndex) = textureImporter.importTexture(filePath: mtlDirURL.appendingPathComponent(tokens[1]).path)
            //case "map_Ks": (_, currentMaterial.specularTextureIndex) = textureImporter.importTexture(filePath: mtlDirURL.appendingPathComponent(tokens[1]).path)
            case "map_d": (_, currentMaterial.dissolveTextureIndex) = textureImporter.importTexture(filePath: mtlDirURL.appendingPathComponent(tokens[1]).path)
            //case "map_Bump": (_, currentMaterial.bumpTextureIndex) = textureImporter.importTexture(filePath: mtlDirURL.appendingPathComponent(tokens[1]).path)
            //case "illum": currentMaterial.illuminationModel = Int16(tokens[1])!
            case "d": currentMaterial.dissolve = Float(tokens[1])!
            case "Tr": currentMaterial.dissolve = 1.0 - Float(tokens[1])!
            case "Ns": currentMaterial.roughness = 1// 1 - pow(2 / (Float(tokens[1])! + 2), 1/4)
            case "Pr": currentMaterial.roughness = Float(tokens[1])!
            case "Pm": currentMaterial.metallic = Float(tokens[1])!
            //case "Ni": currentMaterial.refractiveIndex = Float(tokens[1])!
            // case "sharpness":
            // case "Tf":
            // case "refl":
            // case "disp":
            // case "decal":
            case "newmtl":
                if materialIndex != -1 { pushMaterial() }
                materialIndex += 1
                materialNameIndices[tokens[1]] = materialIndex
                //print("\(tokens[1]) : \(materialIndex)")
            default: continue parseLine
            }
        }
        // Finalise
        pushMaterial()

        return (materials: materials, materialNameIndices: materialNameIndices)
    }

    public func getTextures() -> [MTLTexture] {
        return Array(textureImporter.textures[1...])
    }

    public func getDefaultDiffuseTexture() -> MTLTexture? {
        return textureImporter.defaultRGBA1111Texture
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
    public var importOffset: simd_float3 = simd_float3(0, 0, 0)
    public var importAtOrigin: Bool = false
    public var importCCWFaces: Bool = true
    public var flipX: Bool = false
    public var flipY: Bool = false
    public var flipZ: Bool = true

    init(device: MTLDevice?) {
        materialImporter = MaterialImporter(device: device)
    }

    func importObject(filePath: String) -> ObjectAsset {
        guard let resolvedPath = resolveFilePath(filePath: filePath),
            let contents = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            print("Failed to open OBJ file: \(filePath)")
            return ObjectAsset(vertices: [], faces: [], materials: [], textures: materialImporter.getTextures(), subMeshes: [], meshes: [])
        }

        let objURL = URL(fileURLWithPath: resolvedPath)

        var rawPositions: [simd_float3] = []
        var rawUVs: [simd_float2] = []
        var rawNormals: [simd_float3] = []

        // Final output buffers
        var materials: [Material] = []
        var vertices: [Vertex] = []
        var faces: [Face] = []
        var subMeshes: [SubMesh] = []
        var meshes: [Mesh] = []
        var materialNameToIndex: [String: Int32] = [:]

        // Vertex Deduplication Hash Map: [VertexKey : Final Buffer Index]
        struct VertexKey: Hashable {
            let pIndex: Int
            let uIndex: Int
            let nIndex: Int
        }
        var vertexCache: [VertexKey: UInt32] = [:]

        var currentMeshName = "Mesh"
        var currentMaterialIndex: Int32 = -1

        var currentSubMeshFaceOffset: UInt32 = 0
        var currentSubMeshVertexOffset: UInt32 = 0

        var currentMeshFaceOffset: UInt32 = 0
        var currentMeshVertexOffset: UInt32 = 0
        var currentMeshSubMeshOffset: UInt32 = 0

        func flushSubMesh() {
            let faceCount = UInt32(faces.count) - currentSubMeshFaceOffset
            let vertexCount = UInt32(vertices.count) - currentSubMeshVertexOffset
            guard faceCount > 0 else { return }

            // Compute local bounds center for distance sorting
            var minPos = simd_float3(repeating: .greatestFiniteMagnitude)
            var maxPos = simd_float3(repeating: -.greatestFiniteMagnitude)
            for i in Int(currentSubMeshVertexOffset)..<vertices.count {
                minPos = simd.min(minPos, vertices[i].position)
                maxPos = simd.max(maxPos, vertices[i].position)
            }

            let subMesh = SubMesh(
                vertexOffset: Int32(currentSubMeshVertexOffset),
                vertexCount: Int32(vertexCount),
                faceOffset: Int32(currentSubMeshFaceOffset),
                faceCount: Int32(faceCount),
                materialIndex: currentMaterialIndex,
                meshIndex: Int32(meshes.count),
            )
            subMeshes.append(subMesh)

            currentSubMeshFaceOffset = UInt32(faces.count)
            currentSubMeshVertexOffset = UInt32(vertices.count)
        }

        func flushMesh() {
            flushSubMesh()

            let faceCount = UInt32(faces.count) - currentMeshFaceOffset
            let vertexCount = UInt32(vertices.count) - currentMeshVertexOffset
            let subMeshCount = UInt32(subMeshes.count) - currentMeshSubMeshOffset
            guard subMeshCount > 0 else { return }

            var minBounds = simd_float3(repeating: .greatestFiniteMagnitude)
            var maxBounds = simd_float3(repeating: -.greatestFiniteMagnitude)
            for i in Int(currentMeshVertexOffset)..<vertices.count {
                minBounds = simd.min(minBounds, vertices[i].position)
                maxBounds = simd.max(maxBounds, vertices[i].position)
            }

            let mesh = Mesh(
                name: currentMeshName,
                pivot: (minBounds + maxBounds) * 0.5,
                subMeshOffset: Int32(currentMeshSubMeshOffset),
                subMeshCount: Int32(subMeshCount),
                faceOffset: Int32(currentMeshFaceOffset),
                faceCount: Int32(faceCount),
                vertexOffset: Int32(currentMeshVertexOffset),
                vertexCount: Int32(vertexCount),
                localMinBounds: minBounds,
                localMaxBounds: maxBounds
            )
            meshes.append(mesh)

            currentMeshFaceOffset = UInt32(faces.count)
            currentMeshVertexOffset = UInt32(vertices.count)
            currentMeshSubMeshOffset = UInt32(subMeshes.count)
        }

        func resolveIndex(_ rawStr: String, count: Int) -> Int {
            guard let idx = Int(rawStr), idx != 0 else { return -1 }
            return idx > 0 ? idx - 1 : count + idx
        }

        func getOrAddVertex(pStr: String, uStr: String, nStr: String, fallbackNormal: simd_float3) -> UInt32 {
            let pIdx = resolveIndex(pStr, count: rawPositions.count)
            let uIdx = resolveIndex(uStr, count: rawUVs.count)
            let nIdx = resolveIndex(nStr, count: rawNormals.count)

            let key = VertexKey(pIndex: pIdx, uIndex: uIdx, nIndex: nIdx)
            if let existingIndex = vertexCache[key] {
                return existingIndex
            }

            let pos = (pIdx >= 0 && pIdx < rawPositions.count) ? rawPositions[pIdx] : simd_float3(0, 0, 0)
            let uv = (uIdx >= 0 && uIdx < rawUVs.count) ? rawUVs[uIdx] : simd_float2(0, 0)
            let norm = (nIdx >= 0 && nIdx < rawNormals.count) ? rawNormals[nIdx] : fallbackNormal

            let newVertex = Vertex(position: pos, normal: norm, uv: uv)
            //let newVertex = Vertex(position: pos, uv: uv, normal: norm)
            let newIndex = UInt32(vertices.count)
            vertices.append(newVertex)
            vertexCache[key] = newIndex
            return newIndex
        }

        let lines = contents.components(separatedBy: .newlines)

        for line in lines {
            let cleaned = line.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned.hasPrefix("#") { continue }

            let tokens = cleaned.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard let command = tokens.first else { continue }

            switch command {
            case "v":
                if tokens.count >= 4 {
                    rawPositions.append(simd_float3(Float(tokens[1])! * (flipX ? -1 : 1), Float(tokens[2])! * (flipY ? -1 : 1), Float(tokens[3])! * (flipZ ? -1 : 1)))
                }
            case "vt":
                if tokens.count >= 3 {
                    rawUVs.append(simd_float2(Float(tokens[1])!, Float(tokens[2])!))
                }
            case "vn":
                if tokens.count >= 4 {
                    rawNormals.append(simd_float3(Float(tokens[1])! * (flipX ? -1 : 1), Float(tokens[2])! * (flipY ? -1 : 1), Float(tokens[3])! * (flipZ ? -1 : 1)))
                }
            case "f":
                let faceTokens = Array(tokens.dropFirst())
                guard faceTokens.count >= 3 else { continue }

                var faceIndices: [UInt32] = []
                
                // TODO: change the normal
                let p0 = rawPositions[max(0, resolveIndex(faceTokens[0].components(separatedBy: "/")[0], count: rawPositions.count))]
                let p1 = rawPositions[max(0, resolveIndex(faceTokens[1].components(separatedBy: "/")[0], count: rawPositions.count))]
                let p2 = rawPositions[max(0, resolveIndex(faceTokens[2].components(separatedBy: "/")[0], count: rawPositions.count))]
                let geoNormal = simd_length_squared(simd_cross(p1 - p0, p2 - p0)) > 0 ? simd_normalize(simd_cross(p1 - p0, p2 - p0)) : simd_float3(0, 1, 0)

                for token in faceTokens {
                    let parts = token.components(separatedBy: "/")
                    let pStr = parts.count > 0 ? parts[0] : ""
                    let uStr = parts.count > 1 ? parts[1] : ""
                    let nStr = parts.count > 2 ? parts[2] : ""

                    let vIdx = getOrAddVertex(pStr: pStr, uStr: uStr, nStr: nStr, fallbackNormal: geoNormal)
                    faceIndices.append(vIdx)
                }

                // Triangulate Fan (Supports Triangles, Quads, and N-Gons safely)
                let subMeshIdx = Int32(subMeshes.count)
                for i in 1..<(faceIndices.count - 1) {
                    let idx0 = faceIndices[0]
                    let idx1 = importCCWFaces ? faceIndices[i] : faceIndices[i + 1]
                    let idx2 = importCCWFaces ? faceIndices[i + 1] : faceIndices[i]

                    faces.append(Face(
                        vertexIndex0: idx0, 
                        vertexIndex1: idx1, 
                        vertexIndex2: idx2,
                        subMeshIndex: subMeshIdx
                    ))
                }

            case "o", "g":
                flushMesh()
                if tokens.count > 1 { currentMeshName = tokens[1] }

            case "usemtl":
                if tokens.count > 1 {
                    flushSubMesh()
                    let matName = tokens[1]
                    currentMaterialIndex = materialNameToIndex[matName] ?? -1
                    if currentMaterialIndex == -1 {
                        print("Warning: Material '\(matName)' not found in material library!")
                    }
                }

            case "mtllib":
                if tokens.count > 1 {
                    let mtlPath = objURL.deletingLastPathComponent().appendingPathComponent(tokens[1]).path
                    let (newMats, newNameIndices) = materialImporter.importMaterial(filePath: mtlPath)
                    
                    let matOffset = Int32(materials.count)
                    for (name, index) in newNameIndices {
                        materialNameToIndex[name] = index + matOffset
                    }
                    materials.append(contentsOf: newMats)
                }

            default:
                break
            }
        }

        flushMesh()

        if importAtOrigin && !rawPositions.isEmpty {
            var sum = simd_float3(0, 0, 0)
            for pos in rawPositions { sum += pos }
            let center = (sum / Float(rawPositions.count)) + importOffset

            for i in 0..<vertices.count {
                vertices[i].position -= center
            }
            for i in 0..<meshes.count {
                meshes[i].pivot -= center
                meshes[i].localMinBounds -= center
                meshes[i].localMaxBounds -= center
            }
        }

        return ObjectAsset(
            vertices: vertices,
            faces: faces,
            materials: materials,
            textures: materialImporter.getTextures(),
            subMeshes: subMeshes,
            meshes: meshes
        )
    }
}