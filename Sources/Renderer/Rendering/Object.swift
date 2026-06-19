import simd
import Metal

public struct Uniforms {
    let fovScale: Float
    let headNodeIndex: Int32
    let cameraPosition: simd_float3
    let cameraForward: simd_float3
    let cameraUp: simd_float3
    let cameraRight: simd_float3
}

public struct Vertex {
    public var position: simd_float3
    public var uv: simd_float2
    public var normal: simd_float3
}

public struct Face {
    public var vertexIndices: simd_uint3
    public var subMeshIndex: Int32
}

public struct RayTraceTriangleGPU {
    public var vertex1: Vertex
    public var vertex2: Vertex
    public var vertex3: Vertex
    public var edge1: simd_float3
    public var edge2: simd_float3
    public var normal: simd_float3
    public var materialIndex: Int32
}

public struct Material {
    public var ambientColor: simd_float3 = simd_float3(1, 1, 1)
    public var ambientTextureIndex: Int32 = 0 // -1 = No Texture
    public var dissolve: Float = 1.0 // 1.0 = Opaque, 0.0 = Transparent
}

public struct SubMesh {
    public var vertexOffset: Int32 // Where in the scene vertices list the submesh starts
    public var vertexCount: Int32 // The range of vertices that are of this submesh
    public var faceOffset: Int32
    public var faceCount: Int32
    public var materialIndex: Int32
}

public struct Mesh {
    public var subMeshOffset: Int32
    public var subMeshCount: Int32
}

public struct MaterialGPU {
    var dissolve: Float
}

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

public class Triangle {
    var vertices: [Vertex]
    var subMesh: SubMesh

    init(vertices: [Vertex], subMesh: SubMesh) {
        self.vertices = vertices
        self.subMesh = subMesh
    }
}

public class SubMesh {
    var triangles: [Triangle]
    var material: Material?

    init(triangles: [Triangle], material: Material?) {
        self.triangles = triangles
        self.material = material
    }
}

public final class Mesh {
    var name: String
    var position: simd_float3
    var rotation: simd_float3 // Change to quaternion later
    var size: simd_float3
    var subMeshes: [SubMesh]
    
    init(
        name: String, 
        position: simd_float3 = simd_float3(0, 0, 0), 
        rotation: simd_float3 = simd_float3(0, 0, 0), 
        size: simd_float3 = simd_float3(1, 1, 1), 
        subMeshes: [SubMesh]
    ) {
        self.position = position
        self.rotation = rotation
        self.size = size
        self.subMeshes = subMeshes
        self.name = name
    }
}

public struct Model {
    var children: [Mesh]
}
*/