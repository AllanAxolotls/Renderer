import Metal
import Combine

// TODO: make it queue the subscriptions and merge them instead, by making a begin and end command or something

public class Scene: @unchecked Sendable {
    // TODO: add a Changed subject that fires when added or removed
    private(set) var vertices: [Vertex] = []
    public let verticesAdded = PassthroughSubject<Void, Never>()
    public let verticesRemoved = PassthroughSubject<Void, Never>()

    private(set) var faces: [Face] = []
    public let facesAdded = PassthroughSubject<Void, Never>()
    public let facesRemoved = PassthroughSubject<Void, Never>()

    private(set) var materials: [Material] = []
    public let materialsAdded = PassthroughSubject<Void, Never>()
    public let materialsRemoved = PassthroughSubject<Void, Never>()

    private(set) var textures: [MTLTexture] = []
    public let texturesAdded = PassthroughSubject<Void, Never>()
    public let texturesRemoved = PassthroughSubject<Void, Never>()

    private(set) var subMeshes: [SubMesh] = []
    public let subMeshesAdded = PassthroughSubject<Void, Never>()
    public let subMeshesRemoved = PassthroughSubject<Void, Never>()
    
    private(set) var meshes: [Mesh] = []
    public let meshesAdded = PassthroughSubject<Void, Never>()
    public let meshesRemoved = PassthroughSubject<Void, Never>()

    public var camera: Camera = Camera()
    private(set) var tlas: TLAS?
    public let tlasReformed = PassthroughSubject<Void, Never>()
    public let tlasRebuilt = PassthroughSubject<Void, Never>()

    private var hasDefaultTextures: Bool = false

    init() {
        var defaultMaterial = Material()
        defaultMaterial.diffuseTextureIndex = 0
        materials.append(defaultMaterial) 
    }


    public func addVertices(_ newVertices: [Vertex]) {
        self.vertices.append(contentsOf: newVertices)
        self.verticesAdded.send()
    }
    public func addFaces(_ newFaces: [Face]) {
        self.faces.append(contentsOf: newFaces)
        self.facesAdded.send()
    }
    public func addMaterials(_ newMaterials: [Material]) {
        self.materials.append(contentsOf: newMaterials)
        self.materialsAdded.send()
    }
    public func addTextures(_ newTextures: [MTLTexture]) {
        self.textures.append(contentsOf: newTextures)
        self.texturesAdded.send()
    }
    public func addSubMeshes(_ newSubMeshes: [SubMesh]) {
        self.subMeshes.append(contentsOf: newSubMeshes)
        self.subMeshesAdded.send()
    }
    public func addMeshes(_ newMeshes: [Mesh]) {
        self.meshes.append(contentsOf: newMeshes)
        self.meshesAdded.send()
    }



    public func addDefaultTextures(diffuseTexture: MTLTexture) {
        self.textures.insert(diffuseTexture, at: 0)
        self.texturesAdded.send()
        hasDefaultTextures = true
    }

    public func buildAccelerationStructures() {
        self.tlas = TLAS(scene: self)
    }

    public func rebuildTLAS() {
        //self.tlas = TLAS(scene: self)
        //self.tlas?.reform()
        self.tlas?.build() // Instead of reforming, completely rebuilds (costly)
        tlasRebuilt.send()  // To notify the RayTracer and Rasterizer
    }

    // TODO: in the future instead of straight up calling reform, queue it so one reform for a bunch of meshes instead
    public func meshModelMatrixChangedBinding(mesh: Mesh) {
        self.tlas?.reform()
        tlasReformed.send()
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
                // TODO: look at ObjectImporter.swift for index, somethings is off
                newSubMeshes[i].materialIndex += Int32(truncatingIfNeeded: self.materials.count)
            }
        }
        for i in 0..<newFaces.count {
            let count = UInt32(truncatingIfNeeded: self.vertices.count)
            newFaces[i].vertexIndex0 += count
            newFaces[i].vertexIndex1 += count
            newFaces[i].vertexIndex2 += count
            newFaces[i].subMeshIndex += Int32(truncatingIfNeeded: self.subMeshes.count)
        }
        for i in 0..<newMeshes.count {
            newMeshes[i].subMeshOffset += Int32(truncatingIfNeeded: self.subMeshes.count)
            newMeshes[i].faceOffset += Int32(truncatingIfNeeded: self.faces.count)
            newMeshes[i].vertexOffset += Int32(truncatingIfNeeded: self.vertices.count)
        }
        for i in 0..<newMaterials.count {
            if (newMaterials[i].diffuseTextureIndex == -1) {
                newMaterials[i].diffuseTextureIndex = 0
            } else {
                newMaterials[i].diffuseTextureIndex += Int16(self.textures.count) - 1 
            }

            if (newMaterials[i].dissolveTextureIndex != -1) {
                newMaterials[i].dissolveTextureIndex += Int16(self.textures.count) - 1
            }
        }

        addVertices(newVertices)
        addFaces(newFaces)
        addMaterials(newMaterials)
        addTextures(newTextures)
        addSubMeshes(newSubMeshes)
        addMeshes(newMeshes)

        for mesh in newMeshes { mesh.modelMatrixChangedBinding = meshModelMatrixChangedBinding }
    }
}

public extension UInt32 {
    static let chunkSceneInfo = UInt32(ascii: "INFO")
    static let chunkTLAS      = UInt32(ascii: "TLAS")
    static let chunkDeltas    = UInt32(ascii: "DLTA")
    
    init(ascii: String) {
        let bytes = Array(ascii.utf8.prefix(4))
        self = bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
}