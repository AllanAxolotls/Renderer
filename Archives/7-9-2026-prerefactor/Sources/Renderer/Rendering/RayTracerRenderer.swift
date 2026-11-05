import MetalKit
import ImageIO
import UniformTypeIdentifiers
import Combine

// TODO: move these to a config file
private let outputImageName = "output.png"
private let raytraceOnCPU: Bool = false // If true, the CPU does the raytracing of one frame and saves it as outputImageName, then exits the program immediately
private let saveAndExitOnGPU: Bool = false // If true, one frame gets saved of the raytracer as the outputImageName and then the program immediately exits
private let maxSamples: Int32 = 1000
private let printCPUProgressEveryRow: Bool = true

@MainActor final class RayTracerRenderer {
    // Image Creation here
    var device: MTLDevice!
    public var scene: Scene?
    var pipelineBuilder: PipelineBuilder!
    var raytraceState: MTLComputePipelineState!
    var upscalePipeline: MTLRenderPipelineState!
    var fullscreenSampler: MTLSamplerState!

    let uniformsBuffer: MTLBuffer!
    var reorderedIndexBuffer: MTLBuffer? = nil
    var triangleMaterialMapBuffer: MTLBuffer? = nil
    var materialDataBuffer: MTLBuffer? = nil
    var argumentEncoder: MTLArgumentEncoder!
    var textureCollectionBuffer: MTLBuffer!

    var tlasNodeBuffer: MTLBuffer? = nil
    var tlasInstanceBuffer: MTLBuffer? = nil
    var blasNodeBuffer: MTLBuffer? = nil

    var rayOutputTexture: MTLTexture? = nil
    var accumTexture: MTLTexture? = nil

    var frameCompleted: Bool = true
    var isPaused: Bool = false
    var lastCameraPosition: simd_float3 = simd_float3(.infinity, .infinity, .infinity)
    var lastCameraForward: simd_float3 = simd_float3(.infinity, .infinity, .infinity)
    var lastCameraUp: simd_float3 = simd_float3(.infinity, .infinity, .infinity)
    var lastWidth: Int = -1 // drawable.texture.width
    var lastHeight: Int = -1 // drawable.texture.height
    var sampleIndex: Int32 = 0
    private(set) var lastFrameDuration: Double = 0
    private var lastTitleUpdateTimestamp: CFAbsoluteTime = 0.0
    private let titleUpdateInterval: CFAbsoluteTime = 0.25 // Update max 4 times/sec

    var outputWidthDivisor: Int = 1
    var outputHeightDivisor: Int = 1

    init (device: MTLDevice, scene: Scene? = nil) {
        self.device = device
        self.scene = scene
        self.pipelineBuilder = PipelineBuilder(device: device)
        (self.raytraceState, self.upscalePipeline, argumentEncoder, textureCollectionBuffer) = self.pipelineBuilder.makeRayTracePipeline(textures: scene?.textureHandler?.textures ?? [])

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        fullscreenSampler = device.makeSamplerState(descriptor: sampDesc)

        var uniforms = RayTracerUniforms(
            sampleIndex: sampleIndex,
            tileOffset: simd_uint2(0, 0),
            fovScale: tan(((scene?.camera.fov ?? 90) * .pi / 180) * 0.5), 
            cameraPosition: scene?.camera.position ?? simd_float3(0, 0, 0),
            cameraForward: scene?.camera.forward ?? simd_float3(0, 0, 1), 
            cameraUp: scene?.camera.up ?? simd_float3(0, 1, 0),
            cameraRight: scene?.camera.right ?? simd_float3(1, 0, 0),
        )

        uniformsBuffer = device.makeBuffer(bytes: &uniforms, length: MemoryLayout<RayTracerUniforms>.stride)
    }

