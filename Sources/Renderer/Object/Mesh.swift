import simd

class Mesh : Object {
    var meshResourceHandle : ResourceHandle<MeshResource>
    var meshResource       : MeshResource                   { meshResourceHandle.resource }
    var material           : Material
    var baseMaterial       : BaseMaterial?                  { material.baseMaterial       }

    var position : simd_float3 = .zero { didSet { isTransformDirty = true } }
    /// Euler Angles in Degrees 
    var rotation : simd_float3 = .zero { didSet { isTransformDirty = true } }
    var scale    : simd_float3 = .one  { didSet { isTransformDirty = true } }
    var pivot    : simd_float3 = .zero { didSet { isTransformDirty = true } }

    private var isTransformDirty  : Bool           = true
    private var _modelMatrix      : simd_float4x4  = matrix_identity_float4x4
    private var _invModelMatrix   : simd_float4x4  = matrix_identity_float4x4
    private var _normalMatrix     : simd_float3x3  = matrix_identity_float3x3
    private var _worldBounds      : AABB           = AABB(minBounds: .zero, maxBounds: .zero)

    /// If this Mesh should be processed when Raycasting
    var canQuery      : Bool = true
    var isTransparent : Bool { (material.baseMaterial?.diffuseColor.a ?? 1.0) < 1.0 }

    init(
        meshResourceHandle : ResourceHandle<MeshResource>,
        material           : Material,

        pivot          : simd_float3  = .zero,
        position       : simd_float3  = .zero,
        rotation       : simd_float3  = .zero,
        scale          : simd_float3  = .one,
    ) {
        self.meshResourceHandle = meshResourceHandle
        self.material           = material
        self.pivot              = pivot
        self.position           = position
        self.rotation           = rotation
        self.scale              = scale
        
        super.init(name: meshResourceHandle.resource.name)
    }

    init(
        meshResourceHandle : ResourceHandle<MeshResource>,
        material           : Material,

        pivot     : simd_float3   = .zero,
        transform : simd_float4x4 = matrix_identity_float4x4              
    ) {
        self.meshResourceHandle = meshResourceHandle
        self.material = material
        self.pivot = pivot
        let details = transform.extractTransformDetails()
        self.position = details.position
        self.rotation = details.eulerAnglesDegrees
        self.scale    = details.scale

        super.init(name: meshResourceHandle.resource.name)
    }

    var vertexHandle: MTLBufferAllocator<Vertex>.Handle? { meshResource.vertexHandle }
    var indexHandle:  MTLBufferAllocator<UInt32>.Handle? { meshResource.indexHandle  }

    var modelMatrix    : simd_float4x4 { updateTransformIfDirty(); return _modelMatrix           }
    var invModelMatrix : simd_float4x4 { updateTransformIfDirty(); return _invModelMatrix        }
    var normalMatrix   : simd_float3x3 { updateTransformIfDirty(); return _normalMatrix          }
    var worldBounds    : AABB          { updateTransformIfDirty(); return _worldBounds           }
    var worldMinBounds : simd_float3   { updateTransformIfDirty(); return _worldBounds.minBounds }
    var worldMaxBounds : simd_float3   { updateTransformIfDirty(); return _worldBounds.maxBounds }
    var localMinBounds : simd_float3   { return meshResource.localMinBounds                      }
    var localMaxBounds : simd_float3   { return meshResource.localMaxBounds                      }

    func updateTransformIfDirty() {
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

        _worldBounds.minBounds = simd_float3(repeating: Float.greatestFiniteMagnitude)
        _worldBounds.maxBounds = simd_float3(repeating: -Float.greatestFiniteMagnitude)

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
            _worldBounds.extend(with: p)
        }

        isTransformDirty = false
    }
}