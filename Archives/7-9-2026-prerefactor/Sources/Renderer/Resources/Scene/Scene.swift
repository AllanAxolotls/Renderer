import Metal
import Combine

public enum DirtyFlagType : Int, CaseIterable {
    case Vertices, Indices, MaterialDatas, Meshes, UpdateTLAS, RebuildTLAS // TODO: change to reform
}

public struct DirtyFlags {
    var flags: [Bool] = []
    public var ignoreTLASMakeDirties: Bool = false // TODO: change name

    public init() {
        flags.reserveCapacity(DirtyFlagType.allCases.count)
        for _ in DirtyFlagType.allCases { flags.append(true) }
    }

    public mutating func makeDirty(_ flag: DirtyFlagType) {
        self.flags[flag.rawValue] = true
        if !ignoreTLASMakeDirties { // For all flags, TLAS needs to be rebuild, TODO: maybe not do this for MaterialDatas?
            flags[DirtyFlagType.RebuildTLAS.rawValue] = true
        }
        flags[DirtyFlagType.UpdateTLAS.rawValue] = true // Update GPU Buffers always
    }

    public mutating func makeClean(_ flag: DirtyFlagType) {
        self.flags[flag.rawValue] = false
    }
}

public class Scene: @unchecked Sendable {
    public var id = UUID()
    public var name: String
    public var textureHandler: TextureHandler? = nil
    public var dirtyFlags = DirtyFlags()

    public var vertices: [Vertex] = []              { didSet { dirtyFlags.makeDirty(.Vertices)      } }
    public var indices: [UInt32] = []               { didSet { dirtyFlags.makeDirty(.Indices)       } }
    public var materials: [Material] = []
    public var materialDatas: [MaterialData] = []   { didSet { dirtyFlags.makeDirty(.MaterialDatas) } }
    public var meshes: [Mesh] = []                  { didSet { dirtyFlags.makeDirty(.Meshes)        } }

    public var camera: Camera = Camera()
    var tlas = TLAS()

    init(name: String) {
        self.name = name
    }

    public func createTextureHandler(device: MTLDevice) {
        self.textureHandler = TextureHandler(device: device)

        // Create Materials
    }

    // TODO: in the future instead of straight up calling reform, queue it so one reform for a bunch of meshes instead
    public func meshModelMatrixChangedBinding(mesh: Mesh) {
        self.dirtyFlags.makeDirty(.Meshes)
    }

    @discardableResult
    public func importObject(objectImporter: ObjectImporter, filePath: String) -> (
        newVertexStart: Int, newIndexStart: Int, newMaterialStart: Int,
        newMaterialDataStart: Int, newMeshStart: Int
    ) {
        let vertexEnd = self.vertices.endIndex
        let indexEnd = self.indices.endIndex
        let materialEnd = self.materials.endIndex
        let materialDataEnd = self.materialDatas.endIndex
        let meshEnd = self.meshes.endIndex

        objectImporter.importObject(
            filePath: filePath, 
            vertices: &self.vertices, 
            indices: &self.indices, 
            materials: &self.materials, 
            materialDatas: &self.materialDatas, 
            meshes: &self.meshes
        )

        let newMeshes = self.meshes[meshEnd...]
        for mesh in newMeshes {
            if mesh.parentId == nil { mesh.parentId = self.id }
            mesh.updateTransformIfNeeded()
            mesh.modelMatrixChangedBinding = meshModelMatrixChangedBinding
        }

        return (
            newVertexStart: vertexEnd, newIndexStart: indexEnd, newMaterialStart: materialEnd,
            newMaterialDataStart: materialDataEnd, newMeshStart: meshEnd 
        )
    }
}