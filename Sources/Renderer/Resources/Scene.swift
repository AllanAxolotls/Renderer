import Metal

public class Scene: @unchecked Sendable {
    var vertices: [Vertex] = []
    var faces: [Face] = []
    var materials: [Material] = []
    var textures: [MTLTexture] = []
    var subMeshes: [SubMesh] = []
    var meshes: [Mesh] = []

    var camera: Camera = Camera()
    var bvh: BVH?

    public let importer: ObjectImporter

    init(device: MTLDevice) {
        importer = ObjectImporter(device: device)
        materials.append(Material()) // Default Material
        //importObject(fileName: "RobloxWorld2.obj")
        //importObject(fileName: "FriedChicken.obj")
        //importObject(fileName: "Heart.obj")
        importObject(fileName: "SkyPavMap.obj")
    }

    public func initBVH() {
        self.bvh = BVH(scene: self)
        if let bvh = self.bvh {
            bvh.build()
        }
    }

    public func importObject(fileName: String) {
        var (newVertices, newFaces, newMaterials, newTextures, newSubMeshes, newMeshes) = importer.importObject(fileName: fileName)

        for i in 0..<newSubMeshes.count {
            newSubMeshes[i].vertexOffset += Int32(truncatingIfNeeded: self.vertices.count)
            newSubMeshes[i].faceOffset += Int32(truncatingIfNeeded: self.faces.count)
            if newSubMeshes[i].materialIndex == -1 {
                newSubMeshes[i].materialIndex = 0
            } else {
                newSubMeshes[i].materialIndex += Int32(truncatingIfNeeded: self.materials.count)
            }
        }
        for i in 0..<newFaces.count {
            let count = UInt32(truncatingIfNeeded: self.vertices.count)
            newFaces[i].vertexIndices.x += count
            newFaces[i].vertexIndices.y += count
            newFaces[i].vertexIndices.z += count
            newFaces[i].subMeshIndex += Int32(truncatingIfNeeded: self.subMeshes.count)
        }
        for i in 0..<newMeshes.count {
            newMeshes[i].subMeshOffset += Int32(truncatingIfNeeded: self.subMeshes.count)
        }
        for i in 0..<newMaterials.count {
            newMaterials[i].ambientTextureIndex += Int32(truncatingIfNeeded: self.textures.count)
        }

        self.vertices.append(contentsOf: newVertices)
        self.faces.append(contentsOf: newFaces)
        self.materials.append(contentsOf: newMaterials)
        self.textures.append(contentsOf: newTextures)
        self.subMeshes.append(contentsOf: newSubMeshes)
        self.meshes.append(contentsOf: newMeshes)
    }
}