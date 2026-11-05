import simd

extension SIMD {
    subscript(axis: Axis) -> Scalar {
        get { return self[axis.rawValue] }
        set { self[axis.rawValue] = newValue }
    }
}

extension simd_float4x4 {
    @inlinable init(translation t: simd_float3) {
        self.init(columns: (
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [t.x, t.y, t.z, 1]
        ))
    }

    @inlinable init(scale s: simd_float3) {
        self.init(columns: (
            [s.x, 0, 0, 0],
            [0, s.y, 0, 0],
            [0, 0, s.z, 0],
            [0, 0, 0, 1]
        ))
    }

    @inlinable
    func extractTransformDetails() -> (position: simd_float3, eulerAnglesDegrees: simd_float3, scale: simd_float3) {
        let position = simd_float3(columns.3.x, columns.3.y, columns.3.z)
        
        let col0 = simd_float3(columns.0.x, columns.0.y, columns.0.z)
        let col1 = simd_float3(columns.1.x, columns.1.y, columns.1.z)
        let col2 = simd_float3(columns.2.x, columns.2.y, columns.2.z)
        let scale = simd_float3(simd_length(col0), simd_length(col1), simd_length(col2))
        
        let invScale = 1.0 / scale
        let rotationMatrix = simd_float3x3(
            col0 * invScale.x,
            col1 * invScale.y,
            col2 * invScale.z
        )
        
        // 4. Convert to quaternion and extract Euler angles (YXZ / Tait-Bryan)
        let q = simd_quatf(rotationMatrix)
        let x = q.vector.x, y = q.vector.y, z = q.vector.z, w = q.vector.w
        
        let sinP = 2.0 * (w * x - y * z)
        let pitch = abs(sinP) >= 1 ? copysign(.pi / 2, sinP) : asin(sinP)
        let yaw = atan2(2.0 * (w * y + x * z), 1.0 - 2.0 * (x * x + y * y))
        let roll = atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (x * x + z * z))
        
        let eulerDegrees = simd_float3(pitch, yaw, roll) * (180.0 / .pi)
        return (position, eulerDegrees, scale)
    }
}