    func createRayTexture(width: Int, height: Int) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )

        desc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        desc.storageMode = .private
        rayOutputTexture = device.makeTexture(descriptor: desc)

        let accumDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )

        accumDesc.usage = [.shaderWrite, .shaderRead]
        accumDesc.storageMode = .private
        accumTexture = device.makeTexture(descriptor: accumDesc)
    }

    func invalidateAccumulation() {
        sampleIndex = 0
    }

    // SHARED versions
    public func updateTLASBuffers() {
        guard let scene = scene else { return }
        updateBuffer(device: device, &tlasInstanceBuffer, with: scene.tlas.tlasInstances)
        updateBuffer(device: device, &tlasNodeBuffer, with: scene.tlas.tlasNodes)
        invalidateAccumulation()
    }
    public func updateBLASBuffers() {
        guard let scene = scene else { return }
        updateBuffer(device: device, &reorderedIndexBuffer, with: scene.tlas.reorderedIndices)
        updateBuffer(device: device, &triangleMaterialMapBuffer, with: scene.tlas.triangleMaterialMap)
        updateBuffer(device: device, &blasNodeBuffer, with: scene.tlas.blasNodes)
    }
    public func updateMaterialDataBuffer() {
        guard let scene = scene else { return }
        updateBuffer(device: device, &materialDataBuffer, with: scene.materialDatas)
    }

    // PRIVATE versions
    public func updateTLASBuffers(_ commandQueue: MTLCommandQueue) {
        guard let scene = scene else { return }
        tlasInstanceBuffer = uploadPrivate(scene.tlas.tlasInstances, device: device, commandQueue: commandQueue)
        tlasNodeBuffer = uploadPrivate(scene.tlas.tlasNodes, device: device, commandQueue: commandQueue)
        invalidateAccumulation()
    }
    public func updateBLASBuffers(_ commandQueue: MTLCommandQueue) {
        guard let scene = scene else { return }
        reorderedIndexBuffer = uploadPrivate(scene.tlas.reorderedIndices, device: device, commandQueue: commandQueue)
        triangleMaterialMapBuffer = uploadPrivate(scene.tlas.triangleMaterialMap, device: device, commandQueue: commandQueue)
        blasNodeBuffer = uploadPrivate(scene.tlas.blasNodes, device: device, commandQueue: commandQueue)
    }
    public func updateMaterialDataBuffer(_ commandQueue: MTLCommandQueue) {
        guard let scene = scene else { return }
        materialDataBuffer = uploadPrivate(scene.materialDatas, device: device, commandQueue: commandQueue)
    }

    public func updateTextureCollectionBuffer() {
        guard let scene = scene else { return }
        guard let textureHandler = scene.textureHandler else { return }
        argumentEncoder.setTextures(textureHandler.textures, range: 1 ..< textureHandler.textures.count + 1)
    }

    func draw(view: MTKView, commandQueue: MTLCommandQueue, vertexBuffer: MTLBuffer?) {
        if raytraceOnCPU {
            print("CPU drawing is unavailable right now")
            //calculateImageCPU(scene: scene)
            exit(1)
        }

        if !frameCompleted { return }

        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }

            let camera: Camera? = scene?.camera
            let P: simd_float3 = camera?.position    ?? simd_float3(0, 0, 0)
            let R = camera?.right       ?? simd_float3(1, 0, 0)
            let U = camera?.up          ?? simd_float3(0, 1, 0)
            let F = camera?.forward     ?? simd_float3(0, 0, 1)
            
            func posNearlyEq(_ a: simd_float3, _ b: simd_float3) -> Bool { return simd_length(a - b) < 0.001 }
            var cameraChanged: Bool = false
            if !posNearlyEq(P, lastCameraPosition) || !posNearlyEq(F, lastCameraForward) || !posNearlyEq(U, lastCameraUp) {
                lastCameraPosition = P
                lastCameraForward = F
                lastCameraUp = U
                cameraChanged = true
            }
            let windowResolutionChanged = lastWidth != drawable.texture.width || lastHeight != drawable.texture.height 
            if windowResolutionChanged {
                lastWidth = drawable.texture.width
                lastHeight = drawable.texture.height
            }

            if cameraChanged || windowResolutionChanged { sampleIndex = 0 }
            let flushTextures: Bool = sampleIndex == 0 || windowResolutionChanged
            if (flushTextures && !isPaused) {
                createRayTexture(
                    width: drawable.texture.width / outputWidthDivisor, 
                    height: drawable.texture.height / outputHeightDivisor
                )
            }

            // Camera did not move and max samples reached so stop new GPU processing
            let skipRaytracing: Bool = (sampleIndex >= maxSamples) || isPaused
            if (!skipRaytracing) {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastTitleUpdateTimestamp >= titleUpdateInterval {
                    lastTitleUpdateTimestamp = now
                    
                    if let window = view.window {
                        let title = String(format: "[ Raytracer - Sampling (%d / %d) | GPU: %.2f ms ]", 
                                                    self.sampleIndex, maxSamples, self.lastFrameDuration)
                        DispatchQueue.main.async { window.title = title }
                    }
                }
               
                var uniforms = RayTracerUniforms(
                    sampleIndex: sampleIndex,
                    tileOffset: simd_uint2(0, 0),
                    fovScale: tan(((scene?.camera.fov ?? 90) * .pi / 180) * 0.5), 
                    cameraPosition: P,
                    cameraForward: F, 
                    cameraUp: U,
                    cameraRight: R,
                    
                )

                let tileSize = 128

                let imageWidth = rayOutputTexture!.width
                let imageHeight = rayOutputTexture!.height

                for tileY in stride(from: 0, to: imageHeight, by: tileSize) {
                    for tileX in stride(from: 0, to: imageWidth, by: tileSize) {

                        let tileWidth = min(tileSize, imageWidth - tileX)
                        let tileHeight = min(tileSize, imageHeight - tileY)

                        let tileCommandBuffer = commandQueue.makeCommandBuffer()!     

                        uniforms.tileOffset = simd_uint2(
                            UInt32(tileX),
                            UInt32(tileY)
                        )

                        let encoder = tileCommandBuffer.makeComputeCommandEncoder()!
                        let tileUniformBuffer = device.makeBuffer(
                            bytes: &uniforms,
                            length: MemoryLayout<RayTracerUniforms>.stride
                        )!

                        
                        encoder.setComputePipelineState(raytraceState)

                        encoder.setTexture(rayOutputTexture, index: 0)
                        encoder.setTexture(accumTexture, index: 1)
                        encoder.setTexture(accumTexture, index: 2)

                        encoder.setBuffer(tileUniformBuffer, offset: 0, index: 0)
                        encoder.setBuffer(vertexBuffer, offset: 0, index: 1)
                        encoder.setBuffer(reorderedIndexBuffer, offset: 0, index: 2)
                        encoder.setBuffer(triangleMaterialMapBuffer, offset: 0, index: 3)
                        encoder.setBuffer(materialDataBuffer, offset: 0, index: 4)
                        encoder.setBuffer(textureCollectionBuffer, offset: 0, index: 5)
                        encoder.setBuffer(tlasNodeBuffer, offset: 0, index: 6)
                        encoder.setBuffer(tlasInstanceBuffer, offset: 0, index: 7)
                        encoder.setBuffer(blasNodeBuffer, offset: 0, index: 8)

                        for texture in scene?.textureHandler?.textures ?? [] {
                            encoder.useResource(texture, usage: .sample)
                        }

                        let threadsPerThreadgroup = MTLSize(
                            width: raytraceState.threadExecutionWidth,
                            height: raytraceState.maxTotalThreadsPerThreadgroup / raytraceState.threadExecutionWidth,
                            depth: 1
                        )

                        encoder.dispatchThreads(
                            MTLSize(
                                width: tileWidth,
                                height: tileHeight,
                                depth: 1
                            ),
                            threadsPerThreadgroup: threadsPerThreadgroup
                        )

                        encoder.endEncoding()
                        tileCommandBuffer.commit()
                    }
                }

                sampleIndex += 1
            } else {
                if let window = view.window {
                    if isPaused {
                        window.title = "[ Raytracer - Paused (\(sampleIndex) / \(maxSamples)) ]"
                    } else if sampleIndex >= maxSamples {
                        window.title = "[ Raytracer - Finished (\(sampleIndex) / \(maxSamples)) ]"
                    }
                }
            }

            let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
            renderEncoder.setRenderPipelineState(upscalePipeline)
            renderEncoder.setFragmentTexture(rayOutputTexture, index: 0)
            renderEncoder.setFragmentSamplerState(fullscreenSampler, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renderEncoder.endEncoding()

            frameCompleted = false
            commandBuffer.addCompletedHandler { [weak self] _ in
                Task { @MainActor in
                    self?.frameCompleted = true
                }
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
            /*
            commandBuffer.waitUntilCompleted()
            lastFrameDuration = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
            print(commandBuffer.status.rawValue)

            if let error = commandBuffer.error {
                print(error)
                exit(1)
            }
            */

            // If save, save drawable texture as png to desktop when maxSamples reached and exit program
            
            if saveAndExitOnGPU && sampleIndex >= maxSamples {
                print("CURRENTLY SAVING IMAGES IS UNSUPPORTED!")
                exit(0)

                //commandBuffer.waitUntilCompleted()
                let output = drawable.texture
                let bytesPerPixel = 4
                let bytesPerRow = output.width * bytesPerPixel

                var pixels = [UInt8](repeating: 0, count: output.height * bytesPerRow)
                output.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, output.width, output.height), mipmapLevel: 0)

                let (cGWidth, cGHeight) = getScreenSize()
                let width = Int(cGWidth)
                let height = Int(cGHeight)
                if let image = createImage(width: width, height: height, pixelData: Data(pixels)) {
                    saveImageToDesktop(name: outputImageName, image)
                } else {
                    print("Failed to create image.")
                }
                exit(0)
            }
        }
    }
}