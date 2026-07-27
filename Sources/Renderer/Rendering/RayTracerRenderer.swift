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

/*
private func toByte(_ x: Float) -> UInt8 {
    let safe = x.isNaN || x.isInfinite ? 0 : x
    let clamped = min(max(safe, 0), 255)
    return UInt8(clamped)
}

private func calculateShadow(origin: simd_float3, direction: simd_float3, result: RaycastResult, bvh: BVH) -> Float {
    let direction = simd_float3(0, 1, 0)
    //let filter: [Triangle] = [result.hitFace]
    // SHOULD BE NOT BACKCULLED and should have a filter with result.hit!
    let tempResult: RaycastResult? = bvh.traverse(ray: Ray(origin: result.hit, direction: direction))
    if tempResult == nil { return 0 }
    return 0.5
}

private func raycastPixel(
    pixelX: Int, pixelY: Int, scene: Scene, 
    width: Int, height: Int,
    camera: Camera,
    aspectRatio: Float, fovScale: Float) -> simd_float4 
{
    let ndcX: Float = ((Float(pixelX) + 0.5) / Float(width)) * 2.0 - 1.0
    let ndcY: Float = 1.0 - ((Float(pixelY) + 0.5) / Float(height)) * 2.0

    let projectedX: Float = ndcX * aspectRatio * fovScale
    let projectedY: Float = ndcY * fovScale

    /*
    let localLook = simd_normalize(simd_float3(projectedX, projectedY, 1))
    let look = simd_normalize(cameraRotation.act(localLook))
    */
    let look = normalize(
        camera.forward +
        projectedX * camera.right +
        projectedY * camera.up
    )

    //let result: RaycastResult? = traverseBVH(node: BVH, origin: origin, direction: look)
    let bvh = scene.bvh!
    guard let result: RaycastResult = bvh.traverse(ray: Ray(origin: camera.position, direction: look)) else {
        let horizonColor = simd_float3(207, 219, 230)
        let zenithColor = simd_float3(60, 138, 201)

        let t: Float = 0.5 * (look.y + 1.0)
        let color: simd_float3 = (1.0 - t) * horizonColor + t * zenithColor
        return simd_float4(color.x, color.y, color.z, 255)
    }

    let darkness: Float = calculateShadow(origin: camera.position, direction: look, result: result, bvh: bvh)
    //let darkness: Float = shadowArtifact(origin: origin, direction: look, result: result, BVH: BVH)

    //let vertex1 = result.hitFace.vertex1
    //let vertex2 = result.hitFace.vertex2
    //let vertex3 = result.hitFace.vertex3
    //let normal1 = vertex1.normal
    //let normal2 = vertex2.normal
    //let normal3 = vertex3.normal
    
    //let uv1 = vertex1.uv
    //let uv2 = vertex2.uv
    //let uv3 = vertex3.uv
    
    //let interpolatedNormal: simd_float3 = simd_normalize(
    //    result.barycentric.x * normal1 +
    //    result.barycentric.y * normal2 +
    //    result.barycentric.z * normal3
    //)
   // let lightAngle = simd_float3(0, -1, 0)
    //let lightIntensity: Float = (1 - (simd_dot(lightAngle, interpolatedNormal) + 1) * 0.25) + 0.5 // Added 0.5 for sunlight
    
    let lightIntensity: Float = max(1.25 - darkness, 0)

    //let interpolatedUV: simd_float2 = result.barycentric.x * uv1 + result.barycentric.y * uv2 + result.barycentric.z * uv3
    
    //let subMesh: SubMesh = scene.subMeshes[Int(result.hitFace.subMeshIndex)]
    let material: Material = scene.materials[Int(result.hitFace.materialIndex)]
    
    //let map_Ka: MTLTexture? = material?.diffuseTexture
    let textureColor: simd_float4? = nil// map_Ka?.sample(u: interpolatedUV.x, v: interpolatedUV.y)
    let Ka = material.diffuseColor
    let materialColor: simd_float4 = simd_float4(Ka.x * 255, Ka.y * 255, Ka.z * 255, 255)

    let diffuseColor: simd_float4 = textureColor ?? materialColor
    return simd_float4(diffuseColor.x * lightIntensity, diffuseColor.y * lightIntensity, diffuseColor.z * lightIntensity, diffuseColor.w)
}

