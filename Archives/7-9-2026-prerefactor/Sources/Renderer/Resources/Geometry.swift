import simd
import Foundation

public struct Vertex {
    public var position: simd_float3
    public var normal: simd_float3
    public var uv: simd_float2
}

public struct Material {
    public var id: UUID
    public var name: String = "Default"
    public var materialDataIndex: UInt32 = 0
    public var diffuseTexturePath: URL? = nil
    public var dissolveTexturePath: URL? = nil

    public init(
        id: UUID = UUID(),
        name: String = "Default"
    ) {
        self.id = id
        self.name = name
    }
}

// Shared by the Rasterizer and RayTracer
public struct MaterialData {
    //public var ambientColor: simd_float3 = simd_float3(1, 1, 1)
    public var diffuseColor = simd_float4(1, 1, 1, 1) // .w = dissolve (1.0 = opaque, 0.0 = transparent)
    //public var specularColor: simd_float3 = simd_float3(1, 1, 1)
    public var emissionColor = simd_float4(0, 0, 0, 1) // .w = emissionIntensity
    public var params = simd_float4(1, 0, 1, 0) // .x=roughness, .y=metallic, .z=refractiveIndex, .w=bitflag (0=normal, 1=isSky)
    //public var ambientTextureIndex: Int16 = -1
    public var diffuseTextureIndex: UInt16 = 0
    //public var specularTextureIndex: Int16 = -1
    public var dissolveTextureIndex: Int16 = -1
    //public var bumpTextureIndex: Int16 = -1
    //public var illuminationModel: Int16 = 2
}

public struct SubMesh {
    // Indices are relative to baseVertex, not global array
    // Currently TLAS doesn't handle this, also the importer doesn't even do it correctly
    public var indexOffset: UInt32 // Start index inside global index buffer
    public var indexCount: UInt32 // Number of indices for this draw call (must be divisible by 3)
    public var vertexOffset: UInt32 // Adds offset to indices in Rasterizer
    public var vertexCount: UInt32
    public var materialIndex: UInt32
    public var meshIndex: UInt32
}

public final class Mesh {
    // Scene Graph IDs
    public var id: UUID
    public var name: String = "Mesh"
    public var parentId: UUID? = nil
    public var childrenIds: [UUID] = []

    // Geometry SubMeshes
    public var subMeshes: [SubMesh] = []
    
    public var localMinBounds: simd_float3 { didSet { isTransformDirty = true } }
    public var localMaxBounds: simd_float3 { didSet { isTransformDirty = true } }
    
    public var position: simd_float3 = .zero { didSet { isTransformDirty = true } }
    public var rotation: simd_float3 = .zero { didSet { isTransformDirty = true } } // Euler angles in degrees
    public var scale: simd_float3 = [1, 1, 1] { didSet { isTransformDirty = true } }
    public var pivot: simd_float3 = .zero { didSet { isTransformDirty = true } }

    private var isTransformDirty: Bool = true
    private var _modelMatrix: simd_float4x4 = matrix_identity_float4x4
    private var _invModelMatrix: simd_float4x4 = matrix_identity_float4x4
    private var _normalMatrix: simd_float3x3 = matrix_identity_float3x3
    private var _worldMinBounds: simd_float3 = .zero
    private var _worldMaxBounds: simd_float3 = .zero

    public var modelMatrixChangedBinding: ((Mesh) -> Void)? = nil

    public init(
        id: UUID = UUID(),
        name: String,
        subMeshes: [SubMesh],
        pivot: simd_float3 = .zero,
        position: simd_float3 = .zero,
        rotation: simd_float3 = .zero,
        scale: simd_float3 = [1, 1, 1],
        localMinBounds: simd_float3 = .zero,
        localMaxBounds: simd_float3 = .zero
    ) {
        self.id = id
        self.name = name
        self.subMeshes = subMeshes
        self.pivot = pivot
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.localMinBounds = localMinBounds
        self.localMaxBounds = localMaxBounds
    }

    public var modelMatrix: simd_float4x4 {
        updateTransformIfNeeded()
        return _modelMatrix
    }

    public var invModelMatrix: simd_float4x4 {
        updateTransformIfNeeded()
        return _invModelMatrix
    }

    public var normalMatrix: simd_float3x3 {
        updateTransformIfNeeded()
        return _normalMatrix
    }

    public var worldMinBounds: simd_float3 {
        updateTransformIfNeeded()
        return _worldMinBounds
    }

