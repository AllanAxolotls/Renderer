import Foundation
import simd

enum ModelResourceLoadOption {
    case flipXAxis
    case flipYAxis
    case flipZAxis
    case recomputeNormals
    case clockwiseWinding
    case counterClockwiseWinding
    case centeredAtOrigin
}

/// A Resource for Wavefront .obj files
final class MeshLibraryResource : Resource, @unchecked Sendable {
    unowned let resourceManager: ResourceManager
    var loadOptions: [ModelResourceLoadOption] = [.flipZAxis]

    var meshes: [Mesh] = []

    /// New Mesh Resources from this .obj file
    var ownedMeshResources             : [MeshResource]                            = []
    /// New Mesh Resources
    var ownedMeshResourceHandles       : [ResourceHandle<MeshResource>]            = []
    /// Reused Mesh Resources
    var unownedMeshResourceHandles     : [ResourceHandle<MeshResource>]            = []
    /// Used Material Library Resources
    var materialLibraryResourceHandles : [ResourceHandle<MaterialLibraryResource>] = []

    /// New + Reused Mesh Resources
    var usedMeshResourceHandles        : [ResourceHandle<MeshResource>] { 
        ownedMeshResourceHandles + unownedMeshResourceHandles 
    }

    // < Temporaries > //
    var fetchedPositions : [simd_float3] = []
    var fetchedNormals   : [simd_float3] = []
    var fetchedUVs       : [simd_float2] = []
    private struct VertexKey : Hashable { let pIndex, nIndex, uIndex: Int }
    private var vertexCache: [VertexKey : UInt32] = [:]

    // Per MeshResource Reset
    private var currentMeshResourceDescription: MeshResourceDescription = MeshResourceDescription()
    private var currentMeshBaseName : String = "Unnamed Mesh"
    private var currentMaterialResourceHandle: ResourceHandle<MaterialResource>
    private var currentMeshMaterialCount: Int = 0


    init(from resourceManager: ResourceManager, name: String = "Unnamed MeshLibraryResource", assetURL: URL? = nil) {
        self.resourceManager = resourceManager
        currentMaterialResourceHandle = resourceManager.defaultMaterial.materialResourceHandle
        super.init(name: name, assetURL: assetURL)
    }


    private func flushPendingMeshResource() {
        defer {
            currentMeshResourceDescription = MeshResourceDescription(name: name)
            currentMeshBaseName = "Unnamed Mesh"
            currentMaterialResourceHandle = resourceManager.defaultMaterial.materialResourceHandle

            // Mandatory, otherwise the vertices and indices aren't contigous per Mesh
            vertexCache.removeAll() 
        }

        // Empty Meshes should not get saved, like the Default MeshResource
        guard currentMeshResourceDescription.vertices.count > 0 else { return }
       
        let meshResourceHandle: ResourceHandle<MeshResource>
        let transform: simd_float4x4
        if let (equivalentMeshResource, foundTransform) = resourceManager.getEquivalentMeshResource(with: currentMeshResourceDescription) {
            meshResourceHandle = ResourceHandle(equivalentMeshResource)
            unownedMeshResourceHandles.append(meshResourceHandle)
            transform = foundTransform

        } else {
            let meshResource = MeshResource(name: currentMeshResourceDescription.name, assetURL: assetURL)
            meshResource.vertexHandle = resourceManager.vertexAllocator.allocAndInit(count: currentMeshResourceDescription.vertices.count, pointer: &currentMeshResourceDescription.vertices)
            meshResource.indexHandle  = resourceManager.indexAllocator .allocAndInit(count: currentMeshResourceDescription.indices.count,  pointer: &currentMeshResourceDescription.indices )
            meshResourceHandle = ResourceHandle(meshResource)
            ownedMeshResources.append(meshResource)
            ownedMeshResourceHandles.append(meshResourceHandle)
            resourceManager.cachedMeshResources.append(meshResource)
            transform = matrix_identity_float4x4
        }

        // The handle gets saved in both so that either the Mesh can live separately from the Library
        // OR the library can still fully exist without the mesh
        meshes.append(Mesh(
            meshResourceHandle: meshResourceHandle, 
            material: Material(materialResourceHandle: currentMaterialResourceHandle),
            transform: transform
        ))
    }

