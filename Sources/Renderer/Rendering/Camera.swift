import simd

@MainActor var camera_move_speed: Float = 40
@MainActor var camera_rotate_speed: Float = 2.0

struct Camera {
    var position = simd_float3(0, 0, 0)
    var orientation = simd_quatf(angle: 0, axis: simd_float3(0,1,0))
    var forward: simd_float3 { orientation.act(simd_float3(0,0,1)) }
    var right: simd_float3 { orientation.act(simd_float3(1,0,0)) }
    var up: simd_float3 { orientation.act(simd_float3(0,1,0)) }

    mutating func rotate(yaw: Float, pitch: Float) {
        let yawQuat = simd_quatf(angle: yaw, axis: simd_float3(0,1,0))
        let rightAxis = self.right
        let pitchQuat = simd_quatf(angle: pitch, axis: rightAxis)
        orientation = simd_normalize(pitchQuat * yawQuat * orientation)
    }
}