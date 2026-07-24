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

    private var hasDefaultTextures: Bool = false

    init() {
        var defaultMaterial = Material()
        defaultMaterial.diffuseTextureIndex = 0
        defaultMaterial.dissolveTextureIndex = 1
        materials.append(defaultMaterial) 
    }

    public func addDefaultTextures(diffuseTexture: MTLTexture, dissolveTexture: MTLTexture) {
        textures.insert(diffuseTexture, at: 0)
        textures.insert(dissolveTexture, at: 1)
        hasDefaultTextures = true
    }

    public func buildAccelerationStructures() {
        self.tlas = TLAS(scene: self)
    }

    // TODO: in the future instead of straight up calling reform, queue it so one reform for a bunch of meshes instead
    public func meshModelMatrixChangedBinding(mesh: Mesh) {
        self.tlas?.reform()
        //self.tlas?.build() // Instead of reforming, completely rebuilds (costly)
        tlasReformed = true // To notify the RayTracer and Rasterizer
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
            if (newMaterials[i].diffuseTextureIndex == -1) {
                if !hasDefaultTextures { 
                    print("!!! you must do scene.addDefaultTexture(...) before adding assets !!!") 
                }
                newMaterials[i].diffuseTextureIndex = 0
            } else {
                newMaterials[i].diffuseTextureIndex += Int16(self.textures.count) - 2 // subtract 2 to ignore the default textures
            }

            if (newMaterials[i].dissolveTextureIndex == -1) {
                if !hasDefaultTextures { 
                    print("!!! you must do scene.addDefaultTexture(...) before adding assets !!!") 
                }
                newMaterials[i].dissolveTextureIndex = 1
            } else {
                newMaterials[i].dissolveTextureIndex += Int16(self.textures.count) - 2 // subtract 2 to ignore the default textures
            }
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