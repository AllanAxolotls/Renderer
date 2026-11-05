import Metal
import MetalKit
import Foundation

/*
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

    private var colorTextureCache: [simd_float4: MTLTexture] = [:]
    private var colorIndexCache: [simd_float4: Int16] = [:]

    init() {
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

    // TODO: add png support for greyscale and other weird png formats
    private func loadTexture(filePath: String) -> MTLTexture? {
        guard let mtkTextureLoader = mtkTextureLoader else {
            print("MTKTextureLoader is not initialized, cannot load texture \(filePath)")
            return nil
        }
        if let fixedPath = resolveFilePath(filePath: filePath) {
            let textureURL = URL(fileURLWithPath: fixedPath)
            let options: [MTKTextureLoader.Option: Any] = [
                .origin: MTKTextureLoader.Origin.bottomLeft, // important for OBJ UVs
                .SRGB: true,
            ]
            
            do {
                let texture = try mtkTextureLoader.newTexture(URL: textureURL, options: options)
                return texture
            } catch {
                print("An error occured while trying to load texture \(fixedPath): \n\(error.localizedDescription)")
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
}*/

// TODO: Add material merging if names are the same
public class MaterialImporter {
    public func importMaterial(filePath: String) -> (materials: [Material], materialDatas: [MaterialData], materialNameIndices: [String : UInt32]) {
        var materials: [Material] = []
        var materialDatas: [MaterialData] = []
        var materialNameIndices: [String : UInt32] = [:]

        guard let resolvedFilePath = resolveFilePath(filePath: filePath) else {
            print("Failed loading file: \(filePath), not found in directory!")
            return (materials: materials, materialDatas: materialDatas, materialNameIndices: materialNameIndices)
        }

        var materialIndex: UInt32 = 0
        var currentMaterial = Material()
        var currentMaterialData = MaterialData()

        func pushMaterial() {
            materials.append(currentMaterial)
            materialDatas.append(currentMaterialData)
            currentMaterial = Material()
            currentMaterialData = MaterialData()
        }

        guard let contents = try? String(contentsOfFile: resolvedFilePath, encoding: .utf8) else {
            print("Material file \(filePath) could not be found in directory!")
            return (materials: materials, materialDatas: materialDatas, materialNameIndices: materialNameIndices)
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
            case "Kd": 
                currentMaterialData.diffuseColor.x = Float(tokens[1])!
                currentMaterialData.diffuseColor.y = Float(tokens[2])!
                currentMaterialData.diffuseColor.z = Float(tokens[3])!
            //case "Ks": currentMaterial.specularColor = simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!)
            case "Ke": 
                currentMaterialData.emissionColor.x = Float(tokens[1])!
                currentMaterialData.emissionColor.y = Float(tokens[2])!
                currentMaterialData.emissionColor.z = Float(tokens[3])!
            case "map_Kd": currentMaterial.diffuseTexturePath = mtlDirURL.appendingPathComponent(tokens[1])
            case "map_d": currentMaterial.dissolveTexturePath = mtlDirURL.appendingPathComponent(tokens[1])
            //case "illum": currentMaterial.illuminationModel = Int16(tokens[1])!
            case "d": currentMaterialData.diffuseColor.w = Float(tokens[1])!
            case "Tr": currentMaterialData.diffuseColor.w = 1.0 - Float(tokens[1])!
            case "Ns": currentMaterialData.params.x = 1.0 // TODO: add this back: 1 - pow(2 / (Float(tokens[1])! + 2), 1/4)
            case "Pr": currentMaterialData.params.x = Float(tokens[1])!
            case "Pm": currentMaterialData.params.y = Float(tokens[1])!
            //case "Ni": currentMaterial.refractiveIndex = Float(tokens[1])!
            // case "sharpness":
            // case "Tf":
            // case "refl":
            // case "disp":
            // case "decal":
            case "newmtl":
                if materialIndex != 0 { pushMaterial() }
                currentMaterial.name = tokens[1]
                currentMaterial.materialDataIndex = materialIndex
                materialNameIndices[tokens[1]] = materialIndex
                materialIndex += 1
                //print("\(tokens[1]) : \(materialIndex)")
            default: continue parseLine
            }
        }
        // Finalise
        pushMaterial()

        return (materials: materials, materialDatas: materialDatas, materialNameIndices: materialNameIndices)
    }
}

public class ObjectImporter {
    public var materialImporter = MaterialImporter()
    public var importOffset: simd_float3 = simd_float3(0, 0, 0)
    public var importAtOrigin: Bool = false
    public var importCCWFaces: Bool = false
    public var recomputeNormals: Bool = false
    public var flipX: Bool = false
    public var flipY: Bool = false
    public var flipZ: Bool = true

    func importObject(filePath: String, vertices: inout [Vertex], indices: inout [UInt32], materials: inout [Material], materialDatas: inout [MaterialData], meshes: inout [Mesh]) {
        guard let resolvedPath = resolveFilePath(filePath: filePath),
            let contents = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            print("Failed to open OBJ file: \(filePath)")
            return
        }

        let objURL = URL(fileURLWithPath: resolvedPath)

        var rawPositions: [simd_float3] = []
        var rawNormals: [simd_float3] = []
        var rawUVs: [simd_float2] = []

        var materialNameToIndex: [String: UInt32] = [:]
        