    public var worldMaxBounds: simd_float3 {
        updateTransformIfNeeded()
        return _worldMaxBounds
    }

    public func updateTransformIfNeeded() {
        guard isTransformDirty else { return }

        let rad = rotation * (.pi / 180.0)
        let qx = simd_quatf(angle: rad.x, axis: [1, 0, 0])
        let qy = simd_quatf(angle: rad.y, axis: [0, 1, 0])
        let qz = simd_quatf(angle: rad.z, axis: [0, 0, 1])
        let rotMat = simd_float4x4(qz * qy * qx)

        let T = simd_float4x4(translation: position)
        let P = simd_float4x4(translation: pivot)
        let InvP = simd_float4x4(translation: -pivot)
        let S = simd_float4x4(scale: scale)

        _modelMatrix = T * P * rotMat * S * InvP
        _invModelMatrix = _modelMatrix.inverse

        let inv3x3 = simd_float3x3(
            simd_make_float3(_invModelMatrix.columns.0),
            simd_make_float3(_invModelMatrix.columns.1),
            simd_make_float3(_invModelMatrix.columns.2)
        )
        _normalMatrix = inv3x3.transpose

        var minV = simd_float3(repeating: Float.greatestFiniteMagnitude)
        var maxV = simd_float3(repeating: -Float.greatestFiniteMagnitude)

        let corners: [simd_float3] = [
            [localMinBounds.x, localMinBounds.y, localMinBounds.z],
            [localMinBounds.x, localMinBounds.y, localMaxBounds.z],
            [localMinBounds.x, localMaxBounds.y, localMinBounds.z],
            [localMinBounds.x, localMaxBounds.y, localMaxBounds.z],
            [localMaxBounds.x, localMinBounds.y, localMinBounds.z],
            [localMaxBounds.x, localMinBounds.y, localMaxBounds.z],
            [localMaxBounds.x, localMaxBounds.y, localMinBounds.z],
            [localMaxBounds.x, localMaxBounds.y, localMaxBounds.z]
        ]

        for corner in corners {
            let worldPos = _modelMatrix * simd_float4(corner, 1.0)
            let p = simd_float3(worldPos.x, worldPos.y, worldPos.z)
            minV = min(minV, p)
            maxV = max(maxV, p)
        }

        _worldMinBounds = minV
        _worldMaxBounds = maxV

        isTransformDirty = false
        modelMatrixChangedBinding?(self)
    }
}

extension simd_float4x4 {
    @inlinable
    init(translation t: simd_float3) {
        self.init(columns: (
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [t.x, t.y, t.z, 1]
        ))
    }

    @inlinable
    init(scale s: simd_float3) {
        self.init(columns: (
            [s.x, 0, 0, 0],
            [0, s.y, 0, 0],
            [0, 0, s.z, 0],
            [0, 0, 0, 1]
        ))
    }
}

public final class SphereLight {
    public var position: simd_float3
    public var emission: simd_float3
    public var radius: Float

    init(position: simd_float3, emission: simd_float3, radius: Float) {
        self.position = position
        self.emission = emission
        self.radius = radius
    }
}



// Legacy Stuff
/*
public class Material {
    var name: String
    var Ka: simd_float3 // Ambient Color
    var Kd: simd_float3 // Diffuse Color
    var Ks: simd_float3 // Specular Color
    var Ke: Float

    var Ns: Float // Specular Exponent
    var Ni: Float // Optical Density
    var illum: Float // Illumination
    var d: Float        // Opacity
    // var type: Int // (ENUM), Material Type: Plastic, Metal, etc.

    var map_Ka: MTLTexture?
    var map_Kd: MTLTexture?
    var map_Ks: MTLTexture?
    var map_Bump: MTLTexture?

    init(
        name: String, 
        Ka: simd_float3,  Kd: simd_float3,  Ks: simd_float3, 
        Ke: Float, 
        Ns: Float,  Ni: Float, 
        illum: Float, 
        d: Float, 
        map_Ka: MTLTexture?, map_Kd: MTLTexture?, map_Ks: MTLTexture?, map_Bump: MTLTexture?
    ) {
        self.name = name
        self.Ka = Ka
        self.Kd = Kd
        self.Ks = Ks
        self.Ke = Ke
        self.Ns = Ns
        self.Ni = Ni
        self.illum = illum
        self.d = d
        self.map_Ka = map_Ka
        self.map_Kd = map_Kd
        self.map_Ks = map_Ks
        self.map_Bump = map_Bump
    }
}
*/