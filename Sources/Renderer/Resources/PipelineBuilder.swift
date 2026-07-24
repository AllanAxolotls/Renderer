import Metal

final class PipelineBuilder {
    let device: MTLDevice
    var sampler: MTLSamplerState!

    init(device: MTLDevice) {
        self.device = device
    }

    func makeRasterPipeline() -> MTLRenderPipelineState {
        let url = URL(fileURLWithPath: "Resources/Rasterizer.metallib")
        let lib = try! device.makeLibrary(URL: url)

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        configureBlending(desc)

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .repeat
        sampDesc.tAddressMode = .repeat
        sampler = device.makeSamplerState(descriptor: sampDesc)!

        return try! device.makeRenderPipelineState(descriptor: desc)
    }

    func makeRayTracePipeline(textures: [MTLTexture]) -> (MTLComputePipelineState, MTLBuffer) {
        let url = URL(fileURLWithPath: "Resources/Raytracer.metallib")
        let lib = try! device.makeLibrary(URL: url)
        let function = lib.makeFunction(name: "raytrace")!
        let argumentEncoder = function.makeArgumentEncoder(bufferIndex: 6)

        let textureCount = textures.count
        // TODO: make this variable, instead of stuck
        print("Texture Count: \(textureCount)")
        let bufferLength = argumentEncoder.encodedLength + (textureCount * MemoryLayout<UInt64>.size)
        let argumentBuffer = device.makeBuffer(length: bufferLength, options: [])!
        argumentEncoder.setArgumentBuffer(argumentBuffer, offset: 0)
        argumentEncoder.setSamplerState(sampler, index: 0)
        argumentEncoder.setTextures(textures, range: 1 ..< textureCount + 1)
        return (
            try! device.makeComputePipelineState(function: function), 
            argumentBuffer
        )
    }

    private func configureBlending(_ desc: MTLRenderPipelineDescriptor) {
        let attachment = desc.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
}