// MARK: - Raytracer
@MainActor private func raycastData(scene: Scene, width: Int, height: Int, camera: Camera) -> Data {
    let aspectRatio: Float = Float(width) / Float(height)
    let fovScale: Float = tan(FOVRad * 0.5)
    
    var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { rawBuffer in

        let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!

        DispatchQueue.concurrentPerform(iterations: height) { pixelY in
            let pixelYTimesWidthTimes4 = pixelY * width * 4
            for pixelX in 0..<width {
                let color = raycastPixel(
                    pixelX: pixelX, pixelY: pixelY, scene: scene, 
                    width: width, height: height, 
                    camera: camera,
                    aspectRatio: aspectRatio, fovScale: fovScale 
                )
                let i: Int = pixelYTimesWidthTimes4 + pixelX * 4
                ptr[i]      = toByte(color.x)
                ptr[i + 1]  = toByte(color.y)
                ptr[i + 2]  = toByte(color.z)
                ptr[i + 3]  = toByte(color.w)
            }

            if printCPUProgressEveryRow { print("Row \(pixelY + 1) complete") }
        }
    }

    return Data(pixels)
}

@MainActor private func calculateImageCPU(scene: Scene) {
    let (cGWidth, cGHeight) = getScreenSize()
    let width = Int(cGWidth)
    let height = Int(cGHeight)
    let pixels = raycastData(scene: scene, width: width, height: height, camera: scene.camera)
    if let image = createImage(width: width, height: height, pixelData: pixels) {
        saveImageToDesktop(image)
    } else {
        print("Failed to create image.")
    }
    exit(0)
}*/

final class RayTracerRenderer: Renderer {
    // Image Creation here
    var device: MTLDevice!
    var scene: Scene?
    var pipelineBuilder: PipelineBuilder!
    var raytraceState: MTLComputePipelineState!
    var upscalePipeline: MTLRenderPipelineState!
    var fullscreenSampler: MTLSamplerState!

    let uniformsBuffer: MTLBuffer!
    var materialBuffer: MTLBuffer? = nil
    var tlasNodeBuffer: MTLBuffer? = nil
    var tlasInstanceBuffer: MTLBuffer? = nil
    var blasNodeBuffer: MTLBuffer? = nil
    var faceBuffer: MTLBuffer? = nil
    var vertexAttributesBuffer: MTLBuffer? = nil

    var argumentEncoder: MTLArgumentEncoder!
    var argumentBuffer: MTLBuffer!

    var rayOutputTexture: MTLTexture? = nil
    var accumTexture: MTLTexture? = nil

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

    // Connections
    var sceneTexturesAddedConnection: AnyCancellable? = nil
    var sceneTLASReformedConnection: AnyCancellable? = nil
    var sceneTLASRebuiltConnection: AnyCancellable? = nil

    init (device: MTLDevice, scene: Scene?) {
        self.device = device
        self.pipelineBuilder = PipelineBuilder(device: device)
        (self.raytraceState, self.upscalePipeline, argumentEncoder, argumentBuffer) = self.pipelineBuilder.makeRayTracePipeline(textures: scene?.textures ?? [])

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        fullscreenSampler = device.makeSamplerState(descriptor: sampDesc)

        var uniforms = RayTracerUniforms(
            sampleIndex: sampleIndex,
            fovScale: tan(FOVRad * 0.5), 
            cameraPosition: scene?.camera.position ?? simd_float3(0, 0, 0),
            cameraForward: scene?.camera.forward ?? simd_float3(0, 0, 1), 
            cameraUp: scene?.camera.up ?? simd_float3(0, 1, 0),
            cameraRight: scene?.camera.right ?? simd_float3(1, 0, 0)
        )

        uniformsBuffer = device.makeBuffer(bytes: &uniforms, length: MemoryLayout<RayTracerUniforms>.stride)

        setScene(scene)
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
        //lastCameraPosition = simd_float3(repeating: .infinity)
        //lastCameraForward = simd_float3(repeating: .infinity)
        //lastCameraUp = simd_float3(repeating: .infinity)
    }

