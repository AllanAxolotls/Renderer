import simd

public struct Vertex {
    public var position: simd_float3
    public var uv: simd_float2
    public var normal: simd_float3
}

public struct Face {
    public var vertexIndices: simd_uint3
    public var subMeshIndex: Int32
}

public struct Material {
    public var ambientColor: simd_float3 = simd_float3(1, 1, 1)
    public var diffuseColor: simd_float3 = simd_float3(1, 1, 1)
    public var specularColor: simd_float3 = simd_float3(1, 1, 1)
    public var emissionColor: simd_float3 = simd_float3(0, 0, 0)
    public var ambientTextureIndex: Int32 = -1
    public var diffuseTextureIndex: Int32 = -1 // -1 = No Texture
    public var specularTextureIndex: Int32 = -1
    public var dissolveTextureIndex: Int32 = -1
    public var bumpTextureIndex: Int32 = -1
    public var illuminationModel: Int32 = 2
    public var dissolve: Float = 1.0 // 1.0 = Opaque, 0.0 = Transparent
    public var emissionIntensity: Float = 1
    public var roughness: Float = 1
    public var metallic: Float = 0
    public var refractiveIndex: Float = 1.0 // How much light bends
}

public struct SubMesh { // Submeshes are essentially DrawCalls, every drawcall has one material
    public var vertexOffset: Int32 // Where in the scene vertices list the submesh starts
    public var vertexCount: Int32 // The range of vertices that are of this submesh
    public var faceOffset: Int32
    public var faceCount: Int32
    public var materialIndex: Int32
    public var meshIndex: Int32
}

public final class Mesh {
    public var subMeshOffset: Int32
    public var subMeshCount: Int32
    public var faceOffset: Int32
    public var faceCount: Int32
    public var vertexOffset: Int32
    public var vertexCount: Int32

    public var name: String = "Mesh"
    public var pivot: simd_float3 = simd_float3(0, 0, 0) {  didSet { self.modelMatrix = calcModelMatrix() } }
    public var position: simd_float3 = simd_float3(0, 0, 0) { didSet { self.translationMatrix = calcTranslationMatrix(position) }  }
    public var rotation: simd_float3 = simd_float3(0, 0, 0) {  didSet { self.rotationMatrix = calcRotationMatrix() } }
    public var size: simd_float3 = simd_float3(1, 1, 1) { didSet { self.scaleMatrix = calcScaleMatrix() } }

    private var translationMatrix: simd_float4x4 = matrix_identity_float4x4 { didSet { self.modelMatrix = calcModelMatrix() } }
    private func calcTranslationMatrix(_ p: simd_float3) -> simd_float4x4 {
        return simd_float4x4(columns: (
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(p.x, p.y, p.z, 1)
        ))
    }

    private var rotationMatrix: simd_float4x4 = matrix_identity_float4x4 { didSet { self.modelMatrix = calcModelMatrix() } }
    private func calcRotationMatrix() -> simd_float4x4 {
        let rx = self.rotation.x * .pi / 180
        let ry = self.rotation.y * .pi / 180
        let rz = self.rotation.z * .pi / 180
        let qx = simd_quatf(angle: rx, axis: simd_float3(1, 0, 0))
        let qy = simd_quatf(angle: ry, axis: simd_float3(0, 1, 0))
        let qz = simd_quatf(angle: rz, axis: simd_float3(0, 0, 1))
        return simd_float4x4(qz * qy * qx)
    }

    private var scaleMatrix: simd_float4x4 = matrix_identity_float4x4 { didSet { self.modelMatrix = calcModelMatrix() } }
    private func calcScaleMatrix() -> simd_float4x4 {
        return simd_float4x4(columns: (
            simd_float4(self.size.x, 0, 0, 0),
            simd_float4(0, self.size.y, 0, 0),
            simd_float4(0, 0, self.size.z, 0),
            simd_float4(0, 0, 0, 1)
        ))
    }

