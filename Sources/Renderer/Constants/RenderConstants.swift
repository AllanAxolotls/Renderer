enum RasterizerConstants {
    static let defaultFov: Float = 90.0
    static let defaultZNear: Float = 0.1
    static let defaultZFar: Float = 1000.0
    static let logMeshCounts: Bool = false
}

enum RayTracerConstants {
    //! must all match RayTracer.metal in function 'raytrace': [[buffer(...)]]
    static let uniformsBufferIndex     : Int = 0
    static let meshTriBufferIndex      : Int = 1
    static let materialBufferIndex     : Int = 2
    static let textureBufferIndex      : Int = 3
    static let blasNodeBufferIndex     : Int = 4
    static let tlasInstanceBufferIndex : Int = 5
    static let tlasNodeBufferIndex     : Int = 6
       
    static let samplesPerPixel        : Int  = 5
    static let maxLightBounces        : Int  = 4
    static let maxTextureCount        : Int  = 128 //! must match RayTracer.metal TextureCollection
    static let maxSampleCount         : Int  = 1000
    static let renderOnCPU            : Bool = false
    static let saveAndExitOnCPURender : Bool = true
    static let cpuImageWidth          : Int  = 1920/4
    static let cpuImageHeight         : Int  = 1080/4

    typealias BlasNode = Blas2Node
    typealias TlasNode = Tlas4Node
}