    public func updateTLASBuffers() {
        guard let scene = scene, let tlas = scene.tlas else { return }
        updateBuffer(&tlasInstanceBuffer, with: tlas.tlasInstances)
        updateBuffer(&tlasNodeBuffer, with: tlas.tlasNodes)
        invalidateAccumulation()
    }

    public func updateBLASBuffers() {
        guard let scene = scene, let tlas = scene.tlas else { return }
        updateBuffer(&materialBuffer, with: scene.materials)
        updateBuffer(&blasNodeBuffer, with: tlas.blasNodes)
        updateBuffer(&faceBuffer, with: tlas.faces)
        updateVertexAttributesBuffer(vertices: scene.vertices)
    }

    private func updateBuffer<T>(
        _ buffer: inout MTLBuffer?,
        with elements: [T],
        options: MTLResourceOptions = .storageModeShared
    ) {
        guard !elements.isEmpty else { return }
        let requiredBytes = MemoryLayout<T>.stride * elements.count

        if let existing = buffer, existing.length >= requiredBytes && existing.length <= requiredBytes * 2 {
            let _ = elements.withUnsafeBufferPointer { ptr in
                memcpy(existing.contents(), ptr.baseAddress!, requiredBytes)
            }
        } else {
            let targetCapacity = Int(Double(requiredBytes) * 1.25)
            guard let newBuffer = device.makeBuffer(length: targetCapacity, options: options) else { buffer = nil; return }

            let _ = elements.withUnsafeBufferPointer { ptr in
                memcpy(newBuffer.contents(), ptr.baseAddress!, requiredBytes)
            }
            
            buffer = newBuffer
        }
    }

    private func updateVertexAttributesBuffer(vertices: [Vertex]) {
        guard !vertices.isEmpty else { vertexAttributesBuffer = nil; return }
        let requiredBytes = MemoryLayout<RayTraceVertexAttributes>.stride * vertices.count

        if let existing = vertexAttributesBuffer, existing.length >= requiredBytes && existing.length <= requiredBytes * 2 {
            let dest = existing.contents().bindMemory(to: RayTraceVertexAttributes.self, capacity: vertices.count)
            for (index, v) in vertices.enumerated() {
                dest[index] = RayTraceVertexAttributes(normal: v.normal, uv: v.uv)
            }
            return
        }

        let attributes = vertices.map { RayTraceVertexAttributes(normal: $0.normal, uv: $0.uv) }
        let targetCapacity = Int(Double(requiredBytes) * 1.25)

        guard let newBuffer = device.makeBuffer(length: targetCapacity, options: .storageModeShared) else { return }
        let _ = attributes.withUnsafeBufferPointer { ptr in
            memcpy(newBuffer.contents(), ptr.baseAddress!, requiredBytes)
        }

        self.vertexAttributesBuffer = newBuffer
    }

    public func updateArgumentBuffer() {
        guard let scene = scene else { return }
        argumentEncoder.setTextures(scene.textures, range: 1 ..< scene.textures.count + 1)
    }