    public var modelMatrixChangedBinding: ((Mesh) -> ())? = nil
    public var modelMatrix: simd_float4x4 = matrix_identity_float4x4 { didSet {
        (self.worldMinBounds, self.worldMaxBounds) = calcWorldBounds()
        self.invModelMatrix = self.modelMatrix.inverse
        let invModelMatrix3x3 = simd_float3x3(
            simd_make_float3(invModelMatrix.columns.0),
            simd_make_float3(invModelMatrix.columns.1),
            simd_make_float3(invModelMatrix.columns.2),
        )
        self.normalMatrix = invModelMatrix3x3.transpose
        if let changedBinding = modelMatrixChangedBinding { changedBinding(self) }
    }}
    public var invModelMatrix: simd_float4x4 = matrix_identity_float4x4
    public var normalMatrix: simd_float3x3 = matrix_identity_float3x3
    public var localMinBounds: simd_float3 { didSet { (self.worldMinBounds, self.worldMaxBounds) = calcWorldBounds() } }
    public var localMaxBounds: simd_float3 { didSet { (self.worldMinBounds, self.worldMaxBounds) = calcWorldBounds() } }
    public var worldMinBounds: simd_float3
    public var worldMaxBounds: simd_float3

    init(
        name: String, pivot: simd_float3,
        subMeshOffset: Int32, subMeshCount: Int32, 
        faceOffset: Int32, faceCount: Int32, 
        vertexOffset: Int32, vertexCount: Int32,
        localMinBounds: simd_float3, localMaxBounds: simd_float3
    ) {
        self.name = name
        self.subMeshOffset = subMeshOffset
        self.subMeshCount = subMeshCount
        self.faceOffset = faceOffset
        self.faceCount = faceCount
        self.vertexOffset = vertexOffset
        self.vertexCount = vertexCount
        self.localMinBounds = localMinBounds
        self.localMaxBounds = localMaxBounds
        self.worldMinBounds = self.localMinBounds
        self.worldMaxBounds = self.localMaxBounds
        (self.worldMinBounds, self.worldMaxBounds) = calcWorldBounds()
        self.pivot = pivot // causes WorldBounds and Model Matrix and all other stuff to get calculated
    }

    private func calcModelMatrix() -> simd_float4x4 {
        return translationMatrix * calcTranslationMatrix(self.pivot) * rotationMatrix * scaleMatrix * calcTranslationMatrix(-self.pivot)
    }

    private func calcWorldBounds() -> (min: simd_float3, max: simd_float3) {
        var minV = simd_float3(repeating: Float.greatestFiniteMagnitude)
        var maxV = simd_float3(repeating: -Float.greatestFiniteMagnitude)

        func include(_ p: simd_float3) {
            minV = min(minV, p)
            maxV = max(maxV, p)
        }

        let corners = [
            simd_float3(self.localMinBounds.x, self.localMinBounds.y, self.localMinBounds.z),
            simd_float3(self.localMinBounds.x, self.localMinBounds.y, self.localMaxBounds.z),
            simd_float3(self.localMinBounds.x, self.localMaxBounds.y, self.localMinBounds.z),
            simd_float3(self.localMinBounds.x, self.localMaxBounds.y, self.localMaxBounds.z),
            simd_float3(self.localMaxBounds.x, self.localMinBounds.y, self.localMinBounds.z),
            simd_float3(self.localMaxBounds.x, self.localMinBounds.y, self.localMaxBounds.z),
            simd_float3(self.localMaxBounds.x, self.localMaxBounds.y, self.localMinBounds.z),
            simd_float3(self.localMaxBounds.x, self.localMaxBounds.y, self.localMaxBounds.z),
        ]
        for c in corners {
            let w = self.modelMatrix * simd_float4(c, 1)
            include(simd_float3(w.x, w.y, w.z))
        }
        return (min: minV, max: maxV)
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