import simd

private let epsilon: Float = 1e-6

public struct RaycastResult {
    private var hitAndT: simd_float4 = [0, 0, 0, .infinity]
    var normal: simd_float3 = [0, 1, 0]
    var barycentric: simd_float2 = [0, 0]
    var primitiveId: Int32 = -1
    var materialId: Int32 = -1
    var instanceId: Int32 = -1

    var hit: simd_float3 {
        set { hitAndT = simd_float4(newValue, hitAndT.w) }
        get { simd_make_float3(hitAndT) }
    }
    var distance: Float {
        set { hitAndT.w = newValue }
        get { hitAndT.w }
    }
 
    func didHit() -> Bool { return self.distance != .infinity }
    func didNotHit() -> Bool { return self.distance == .infinity }
}

extension Ray {
    func intersectsAABB(_ aabb: AABB) -> Bool {
        // X-axis slab
        var tmin: Float = (aabb.minBounds.x - origin.x) * invDirection.x
        var tmax: Float = (aabb.maxBounds.x - origin.x) * invDirection.x
        if tmin > tmax { swap(&tmin, &tmax) }
        
        // Y-axis slab
        var tymin: Float = (aabb.minBounds.y - origin.y) * invDirection.y
        var tymax: Float = (aabb.maxBounds.y - origin.y) * invDirection.y
        if tymin > tymax { swap(&tymin, &tymax) }

        if (tmin > tymax) || (tymin > tmax) { return false; }
        if tymin > tmin { tmin = tymin }
        if tymax < tmax { tmax = tymax }

        // Z-axis slab
        var tzmin: Float = (aabb.minBounds.z - origin.z) * invDirection.z
        var tzmax: Float = (aabb.maxBounds.z - origin.z) * invDirection.z
        if (tzmin > tzmax) { swap(&tzmin, &tzmax) }

        if (tmin > tzmax) || (tzmin > tmax) || (tmax < 0.0) { return false }
        return true
    }

    func intersectsAABBWithSmallerT(_ aabb: AABB, t: Float) -> Bool {
        // X-axis slab
        var tmin: Float = (aabb.minBounds.x - origin.x) * invDirection.x
        var tmax: Float = (aabb.maxBounds.x - origin.x) * invDirection.x
        if tmin > tmax { swap(&tmin, &tmax) }
        
        // Y-axis slab
        var tymin: Float = (aabb.minBounds.y - origin.y) * invDirection.y
        var tymax: Float = (aabb.maxBounds.y - origin.y) * invDirection.y
        if tymin > tymax { swap(&tymin, &tymax) }

        if (tmin > tymax) || (tymin > tmax) { return false; }
        if tymin > tmin { tmin = tymin }
        if tymax < tmax { tmax = tymax }

        // Z-axis slab
        var tzmin: Float = (aabb.minBounds.z - origin.z) * invDirection.z
        var tzmax: Float = (aabb.maxBounds.z - origin.z) * invDirection.z
        if (tzmin > tzmax) { swap(&tzmin, &tzmax) }

        if (tmin > tzmax) || (tzmin > tmax) || (tmin >= t) || (tmax < 0.0) { return false }
        return true
    }

    func intersectsAABB4(_ aabb4: AABB4) -> simd_float4 {
        // X-axis slab
        let tx1 = (aabb4.minBoundsX - simd_float4(repeating: origin.x)) * invDirection.x
        let tx2 = (aabb4.maxBoundsX - simd_float4(repeating: origin.x)) * invDirection.x
        var tmin = fmin(tx1, tx2);
        var tmax = fmax(tx1, tx2);

        // Y-axis slab
        let ty1 = (aabb4.minBoundsY - simd_float4(repeating: origin.y)) * invDirection.y
        let ty2 = (aabb4.maxBoundsY - simd_float4(repeating: origin.y)) * invDirection.y
        tmin = fmax(tmin, fmin(ty1, ty2))
        tmax = fmin(tmax, fmax(ty1, ty2))

        // Z-axis slab
        let tz1 = (aabb4.minBoundsZ - simd_float4(repeating: origin.z)) * invDirection.z
        let tz2 = (aabb4.maxBoundsZ - simd_float4(repeating: origin.z)) * invDirection.z
        tmin = fmax(tmin, fmin(tz1, tz2))
        tmax = fmin(tmax, fmax(tz1, tz2))

        let hitCondition = (tmin .<= tmax) .& (tmax .> 0.0)
        return simd_float4(repeating: .infinity).replacing(with: tmin, where: hitCondition)
    }

    func intersectsAABB4WithSmallerT(_ aabb4: AABB4, t: Float) -> simd_float4 {
        // X-axis slab
        let tx1 = (aabb4.minBoundsX - simd_float4(repeating: origin.x)) * invDirection.x
        let tx2 = (aabb4.maxBoundsX - simd_float4(repeating: origin.x)) * invDirection.x
        var tmin = fmin(tx1, tx2);
        var tmax = fmax(tx1, tx2);

        // Y-axis slab
        let ty1 = (aabb4.minBoundsY - simd_float4(repeating: origin.y)) * invDirection.y
        let ty2 = (aabb4.maxBoundsY - simd_float4(repeating: origin.y)) * invDirection.y
        tmin = fmax(tmin, fmin(ty1, ty2))
        tmax = fmin(tmax, fmax(ty1, ty2))

        // Z-axis slab
        let tz1 = (aabb4.minBoundsZ - simd_float4(repeating: origin.z)) * invDirection.z
        let tz2 = (aabb4.maxBoundsZ - simd_float4(repeating: origin.z)) * invDirection.z
        tmin = fmax(tmin, fmin(tz1, tz2))
        tmax = fmin(tmax, fmax(tz1, tz2))

        let hitCondition = (tmin .<= tmax) .& (tmax .> 0.0) .& (tmin .< t)
        return simd_float4(repeating: .infinity).replacing(with: tmin, where: hitCondition)
    }

    func intersectsTriangle(_ triangle: MeshTri) -> RaycastResult {
        let position0 = triangle.vertex0.position
        let edge1 = triangle.vertex1.position - position0
        let edge2 = triangle.vertex2.position - position0
        let normal = simd_cross(edge1, edge2)

        // backface Culling, keeps CWW-wound triangles
        if simd_dot(normal, direction) > 0 { return RaycastResult() }

        let direction_cross_edge2 = simd_cross(direction, edge2)
        let det = simd_dot(edge1, direction_cross_edge2) // Triple Scalar Product
        if abs(det) < epsilon { return RaycastResult() }

        let invDet = 1.0 / det
        let s = origin - position0
        let u = invDet * simd_dot(s, direction_cross_edge2)
        if u < -epsilon || u - 1 > epsilon { return RaycastResult() }

        let s_cross_edge1 = simd_cross(s, edge1)
        let v = invDet * simd_dot(direction, s_cross_edge1)
        if v < -epsilon || u + v - 1 > epsilon { return RaycastResult() }

        let t = invDet * simd_dot(edge2, s_cross_edge1)
        if t > epsilon {
            var result = RaycastResult()
            result.hit = origin + direction * t
            result.normal = simd_normalize(normal) // TODO: DONT FORGET TO DO THIS IN METAL TOO
            result.distance = t
            result.barycentric = simd_float2(u, v)
            return result
        }

        return RaycastResult()
    }
}