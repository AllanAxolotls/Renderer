import simd

enum Axis: Int, CaseIterable {
    case X = 0
    case Y = 1
    case Z = 2
}

struct AABB {
    var minBounds = simd_float3(repeating: Float.greatestFiniteMagnitude)
    var maxBounds = simd_float3(repeating: -Float.greatestFiniteMagnitude)

    init(
        minBounds: simd_float3 = simd_float3(repeating: Float.greatestFiniteMagnitude), 
        maxBounds: simd_float3 = simd_float3(repeating: -Float.greatestFiniteMagnitude)
    ) {
        self.minBounds = minBounds
        self.maxBounds = maxBounds
    }

    init(from points: [simd_float3]) {
        for point in points { self.extend(with: point) }
    }

    init(from triangle: MeshTri) {
        self.extend(with: triangle.vertex0.position)
        self.extend(with: triangle.vertex1.position)
        self.extend(with: triangle.vertex2.position)
    }

    init(from triangles: [MeshTri]) {
        for triangle in triangles {
            self.extend(with: triangle.vertex0.position)
            self.extend(with: triangle.vertex1.position)
            self.extend(with: triangle.vertex2.position)
        }
    }

    init(from meshes: [Mesh]) {
        for mesh in meshes { self.extend(with: mesh.worldBounds) }
    }

    mutating func extend(with point: simd_float3) {
        self.minBounds = min(minBounds, point)
        self.maxBounds = max(maxBounds, point)
    }

    mutating func extend(with aabb: AABB) {
        self.minBounds = min(self.minBounds, aabb.minBounds)
        self.maxBounds = max(self.maxBounds, aabb.maxBounds)
    }

    func surfaceArea() -> Float {
        let d = maxBounds - minBounds
        let x = max(0.0, d.x)
        let y = max(0.0, d.y)
        let z = max(0.0, d.z)
        return 2.0 * (x * y + y * z + z * x)
    }

    func longestAxis() -> Axis {
        let extents = maxBounds - minBounds
        if (extents.x > extents.y) && (extents.x > extents.z) {
            return .X
        } else if extents.y > extents.z {
            return .Y
        } else {
            return .Z
        }
    }
}

struct AABB4 {
    var minBoundsX = simd_float4(repeating:  .infinity)
    var maxBoundsX = simd_float4(repeating: -.infinity)
    var minBoundsY = simd_float4(repeating:  .infinity)
    var maxBoundsY = simd_float4(repeating: -.infinity)
    var minBoundsZ = simd_float4(repeating:  .infinity)
    var maxBoundsZ = simd_float4(repeating: -.infinity)
}