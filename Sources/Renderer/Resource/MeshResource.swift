import Foundation
import simd

final class MeshResource : Resource, @unchecked Sendable {
    var vertexHandle : MTLBufferAllocator<Vertex>.Handle? = nil
    var indexHandle  : MTLBufferAllocator<UInt32>.Handle? = nil
    var blas         : Blas?                              = nil

    /// Bounds without the Model Matrix Transformation
    var localBounds   : AABB        = AABB()
    var localMinBounds: simd_float3 { 
        get { localBounds.minBounds }
        set { localBounds.minBounds = newValue }
    }
    var localMaxBounds: simd_float3 { 
        get { localBounds.maxBounds }
        set { localBounds.maxBounds = newValue }
    }

    init(
        name: String = "Unnamed MeshResource",
        assetURL: URL? = nil,

        vertexHandle   : MTLBufferAllocator<Vertex>.Handle? = nil,
        indexHandle    : MTLBufferAllocator<UInt32>.Handle? = nil,
        blas           : Blas?                              = nil,

        localBounds    : AABB? = nil
    ) {
        self.vertexHandle = vertexHandle
        self.indexHandle  = indexHandle
        self.blas         = blas
        super.init(name: name, assetURL: assetURL)

        if let localBounds = localBounds {
            self.localBounds = localBounds
        } else {
            self.vertexHandle?.withUnsafeBufferPointer { buffer in
                for vertex in buffer { self.localBounds.extend(with: vertex.position) }
            }
        }

    }

    override func performLoad() throws {
        // Should be used for mesh files that get stored solo
        // .obj doesn't have this so this function can stay empty
    }

    override func unload() {
        vertexHandle?.free()
        indexHandle?.free()
    }

    func findTransform(to desc: MeshResourceDescription) -> simd_float4x4? {
        guard let vertexHandle = self.vertexHandle,
            let indexHandle = self.indexHandle else { return nil }

        guard vertexHandle.count == desc.vertices.count,
            indexHandle.count == desc.indices.count,
            indexHandle.count >= 3 else { return nil }

        let epsilon: Float = 1e-4

        func calcNormalizedDotProduct(a: simd_float3, b: simd_float3) -> Float {
            let lenA = simd_length(a)
            let lenB = simd_length(b)
            guard lenA > 1e-6 && lenB > 1e-6 else { return 0.0 }
            return abs(simd_dot(a, b)) / (lenA * lenB)
        }

        func getTriangleAngle(lhs: Vertex, mid: Vertex, rhs: Vertex) -> Float {
            let leftEdge = lhs.position - mid.position
            let rightEdge = rhs.position - mid.position
            return calcNormalizedDotProduct(a: leftEdge, b: rightEdge)
        }

        func getTriangleAngles(_ vertex0: Vertex, _ vertex1: Vertex, _ vertex2: Vertex) -> simd_float2 {
            return simd_float2(
                getTriangleAngle(lhs: vertex1, mid: vertex0, rhs: vertex2),
                getTriangleAngle(lhs: vertex2, mid: vertex1, rhs: vertex0)
            )
        }

        func getNormalAngle(a: Vertex, b: Vertex) -> Float {
            return calcNormalizedDotProduct(a: a.normal, b: b.position - a.position)
        }

        func getNormalAngles(_ vertex0: Vertex, _ vertex1: Vertex, _ vertex2: Vertex) -> simd_float3 {
            return simd_float3(
                getNormalAngle(a: vertex0, b: vertex1),
                getNormalAngle(a: vertex1, b: vertex2),
                getNormalAngle(a: vertex2, b: vertex0)
            )
        }

        for i in stride(from: 0, to: indexHandle.count, by: 3) {
            let vertex0 = vertexHandle[Int(indexHandle[i + 0]!)]!
            let vertex1 = vertexHandle[Int(indexHandle[i + 1]!)]!
            let vertex2 = vertexHandle[Int(indexHandle[i + 2]!)]!

            let descVertex0 = desc.vertices[Int(desc.indices[i + 0])]
            let descVertex1 = desc.vertices[Int(desc.indices[i + 1])]
            let descVertex2 = desc.vertices[Int(desc.indices[i + 2])]

            let normals1 = getNormalAngles(vertex0, vertex1, vertex2)
            let normals2 = getNormalAngles(descVertex0, descVertex1, descVertex2)
            if any(abs(normals1 - normals2) .> epsilon) { return nil }

            let angles1 = getTriangleAngles(vertex0, vertex1, vertex2)
            let angles2 = getTriangleAngles(descVertex0, descVertex1, descVertex2)
            if any(abs(angles1 - angles2) .> epsilon) { return nil }
        }

        let srcP0 = vertexHandle[Int(indexHandle[0]!)]!.position
        let srcP1 = vertexHandle[Int(indexHandle[1]!)]!.position
        let srcP2 = vertexHandle[Int(indexHandle[2]!)]!.position

        let dstP0 = desc.vertices[Int(desc.indices[0])].position
        let dstP1 = desc.vertices[Int(desc.indices[1])].position
        let dstP2 = desc.vertices[Int(desc.indices[2])].position

        let srcCenter = (srcP0 + srcP1 + srcP2) / 3.0
        let dstCenter = (dstP0 + dstP1 + dstP2) / 3.0

        let srcU = normalize(srcP1 - srcP0)
        let srcV = normalize(cross(srcU, srcP2 - srcP0))
        let srcW = cross(srcU, srcV)
        
        let R_src = simd_float3x3(srcU, srcV, srcW)

        let dstU = normalize(dstP1 - dstP0)
        let dstV = normalize(cross(dstU, dstP2 - dstP0))
        let dstW = cross(dstU, dstV)
        
        let R_dst = simd_float3x3(dstU, dstV, dstW)
        let rotationMatrix3x3 = R_dst * simd_transpose(R_src)
        let translationVector = dstCenter - rotationMatrix3x3 * srcCenter

        var transform = matrix_identity_float4x4
        transform.columns.0 = simd_float4(rotationMatrix3x3.columns.0, 0.0)
        transform.columns.1 = simd_float4(rotationMatrix3x3.columns.1, 0.0)
        transform.columns.2 = simd_float4(rotationMatrix3x3.columns.2, 0.0)
        transform.columns.3 = simd_float4(translationVector, 1.0)

        return transform
    }
}

struct MeshResourceDescription {
    var name: String = "Unnamed Mesh"
    var vertices: [Vertex] = []
    var indices: [UInt32] = []
}
