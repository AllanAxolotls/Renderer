import Compression

enum RyxSceneSectionType : UInt32, CaseIterable {
    // ResourceManager
    case vertices, indices, baseMaterials
    // CollisionManager
    case meshTris, blasNodes, tlasNodes, tlasInstances
    // SceneGraph
    case meshes, meshResources, materials, materialResources
    case textures, textureResources
    case meshLibrary, materialLibrary
    case sceneGraph

    var magicString: String {
        switch self {
            case .vertices:          return "VERT"
            case .indices:           return "INDC"
            case .baseMaterials:     return "BMAT"
            case .meshTris:          return "TRIS"
            case .blasNodes:         return "BLAS"
            case .tlasNodes:         return "TLAS"
            case .tlasInstances:     return "TINS"
            case .meshes:            return "MESH"
            case .meshResources:     return "MSHR"
            case .materials:         return "MATL"
            case .materialResources: return "MTLR"
            case .textures:          return "TEXT"
            case .textureResources:  return "TEXR"
            case .meshLibrary:       return "MSHL"
            case .materialLibrary:   return "MTLL"
            case .sceneGraph:        return "SCNG"
        }
    }

    var fourCC: UInt32 {
        let bytes = Array(magicString.utf8.prefix(4))
        return bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
}

enum RyxSceneCompressionType : UInt32 {
    case none = 0
    case lzfse = 1

    func getCompressionAlgorithm() -> compression_algorithm? {
        switch self {
            case .none: return nil
            case .lzfse: return COMPRESSION_LZFSE
        }
    }
}

struct RyxSceneHeader {
    let magicNumber: UInt32
    let versionNumber: UInt32
    let compressionType: RyxSceneCompressionType
    let flags: UInt32
    let tocOffset: UInt64
    let compressedBodySize: UInt64
    let uncompressedBodySize: UInt64
}

struct RyxSceneTocEntry {
    let magicNumber: UInt32
    let versionNumber: UInt32
    let payloadByteSize: UInt64
    let payloadAbsoluteByteOffset: UInt64
}