    private func resolveIndex(_ rawStr: String, count: Int) -> Int {
        guard let idx = Int(rawStr), idx != 0 else { return -1 }
        return idx > 0 ? idx - 1 : count + idx
    }

    private func getOrAddVertex(pStr: String, uStr: String, nStr: String, fallbackNormal: simd_float3) -> UInt32 {
        let pIdx = resolveIndex(pStr, count: fetchedPositions.count)
        let uIdx = resolveIndex(uStr, count: fetchedUVs.count)
        let nIdx = resolveIndex(nStr, count: fetchedNormals.count)

        let key = VertexKey(pIndex: pIdx, nIndex: nIdx, uIndex: uIdx)
        if let existingIndex = vertexCache[key] {
            return existingIndex
        }

        let pos = (pIdx >= 0 && pIdx < fetchedPositions.count) ? fetchedPositions[pIdx] : simd_float3(0, 0, 0)
        let uv = (uIdx >= 0 && uIdx < fetchedUVs.count) ? fetchedUVs[uIdx] : simd_float2(0, 0)
        let norm = loadOptions.contains(.recomputeNormals)
            ? fallbackNormal
            : ((nIdx >= 0 && nIdx < fetchedNormals.count) ? fetchedNormals[nIdx] : fallbackNormal)

        let newVertex = Vertex(position: pos, normal: norm, uv: uv)
        let newIndex = UInt32(currentMeshResourceDescription.vertices.count)
        currentMeshResourceDescription.vertices.append(newVertex)
        vertexCache[key] = newIndex
        return newIndex
    }
    
