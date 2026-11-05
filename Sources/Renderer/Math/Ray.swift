import simd

public struct Ray {
    var origin: simd_float3
    var direction: simd_float3 { didSet { invDirection = 1.0 / direction } }
    private(set) var invDirection: simd_float3 = simd_float3()

    init(origin: simd_float3, direction: simd_float3) {
        self.origin = origin
        self.direction = direction
        self.invDirection = 1.0 / direction
    }
}