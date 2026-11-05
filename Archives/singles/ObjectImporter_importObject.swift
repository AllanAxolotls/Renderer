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
            if currentSubMeshFaceCount == 0 { return }
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

            let mesh = Mesh(
                name: currentMeshName ?? "Mesh", pivot: (minBounds + maxBounds) * 0.5, 
                subMeshOffset: currentSubMeshOffset, subMeshCount: currentSubMeshCount,
                faceOffset: currentMeshFaceOffset, faceCount: currentMeshFaceCount,
                vertexOffset: currentMeshVertexOffset, vertexCount: currentMeshVertexCount,
                localMinBounds: minBounds, localMaxBounds: maxBounds
            )
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

                // TODO: add safe guards when indices are out of bounds
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
                        vertexIndices: simd_uint3(baseIndex, baseIndex + (importCCWFaces ? 1 : 2), baseIndex + (importCCWFaces ? 2 : 1)), 
                        subMeshIndex: currentSubMeshOffset + currentSubMeshCount
                    ))
                    currentSubMeshFaceCount += 1
                    currentMeshFaceCount += 1
                }

                func newQuad() {
                    faces.append(Face(
                        vertexIndices: simd_uint3(baseIndex, baseIndex + (importCCWFaces ? 1 : 2), baseIndex + (importCCWFaces ? 2 : 1)), 
                        subMeshIndex: currentSubMeshOffset + currentSubMeshCount
                    ))
                    faces.append(Face(
                        vertexIndices: simd_uint3(baseIndex, baseIndex + (importCCWFaces ? 2 : 3), baseIndex + (importCCWFaces ? 3 : 2)), 
                        subMeshIndex: currentSubMeshOffset + currentSubMeshCount
                    ))
                    currentSubMeshFaceCount += 2
                    currentMeshFaceCount += 2
                }
                
                if vertexAttributes4 == nil { newTriangle() } else { newQuad() }
            case "o": 
                pushSubMesh()
                pushMesh()
            case "g":
                pushSubMesh()
                pushMesh()
                currentMeshName = tokens[1]
            case "usemtl":
                pushSubMesh()
                currentMaterialIndex = materialNameIndices[tokens[1]]
                if currentMaterialIndex == nil {
                    print("Material \(tokens[1]) was not found!")
                }
                
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

        // Centering and offseting
        var vertexSum = simd_float3(0, 0, 0)
        if importAtOrigin {
            for vertexPosition in vertexPositions { vertexSum += vertexPosition }
        }
        let vertexAverage = vertexSum / Float(vertexPositions.count) + importOffset
        for i in 0..<vertices.count { vertices[i].position -= vertexAverage }
        for i in 0..<meshes.count { 
            meshes[i].pivot -= vertexAverage 
            meshes[i].localMinBounds -= vertexAverage
            meshes[i].localMaxBounds -= vertexAverage
        }

        return ObjectAsset(vertices: vertices, faces: faces, materials: materials, textures: materialImporter.getTextures(), subMeshes: subMeshes, meshes: meshes)
    }