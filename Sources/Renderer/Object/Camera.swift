import simd

class Camera : Object {
    var position: simd_float3
    var orientation: simd_quatf

    var forward: simd_float3 { orientation.act(simd_float3(0, 0, 1)) }
    var right:   simd_float3 { orientation.act(simd_float3(1, 0, 0)) }
    var up:      simd_float3 { orientation.act(simd_float3(0, 1, 0)) }

    var moveSpeed: Float = 40.0
    // TODO: make it read these settings from a config-file
    var rotateSpeed:    Float = 2.0
    var mouseSensivity: Float = 16.0
    var fov:   Float = 90.0 // Field of View
    var zNear: Float = 0.1 // Near Clipping Plane
    var zFar:  Float = 10000.0 // Far Clipping Plane

    var viewMatrix: simd_float4x4 {
        simd_float4x4(columns: (
            [right.x,               up.x,               forward.x,               0],
            [right.y,               up.y,               forward.y,               0],
            [right.z,               up.z,               forward.z,               0],
            [-dot(right, position), -dot(up, position), -dot(forward, position), 1],
        ))
    }

    init(
        name: String            = "Default Camera",
        parent: Object?         = nil,
        position: simd_float3   = simd_float3(0, 0, 0), 
        orientation: simd_quatf = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
    ) {
        self.position = position
        self.orientation = orientation
        super.init(name: name, parent: parent)
    }

    func rotate(yaw: Float, pitch: Float) {
        let yawQuat    = simd_quatf(angle: yaw, axis: simd_float3(0,1,0))
        let rightAxis = self.right
        let pitchQuat  = simd_quatf(angle: pitch, axis: rightAxis)
        orientation = simd_normalize(pitchQuat * yawQuat * orientation)
    }

    func makeOrientation(from eulerDegrees: simd_float3) {
        let radians = eulerDegrees * (.pi / 180.0)
        let pitch = simd_quatf(angle: radians.x, axis: simd_float3(1, 0, 0))
        let yaw   = simd_quatf(angle: radians.y, axis: simd_float3(0, 1, 0))
        let roll  = simd_quatf(angle: radians.z, axis: simd_float3(0, 0, 1))
        orientation = simd_normalize(yaw * pitch * roll)
    }
}