    public func setScene(_ newScene: Scene?) {
        if (self.scene != nil) {
            // Disconnect Subscriptions
            if let connection = sceneTexturesAddedConnection    { connection.cancel() }
            if let connection = sceneTLASReformedConnection     { connection.cancel() }
            if let connection = sceneTLASRebuiltConnection     { connection.cancel() }
            
            sceneTexturesAddedConnection = nil
            sceneTLASReformedConnection = nil
            sceneTLASRebuiltConnection = nil
        }

        self.scene = newScene

        // Create new subscriptions
        guard let newScene = newScene else { return }
        sceneTexturesAddedConnection  = newScene.texturesAdded.sink  { [weak self] in self?.updateArgumentBuffer() }
        sceneTLASReformedConnection   = newScene.tlasReformed.sink   { [weak self] in self?.updateTLASBuffers()    }
        sceneTLASRebuiltConnection    = newScene.tlasRebuilt.sink    { [weak self] in
            self?.updateArgumentBuffer()
            self?.updateTLASBuffers()
            self?.updateBLASBuffers()
        }
        // TODO: think of reasons why updateBLASBuffers() should be called (When faces get added for example, submeshes too!)

        updateArgumentBuffer()
        updateTLASBuffers()
        updateBLASBuffers()
    }

    func draw(view: MTKView, commandQueue: MTLCommandQueue) {
        if raytraceOnCPU {
            print("CPU drawing is unavailable right now")
            //calculateImageCPU(scene: scene)
            exit(1)
        }

        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }

            let camera: Camera? = scene?.camera
            let P = camera?.position    ?? simd_float3(0, 0, 0)
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
            if (flushTextures && !raytracingPaused) {
                createRayTexture(
                    width: drawable.texture.width / outputWidthDivisor, 
                    height: drawable.texture.height / outputHeightDivisor
                )
            }

            // Camera did not move and max samples reached so stop new GPU processing
            let skipRaytracing: Bool = (sampleIndex >= maxSamples) || raytracingPaused
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

                let encoder = commandBuffer.makeComputeCommandEncoder()!

                var uniforms = RayTracerUniforms(
                    sampleIndex: sampleIndex,
                    fovScale: tan(FOVRad * 0.5), 
                    cameraPosition: P,
                    cameraForward: F, 
                    cameraUp: U,
                    cameraRight: R
                )
                memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<RayTracerUniforms>.stride)

                encoder.setComputePipelineState(self.raytraceState)
                // before: drawable.texture
                encoder.setTexture(rayOutputTexture, index: 0)
                encoder.setTexture(accumTexture, index: 1)
                encoder.setTexture(accumTexture, index: 2)
                
                encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)
                encoder.setBuffer(materialBuffer, offset: 0, index: 1)
                encoder.setBuffer(tlasNodeBuffer, offset: 0, index: 2)
                encoder.setBuffer(tlasInstanceBuffer, offset: 0, index: 3)
                encoder.setBuffer(blasNodeBuffer, offset: 0, index: 4)
                encoder.setBuffer(faceBuffer, offset: 0, index: 5)
                encoder.setBuffer(argumentBuffer, offset: 0, index: 6)
                encoder.setBuffer(vertexAttributesBuffer, offset: 0, index: 7)

                if let scene = scene {
                    for texture in scene.textures { encoder.useResource(texture, usage: .sample) }
                }

                let width = raytraceState.threadExecutionWidth
                let height = raytraceState.maxTotalThreadsPerThreadgroup / width
                let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
                let threadsPerGrid = MTLSize(width: rayOutputTexture!.width, height: rayOutputTexture!.height, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()

                commandBuffer.addCompletedHandler { [weak self] cb in
                    guard let self = self else { return }  
                    let durationMS = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                    Task { @MainActor in self.lastFrameDuration = durationMS }
                }

                sampleIndex += 1
            } else {
                if let window = view.window {
                    if raytracingPaused {
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

            commandBuffer.present(drawable)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            // If save, save drawable texture as png to desktop when maxSamples reached and exit program
            if saveAndExitOnGPU && sampleIndex >= maxSamples {
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