        // Vertex Deduplication Hash Map: [VertexKey : Final Buffer Index]
        struct VertexKey: Hashable {
            let pIndex: Int
            let uIndex: Int
            let nIndex: Int
        }
        var vertexCache: [VertexKey: UInt32] = [:]

        var currentMeshName = "Mesh"
        var currentMaterialIndex: UInt32 = UInt32(materials.count)

        var currentMeshSubMeshes: [SubMesh] = []
        var currentSubMeshVertexOffset: UInt32 = UInt32(vertices.count)
        var currentSubMeshIndexOffset: UInt32 = UInt32(indices.count)

        func flushSubMesh() {
            let vertexCount = UInt32(vertices.count) - currentSubMeshVertexOffset
            let indexCount = UInt32(indices.count) - currentSubMeshIndexOffset
            guard indexCount > 0 else { return }

            let subMesh = SubMesh(
                //vertexCount: vertexCount,
                indexOffset: currentSubMeshIndexOffset,
                indexCount: indexCount,
                vertexOffset: currentSubMeshVertexOffset,
                vertexCount: vertexCount,
                materialIndex: currentMaterialIndex,
                meshIndex: UInt32(meshes.count) // TODO: double check if it's always valid
            )
            currentMeshSubMeshes.append(subMesh)

            currentSubMeshVertexOffset = UInt32(vertices.count)
            currentSubMeshIndexOffset = UInt32(indices.count)
        }

        func flushMesh() {
            flushSubMesh()
            guard currentMeshSubMeshes.count > 0 else { return }

            var minBounds = simd_float3(repeating: .greatestFiniteMagnitude)
            var maxBounds = simd_float3(repeating: -.greatestFiniteMagnitude)

            // Drawcalls are contagious in memory so this is possible:
            let firstSubMesh = currentMeshSubMeshes.first!
            let lastSubMesh = currentMeshSubMeshes.last!

            for i in Int(firstSubMesh.vertexOffset) ..< Int(lastSubMesh.vertexOffset + lastSubMesh.vertexCount) {
                minBounds = simd.min(minBounds, vertices[i].position)
                maxBounds = simd.max(maxBounds, vertices[i].position)
            }

            let mesh = Mesh(
                name: currentMeshName,
                subMeshes: currentMeshSubMeshes,
                pivot: (minBounds + maxBounds) * 0.5,

                localMinBounds: minBounds,
                localMaxBounds: maxBounds
            )
            meshes.append(mesh)
            currentMeshSubMeshes = []
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
            let norm = recomputeNormals 
                ? fallbackNormal
                : ((nIdx >= 0 && nIdx < rawNormals.count) ? rawNormals[nIdx] : fallbackNormal)

            let newVertex = Vertex(position: pos, normal: norm, uv: uv)
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
                
                let p0 = rawPositions[max(0, resolveIndex(faceTokens[0].components(separatedBy: "/")[0], count: rawPositions.count))]
                let p1 = rawPositions[max(0, resolveIndex(faceTokens[1].components(separatedBy: "/")[0], count: rawPositions.count))]
                let p2 = rawPositions[max(0, resolveIndex(faceTokens[2].components(separatedBy: "/")[0], count: rawPositions.count))]
                let geoNormal = simd_length_squared(simd_cross(p1 - p0, p2 - p0)) > 0 ? simd_normalize(simd_cross(p1 - p0, p2 - p0)) : simd_float3(0, 1, 0)

                for token in faceTokens {
                    let parts = token.components(separatedBy: "/")
                    let pStr = parts.count > 0 ? parts[0] : ""
                    let uStr = parts.count > 1 ? parts[1] : ""
                    let nStr = parts.count > 2 ? parts[2] : ""

                    let vertexIndex = getOrAddVertex(pStr: pStr, uStr: uStr, nStr: nStr, fallbackNormal: geoNormal)

                    faceIndices.append(vertexIndex)
                }

                // Triangulate Fan (Supports Triangles, Quads, and N-Gons safely)
                for i in 1..<(faceIndices.count - 1) {
                    indices.append(faceIndices[0])
                    indices.append(importCCWFaces ? faceIndices[i] : faceIndices[i + 1])
                    indices.append(importCCWFaces ? faceIndices[i + 1] : faceIndices[i])
                }

            case "o", "g":
                flushMesh()
                if tokens.count > 1 { currentMeshName = tokens[1] }

            case "usemtl":
                if tokens.count > 1 {
                    flushSubMesh()
                    let matName = tokens[1]
                    if let materialIndex = materialNameToIndex[matName] {
                        currentMaterialIndex = materialIndex
                    } else {
                        currentMaterialIndex = 0
                        print("Warning: Material '\(matName)' not found in material library!")
                    }
                }

            case "mtllib":
                if tokens.count > 1 {
                    let mtlPath = objURL.deletingLastPathComponent().appendingPathComponent(tokens[1]).path
                    let (newMaterials, newMaterialDatas, newNameIndices) = materialImporter.importMaterial(filePath: mtlPath)
                    
                    let matOffset = UInt32(materials.count)
                    for (name, index) in newNameIndices {
                        materialNameToIndex[name] = index + matOffset
                    }
                    materials.append(contentsOf: newMaterials)
                    materialDatas.append(contentsOf: newMaterialDatas)
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

            for i in 0..<meshes.count {
                meshes[i].pivot -= center
                meshes[i].position -= center
                meshes[i].localMinBounds -= center
                meshes[i].localMaxBounds -= center
            }
        }
    }
}