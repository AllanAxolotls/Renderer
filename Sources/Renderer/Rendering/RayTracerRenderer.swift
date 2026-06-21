import MetalKit
import ImageIO
import UniformTypeIdentifiers

let outputImageName = "output.png"
let raytraceOnCPU: Bool = false // If true, the CPU does the raytracing of one frame and saves it as outputImageName, then exits the program immediately
let saveAndExitOnGPU: Bool = false // If true, one frame gets saved of the raytracer as the outputImageName and then the program immediately exits
let maxSamples: Int32 = 100
let printCPUProgressEveryRow: Bool = true

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
    
    //let map_Ka: MTLTexture? = material?.ambientTexture
    let textureColor: simd_float4? = nil// map_Ka?.sample(u: interpolatedUV.x, v: interpolatedUV.y)
    let Ka = material.ambientColor
    let materialColor: simd_float4 = simd_float4(Ka.x * 255, Ka.y * 255, Ka.z * 255, 255)

    let ambientColor: simd_float4 = textureColor ?? materialColor
    return simd_float4(ambientColor.x * lightIntensity, ambientColor.y * lightIntensity, ambientColor.z * lightIntensity, ambientColor.w)
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
    var scene: Scene
    var pipelineBuilder: PipelineBuilder!
    var pipeline: MTLComputePipelineState!

    let uniformsBuffer: MTLBuffer!
    var materialBuffer: MTLBuffer!
    var tlasNodeBuffer: MTLBuffer!
    var tlasInstanceBuffer: MTLBuffer!
    var blasNodeBuffer: MTLBuffer!
    var faceBuffer: MTLBuffer!
    var argumentBuffer: MTLBuffer!

    var accumTexture: MTLTexture? = nil
    var lastCameraPosition: simd_float3 = simd_float3(.infinity, .infinity, .infinity)
    var lastCameraForward: simd_float3 = simd_float3(.infinity, .infinity, .infinity)
    var lastCameraUp: simd_float3 = simd_float3(.infinity, .infinity, .infinity)
    var lastWidth: Int = -1 // drawable.texture.width
    var lastHeight: Int = -1 // drawable.texture.height
    var sampleIndex: Int32 = 0

    init (device: MTLDevice, scene: Scene) {
        self.device = device
        self.scene = scene
        self.pipelineBuilder = PipelineBuilder(device: device)
        (self.pipeline, argumentBuffer) = self.pipelineBuilder.makeRayTracePipeline(textures: scene.textures)

        var uniforms = Uniforms(
            sampleIndex: sampleIndex,
            fovScale: tan(FOVRad * 0.5), 
            cameraPosition: scene.camera.position,
            cameraForward: scene.camera.forward, 
            cameraUp: scene.camera.up,
            cameraRight: scene.camera.right
        )

        var facesToGPU: [RayTraceTriangleGPU] = []
        func faceToGPU(_ face: Face) -> RayTraceTriangleGPU {
            let subMesh = scene.subMeshes[Int(face.subMeshIndex)]
            let vertex1 = scene.vertices[Int(face.vertexIndices.x)]
            let vertex2 = scene.vertices[Int(face.vertexIndices.y)]
            let vertex3 = scene.vertices[Int(face.vertexIndices.z)]
            let edge1 = vertex2.position - vertex1.position
            let edge2 = vertex3.position - vertex1.position
            return RayTraceTriangleGPU(
                vertex1: vertex1, vertex2: vertex2, vertex3: vertex3, 
                edge1: edge1, edge2: edge2,
                normal: simd_normalize(simd_cross(edge1, edge2)),
                materialIndex: subMesh.materialIndex
            )
        }
        for face in scene.faces { facesToGPU.append(faceToGPU(face)) }

        uniformsBuffer = device.makeBuffer(bytes: &uniforms, length: MemoryLayout<Uniforms>.stride)

        scene.materials.withUnsafeBufferPointer { ptr in 
            self.materialBuffer = device.makeBuffer(bytes: ptr.baseAddress!, length: MemoryLayout<Material>.stride * scene.materials.count)
        }
        scene.tlas!.tlasNodes.withUnsafeBufferPointer { ptr in
            self.tlasNodeBuffer = device.makeBuffer(bytes: ptr.baseAddress!, length: MemoryLayout<TLASNode>.stride * scene.tlas!.tlasNodes.count)
        }
        scene.tlas!.tlasInstances.withUnsafeBufferPointer { ptr in
            self.tlasInstanceBuffer = device.makeBuffer(bytes: ptr.baseAddress!, length: MemoryLayout<TLASInstance>.stride * scene.tlas!.tlasInstances.count)
        }
        scene.tlas!.blasNodes.withUnsafeBufferPointer { ptr in
            self.blasNodeBuffer = device.makeBuffer(bytes: ptr.baseAddress!, length: MemoryLayout<BLASNode>.stride * scene.tlas!.blasNodes.count)
        }
        scene.tlas!.faces.withUnsafeBufferPointer { ptr in
            self.faceBuffer = device.makeBuffer(bytes: ptr.baseAddress!, length: MemoryLayout<RayTraceTriangleGPU>.stride * scene.tlas!.faces.count)
        }
    }

    func invalidateAccumulation() {
        sampleIndex = 0
        lastCameraPosition = simd_float3(repeating: .infinity)
        lastCameraForward = simd_float3(repeating: .infinity)
        lastCameraUp = simd_float3(repeating: .infinity)
    }

    func draw(view: MTKView, commandQueue: MTLCommandQueue) {
        autoreleasepool {
            if raytraceOnCPU {
                print("CPU drawing is unavailable right now")
                exit(1)
                //calculateImageCPU(scene: scene) 
            } else { // GPU
                guard let drawable = view.currentDrawable else { return }
                
                //TODO: In the future 'sceneChanged' will be required aswell
                func posNearlyEq(_ a: simd_float3, _ b: simd_float3) -> Bool { return simd_length(a - b) < 0.001 }
                var cameraChanged: Bool = false
                if !posNearlyEq(scene.camera.position, lastCameraPosition) || !posNearlyEq(scene.camera.forward, lastCameraForward) || !posNearlyEq(scene.camera.up, lastCameraUp) {
                    lastCameraPosition = scene.camera.position
                    lastCameraForward = scene.camera.forward
                    lastCameraUp = scene.camera.up
                    cameraChanged = true
                    print("Camera Moved, Sample Invalidated")
                }
                let windowResolutionChanged = lastWidth != drawable.texture.width || lastHeight != drawable.texture.height 
                if windowResolutionChanged {
                    lastWidth = drawable.texture.width
                    lastHeight = drawable.texture.height
                    print("Window Resized, Sample Invalidated")
                }

                sampleIndex = (cameraChanged || windowResolutionChanged) ? 0 : sampleIndex + 1
                if sampleIndex == 0 {
                    let accumTextureDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: drawable.texture.width, height: drawable.texture.height, mipmapped: false)
                    accumTextureDesc.usage = [.shaderWrite, .shaderRead]
                    accumTexture = device.makeTexture(descriptor: accumTextureDesc)
                }     
                if sampleIndex >= maxSamples { // Camera did not move and max samples reached so stop new GPU processing
                    return
                } else {
                    print("Sampling Index: \(sampleIndex)")
                }

                // The Render Commands
                let commandBuffer = commandQueue.makeCommandBuffer()!
                let encoder = commandBuffer.makeComputeCommandEncoder()!

                var uniforms = Uniforms(
                    sampleIndex: sampleIndex,
                    fovScale: tan(FOVRad * 0.5), 
                    cameraPosition: scene.camera.position,
                    cameraForward: scene.camera.forward, 
                    cameraUp: scene.camera.up,
                    cameraRight: scene.camera.right
                )
                memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

                encoder.setComputePipelineState(self.pipeline)
                encoder.setTexture(drawable.texture, index: 0)
                encoder.setTexture(accumTexture, index: 1)
                encoder.setSamplerState(self.pipelineBuilder.sampler, index: 0)
                
                encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)
                encoder.setBuffer(materialBuffer, offset: 0, index: 1)
                encoder.setBuffer(tlasNodeBuffer, offset: 0, index: 2)
                encoder.setBuffer(tlasInstanceBuffer, offset: 0, index: 3)
                encoder.setBuffer(blasNodeBuffer, offset: 0, index: 4)
                encoder.setBuffer(faceBuffer, offset: 0, index: 5)
                encoder.setBuffer(argumentBuffer, offset: 0, index: 6)
                for texture in scene.textures { encoder.useResource(texture, usage: .sample) }

                let width = pipeline.threadExecutionWidth
                let height = pipeline.maxTotalThreadsPerThreadgroup / width
                let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
                let threadsPerGrid = MTLSize(width: drawable.texture.width, height: drawable.texture.height, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

                encoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()

                // If save, save drawable texture as png to desktop when maxSamples reached and exit program
                if saveAndExitOnGPU && sampleIndex >= maxSamples {
                    commandBuffer.waitUntilCompleted()
                    let output = drawable.texture
                    let bytesPerPixel = 4
                    let bytesPerRow = output.width * bytesPerPixel

                    var pixels = [UInt8](repeating: 0, count: output.height * bytesPerRow)
                    output.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, output.width, output.height), mipmapLevel: 0)

                    let (cGWidth, cGHeight) = getScreenSize()
                    let width = Int(cGWidth)
                    let height = Int(cGHeight)
                    if let image = createImage(width: width, height: height, pixelData: Data(pixels)) {
                        saveImageToDesktop(image)
                    } else {
                        print("Failed to create image.")
                    }
                    exit(0)
                }
            }
        }
    }
}