    override func performLoad() throws {
        defer {
            fetchedPositions.removeAll()
            fetchedNormals.removeAll()
            fetchedUVs.removeAll()
        }

        guard let assetURL = assetURL else { throw NSError(domain: "MeshLibraryResource", code: 1, userInfo: [NSLocalizedDescriptionKey: "performLoad() failed, assetURL must not be nil"]) }

        // Open the File if it exists
        let contents = try! String(contentsOf: assetURL, encoding: .utf8)

        let lines = contents.components(separatedBy: .newlines)

        for line in lines {
            let cleanLine = line.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanLine.isEmpty || cleanLine.hasPrefix("#") { continue }

            let tokens = cleanLine.components(separatedBy: .whitespaces).filter{ !$0.isEmpty }
            guard let command = tokens.first else { continue }

            switch command {
            case "v":
                guard tokens.count >= 4 else { continue }
                fetchedPositions.append(simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!) * simd_float3(
                    loadOptions.contains(.flipXAxis) ? -1 : 1,
                    loadOptions.contains(.flipYAxis) ? -1 : 1,
                    loadOptions.contains(.flipZAxis) ? -1 : 1
                ))

            case "vn":
                guard tokens.count >= 4 else { continue }
                fetchedNormals.append(simd_float3(Float(tokens[1])!, Float(tokens[2])!, Float(tokens[3])!) * simd_float3(
                    loadOptions.contains(.flipXAxis) ? -1 : 1,
                    loadOptions.contains(.flipYAxis) ? -1 : 1,
                    loadOptions.contains(.flipZAxis) ? -1 : 1
                ))

            
            case "vt":
                guard tokens.count >= 3 else { continue }
                fetchedUVs.append(simd_float2(Float(tokens[1])!, Float(tokens[2])!))
                
            case "f":
                let faceTokens = Array(tokens.dropFirst())
                guard faceTokens.count >= 3 else { continue }

                var faceIndices: [UInt32] = []
                let p0 = fetchedPositions[max(0, resolveIndex(faceTokens[0].components(separatedBy: "/")[0], count: fetchedPositions.count))]
                let p1 = fetchedPositions[max(0, resolveIndex(faceTokens[1].components(separatedBy: "/")[0], count: fetchedPositions.count))]
                let p2 = fetchedPositions[max(0, resolveIndex(faceTokens[2].components(separatedBy: "/")[0], count: fetchedPositions.count))]
                let geoNormal = simd_length_squared(simd_cross(p1 - p0, p2 - p0)) > 0 ? simd_normalize(simd_cross(p1 - p0, p2 - p0)) : simd_float3(0, 1, 0)

                for token in faceTokens {
                    let parts = token.components(separatedBy: "/")
                    let pStr = parts.count > 0 ? parts[0] : ""
                    let uStr = parts.count > 1 ? parts[1] : ""
                    let nStr = parts.count > 2 ? parts[2] : ""

                    let vertexIndex = getOrAddVertex(pStr: pStr, uStr: uStr, nStr: nStr, fallbackNormal: geoNormal)

                    faceIndices.append(vertexIndex)
                }

                // Triangulate Fan (Supports Triangles, Quads, and N-Gons)
                let importCCW = loadOptions.contains(.counterClockwiseWinding)
                for i in 1..<(faceIndices.count - 1) {
                    currentMeshResourceDescription.indices.append(faceIndices[0])
                    currentMeshResourceDescription.indices.append(importCCW ? faceIndices[i] : faceIndices[i + 1])
                    currentMeshResourceDescription.indices.append(importCCW ? faceIndices[i + 1] : faceIndices[i])
                }

            case "o", "g":
                flushPendingMeshResource()
                guard tokens.count > 1 else { continue }
                currentMeshBaseName = tokens[1]
                currentMeshResourceDescription.name = tokens[1]
                currentMeshMaterialCount = 0

            case "usemtl":
                let mtlName = tokens.count > 1 ? tokens[1] : "DefaultMaterial"
                currentMeshMaterialCount += 1
                if currentMeshMaterialCount > 1 {
                    currentMeshResourceDescription.name = currentMeshBaseName + "_\(currentMaterialResourceHandle.resource.name)"
                    flushPendingMeshResource()
                    currentMeshResourceDescription.name = currentMeshBaseName + "_\(mtlName)"
                }

                var foundMaterialResourceHandle: ResourceHandle<MaterialResource>? = nil

                for materialLibraryResourceHandle in materialLibraryResourceHandles.reversed() {
                    let materialLibraryResource = materialLibraryResourceHandle.resource
                    if let materialResourceHandle = materialLibraryResource.getMaterialResourceHandleByName(mtlName) {
                        foundMaterialResourceHandle = materialResourceHandle
                        break 
                    }
                }

                currentMaterialResourceHandle = foundMaterialResourceHandle ?? resourceManager.defaultMaterial.materialResourceHandle

            case "mtllib":
                guard tokens.count > 1 else { continue }
                let materialURL = assetURL.deletingLastPathComponent().appendingPathComponent(tokens[1])
                materialLibraryResourceHandles.append(try resourceManager.loadMaterialLibraryResource(url: materialURL))

            default:
                continue
            }

        }

        flushPendingMeshResource()
        
        if loadOptions.contains(.centeredAtOrigin) {
            var vertexSum = simd_float3(0, 0, 0)
            var vertexCount: Int = 0
            for mesh in meshes {
                mesh.meshResource.vertexHandle?.withUnsafeBufferPointer { buffer in
                    for vertex in buffer { 
                        vertexSum += vertex.position 
                        vertexCount += 1
                    }
                }
            }
            
            let center = vertexSum / Float(vertexCount)
            for mesh in meshes { mesh.position -= center }
        }
    }

    override func unload() {
        meshes.removeAll()
        ownedMeshResources.removeAll()
        unownedMeshResourceHandles.removeAll()
        ownedMeshResourceHandles.removeAll()
        materialLibraryResourceHandles.removeAll()
    }

    func getMeshByName(_ name: String) -> Mesh? {
        return meshes.first(where: { $0.name == name })
    }

    func getMeshResourceHandleByName(_ name: String) -> ResourceHandle<MeshResource>? {
        return usedMeshResourceHandles.first(where: { $0.resource.name == name })
    }

    func asModel() -> Model {
        let model = Model(name: self.name)
        model.addChildren(meshes)
        return model
    }
}