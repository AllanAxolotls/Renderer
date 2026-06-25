import Metal

public class Scene: @unchecked Sendable {
    var vertices: [Vertex] = []
    var faces: [Face] = []
    var materials: [Material] = []
    var textures: [MTLTexture] = []
    var subMeshes: [SubMesh] = []
    var meshes: [Mesh] = []
    var sphereLights: [SphereLight] = []

    var camera: Camera = Camera()
    var tlas: TLAS?
    var tlasReformed: Bool = false

    init() {
        materials.append(Material()) // Default Material
    }

    public func buildAccelerationStructures() {
        self.tlas = TLAS(scene: self)
    }

    // TODO: in the future instead of straight up calling reform, queue it so one reform for a bunch of meshes instead
    public func meshModelMatrixChangedBinding(mesh: Mesh) {
        self.tlas?.reform()
        //self.tlas?.build()
        tlasReformed = true // To notify the RayTracer
        
    }

    public func addAsset(_ asset: ObjectAsset) {
        var (newVertices, newFaces, newMaterials, newTextures, newSubMeshes, newMeshes) = (asset.vertices, asset.faces, asset.materials, asset.textures, asset.subMeshes, asset.meshes)
        for i in 0..<newSubMeshes.count {
            newSubMeshes[i].vertexOffset += Int32(truncatingIfNeeded: self.vertices.count)
            newSubMeshes[i].faceOffset += Int32(truncatingIfNeeded: self.faces.count)
            newSubMeshes[i].meshIndex += Int32(truncatingIfNeeded: self.meshes.count)
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
            newMeshes[i].faceOffset += Int32(truncatingIfNeeded: self.faces.count)
            newMeshes[i].vertexOffset += Int32(truncatingIfNeeded: self.vertices.count)
        }
        for i in 0..<newMaterials.count {
            newMaterials[i].diffuseTextureIndex += Int32(truncatingIfNeeded: self.textures.count)
        }

        self.vertices.append(contentsOf: newVertices)
        self.faces.append(contentsOf: newFaces)
        self.materials.append(contentsOf: newMaterials)
        self.textures.append(contentsOf: newTextures)
        self.subMeshes.append(contentsOf: newSubMeshes)
        self.meshes.append(contentsOf: newMeshes)

        for mesh in newMeshes { mesh.modelMatrixChangedBinding = meshModelMatrixChangedBinding }
    }
}