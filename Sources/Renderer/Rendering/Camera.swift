import simd

public struct Camera: @unchecked Sendable {
    public var position = simd_float3(0, 0, 0)
    public var orientation = simd_quatf(angle: 0, axis: simd_float3(0,1,0))
    public var forward: simd_float3 { orientation.act(simd_float3(0,0,1)) }
    public var right: simd_float3 { orientation.act(simd_float3(1,0,0)) }
    public var up: simd_float3 { orientation.act(simd_float3(0,1,0)) }
    public var moveSpeed: Float = 40.0
    public var rotateSpeed: Float = 2.0
    public var mouseSensivity: Float = 16.0

    mutating func rotate(yaw: Float, pitch: Float) {
        let yawQuat = simd_quatf(angle: yaw, axis: simd_float3(0,1,0))
        let rightAxis = self.right
        let pitchQuat = simd_quatf(angle: pitch, axis: rightAxis)
        orientation = simd_normalize(pitchQuat * yawQuat * orientation)
    }
}