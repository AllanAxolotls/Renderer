import Metal
import MetalKit

struct RayTracerUniforms {
    var sampleIndex:    Int32
    var fovScale:       Float
    var cameraPosition: simd_float3
    var cameraForward:  simd_float3
    var cameraUp:       simd_float3
    var cameraRight:    simd_float3
} 

@MainActor final class RayTracer {
    private unowned let device: MTLDevice
    private unowned let renderManager: RenderManager
    private unowned let resourceManager: ResourceManager
    private unowned let sceneManager: SceneManager
    private unowned let collisionManager: CollisionManager
    private unowned let commandQueue: MTLCommandQueue

    var computePipelineState: MTLComputePipelineState!
    var renderPipelineState: MTLRenderPipelineState!
    var upscaleSampler: MTLSamplerState!

    var textureArgumentEncoder: MTLArgumentEncoder!
    var uniformBuffer: MTLBuffer!
    var textureBuffer: MTLBuffer!
    var rayOutputTexture: MTLTexture? = nil
    var accumTexture: MTLTexture? = nil

    var isPaused: Bool = false

    init(
        device: MTLDevice,
        renderManager: RenderManager,
        resourceManager: ResourceManager,
        sceneManager: SceneManager,
        collisionManager: CollisionManager,
        commandQueue: MTLCommandQueue
    ) {
        self.device = device
        self.renderManager = renderManager
        self.resourceManager = resourceManager
        self.sceneManager = sceneManager
        self.collisionManager = collisionManager
        self.commandQueue = commandQueue

        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<RayTracerUniforms>.stride)
    }

    func render(in view: MTKView) {
        if RayTracerConstants.renderOnCPU {
            renderCPU()
        } else {
            renderGPU(in: view)
        }
    }

    private func createRayTexture(width: Int, height: Int) {
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

    var lastWidth          : Int = -1
    var lastHeight         : Int = -1
    var lastCameraPosition : simd_float3 = simd_float3(repeating: .infinity)
    var lastCameraForward  : simd_float3 = simd_float3(repeating: .infinity)
    var lastCameraUp       : simd_float3 = simd_float3(repeating: .infinity)
    var sampleIndex        : Int32 = 0
    var frameElapsedTime   : CFTimeInterval = 0.0
    var totalElapsedTime   : CFTimeInterval = 0.0
    var averageElapsedTime : CFTimeInterval = 0.0

    private func renderGPU(in view: MTKView) {
        let result = renderManager.inflightSemaphore.wait(timeout: .now())
        if result == .timedOut { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable 
        else {
            renderManager.inflightSemaphore.signal()
            return 
        }

        let camera: Camera? = sceneManager.currentScene?.currentCamera
        let P: simd_float3 = camera?.position ?? [0, 0, 0]
        let R: simd_float3 = camera?.right    ?? [1, 0, 0]
        let U: simd_float3 = camera?.up       ?? [0, 1, 0]
        let F: simd_float3 = camera?.forward  ?? [0, 0, 1]
        
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

        // Camera did not move and max samples reached so stop new GPU processing
        let skipRaytracing: Bool = (sampleIndex >= RayTracerConstants.maxSampleCount) || isPaused

        let currentSampleIndex: Int32
        if cameraChanged || windowResolutionChanged { 
            // Invalidate current sample
            currentSampleIndex = 0
            sampleIndex = 0
            totalElapsedTime = 0.0
        } else {
            currentSampleIndex = sampleIndex
            if (!skipRaytracing) {
                sampleIndex = min(sampleIndex + 1, Int32(RayTracerConstants.maxSampleCount))
            }
        }

        let flushTextures: Bool = sampleIndex == 0 || windowResolutionChanged
        if (flushTextures && !isPaused) {

            let outputWidthDivisor: Int = 1
            let outputHeightDivisor: Int = 1
            createRayTexture(
                width: drawable.texture.width / outputWidthDivisor, 
                height: drawable.texture.height / outputHeightDivisor
            )
        }

        if (!skipRaytracing) {

            var uniforms = RayTracerUniforms(
                sampleIndex: currentSampleIndex,
                fovScale: tan(((sceneManager.currentScene?.currentCamera.fov ?? 90) * .pi / 180) * 0.5),
                cameraPosition: P,
                cameraForward: F, 
                cameraUp: U,
                cameraRight: R
            )
            memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<RayTracerUniforms>.stride)

            let encoder = commandBuffer.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(computePipelineState)
            encoder.setTexture(rayOutputTexture, index: 0)
            encoder.setTexture(accumTexture, index: 1)
            encoder.setTexture(accumTexture, index: 2)

            encoder.setBuffer(uniformBuffer, offset: 0, index: RayTracerConstants.uniformsBufferIndex)
            encoder.setBuffer(collisionManager.meshTriAllocator.buffer, offset: 0, index: RayTracerConstants.meshTriBufferIndex)
            encoder.setBuffer(resourceManager.materialAllocator.buffer, offset: 0, index: RayTracerConstants.materialBufferIndex)

            // Textures
            encoder.setBuffer(textureBuffer, offset: 0, index: RayTracerConstants.textureBufferIndex)
            
            let textures: [MTLTexture] = resourceManager.textureSlotCollection.packed(using: resourceManager.defaultTexture.mtlTexture!)
            textureArgumentEncoder.setTextures(textures, range: 1 ..< textures.count + 1)
            for texture in textures { encoder.useResource(texture, usage: .sample) }

            encoder.setBuffer(collisionManager.blasNodeAllocator.buffer,     offset: 0, index: RayTracerConstants.blasNodeBufferIndex)
            encoder.setBuffer(collisionManager.tlasInstanceAllocator.buffer, offset: 0, index: RayTracerConstants.tlasInstanceBufferIndex)
            encoder.setBuffer(collisionManager.tlasNodeAllocator.buffer,     offset: 0, index: RayTracerConstants.tlasNodeBufferIndex)

            let width = computePipelineState.threadExecutionWidth
            let height = computePipelineState.maxTotalThreadsPerThreadgroup / width
            let threadsPerThreadgroup = MTLSize(
                width: width,
                height: height,
                depth: 1
            )

            // TODO: shouldn't be from drawable
            encoder.dispatchThreads(
                MTLSize(width: drawable.texture.width, height: drawable.texture.height, depth: 1),
                threadsPerThreadgroup: threadsPerThreadgroup
            )

            encoder.endEncoding()
        }

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setFragmentTexture(rayOutputTexture, index: 0)
        renderEncoder.setFragmentSamplerState(upscaleSampler, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        renderEncoder.endEncoding()

        commandBuffer.addCompletedHandler {cb in
            let gpuStartTime = cb.gpuStartTime
            let gpuEndTime = cb.gpuEndTime

            DispatchQueue.main.async {
                if (!self.isPaused) {
                    self.frameElapsedTime = max( min( (gpuEndTime - gpuStartTime) * 1000, 10000), 0)
                    self.totalElapsedTime += self.frameElapsedTime
                    self.averageElapsedTime = self.totalElapsedTime / Double(self.sampleIndex)
                }

                self.renderManager.inflightSemaphore.signal()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func saveGpuResult(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        let output = drawable.texture
        let bytesPerPixel = 4
        let bytesPerRow = output.width * bytesPerPixel

        var pixels = [UInt8](repeating: 0, count: output.height * bytesPerRow)
        output.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, output.width, output.height), mipmapLevel: 0)

        let width = Int(renderManager.gameScreenSize.width)
        let height = Int(renderManager.gameScreenSize.height)
        savePixelDataToDesktop(name: "RayTracer_GPU_Result.png", width: width, height: height, pixelData: Data(pixels))
        exit(0)
    }

    /// Creates a frame using the CPU, saves it on the desktop and stops execution
    private func renderCPU() {
        let cpuImageWidth = RayTracerConstants.cpuImageWidth
        let cpuImageHeight = RayTracerConstants.cpuImageHeight
        var pixels = [UInt8](repeating: 0, count: cpuImageWidth * cpuImageHeight * 4)

        for y in 0 ..< cpuImageHeight {
            for x in 0 ..< cpuImageWidth {
                let pixelOffset = (y * cpuImageWidth + x) * 4
                let pixel = raytraceCpu(
                    gid: simd_uint2(UInt32(x), UInt32(y))
                )

                pixels[pixelOffset + 0] = pixel.r
                pixels[pixelOffset + 1] = pixel.g
                pixels[pixelOffset + 2] = pixel.b
                pixels[pixelOffset + 3] = pixel.a
            }
        }

        let pixelData = Data(pixels)

        if RayTracerConstants.saveAndExitOnCPURender {
            savePixelDataToDesktop(name: "RayTracer_CPU_Result.png", width: cpuImageWidth, height: cpuImageHeight, pixelData: pixelData)
            exit(0)
        }

        // TODO: display CPU result in window by setting the window drawable texture to the pixel data

    }

    private func raytraceCpu(
        gid: simd_uint2
    ) -> Rgba8 {
        let width  : UInt32 = UInt32(RayTracerConstants.cpuImageWidth)
        let height : UInt32 = UInt32(RayTracerConstants.cpuImageHeight)
        let pixelX : UInt32 = gid.x
        let pixelY : UInt32 = gid.y

        let camera: Camera? = sceneManager.currentScene?.currentCamera
        let fov: Float = camera?.fov ?? 90
        let fovScale: Float = tan((fov * .pi / 180) * 0.5)
        let cameraPosition : simd_float3 = camera?.position ?? [0, 0, 0]
        let cameraForward  : simd_float3 = camera?.forward  ?? [0, 0, 1]
        let cameraUp       : simd_float3 = camera?.up       ?? [0, 1, 0]
        let cameraRight    : simd_float3 = camera?.right    ?? [1, 0, 0]

        let aspectRatio: Float = Float(width) / Float(height)
        let samplesPerPixel = RayTracerConstants.samplesPerPixel
        var accumulatedRadiance: simd_float3 = [0, 0, 0]

        for _ in 0 ..< samplesPerPixel {
            let jitterX = randomFloat() - 0.5
            let jitterY = randomFloat() - 0.5

            let ndcX = (Float(pixelX) + jitterX) / Float(width) * 2.0 - 1.0
            let ndcY = 1.0 - ((Float(pixelY) + jitterY) / Float(height)) * 2.0
            let projectedX = ndcX * aspectRatio * fovScale
            let projectedY = ndcY * fovScale

            let look = simd_normalize(cameraForward + projectedX * cameraRight + projectedY * cameraUp)
            let primaryRay = Ray(origin: cameraPosition, direction: look)

            accumulatedRadiance += tracePath(ray: primaryRay)
        }

        // Average the samples
        let finalRadiance = accumulatedRadiance / Float(samplesPerPixel)

        return Rgba8(
            simd_clamp(finalRadiance, [0, 0, 0], [1, 1, 1]),
            a: 1.0
        )
    }

    private func tracePath(ray initialRay: Ray) -> simd_float3 {
        var ray = initialRay
        var radiance: simd_float3 = [0, 0, 0]
        var throughput: simd_float3 = [1, 1, 1]

        for bounce in 0 ..< RayTracerConstants.maxLightBounces {
            let raycastResult = collisionManager.raycast(ray: ray)

            // 1. ENVIRONMENT / SKY HIT
            if raycastResult.didNotHit() {
                let look = ray.direction
                let t = 0.5 * (look.y + 1.0)
                let horizonColor: simd_float3 = [207.0/255.0, 219.0/255.0, 230.0/255.0]
                let zenithColor: simd_float3 = [60.0/255.0, 138.0/255.0, 201.0/255.0]
                let skyIntensity: Float = 4.0
                let skyColor = mix(horizonColor, zenithColor, t: t)
                
                let sunDirection: simd_float3 = [0, 1.0, 0]
                let sunColor: simd_float3 = [1, 1, 1]
                let sunIntensity: Float = 256.0
                let sunAmount = powf(simd_max(simd_dot(look, sunDirection), 0.0), sunIntensity)
                
                let skyRadiance = skyColor * skyIntensity + sunColor * sunAmount
                radiance += throughput * skyRadiance

                break
            }

            guard let meshTri = collisionManager.meshTriAllocator[Int(raycastResult.primitiveId)],
                  let material = resourceManager.materialAllocator[Int(raycastResult.materialId)]
            else {
                radiance += throughput * simd_float3(1, 0, 1)
                break
            }

            // Emission
            let emission = material.emissionColor.rgb
            let maxEmission = max(emission.x, max(emission.y, emission.z))
            if maxEmission > 0.0 {
                radiance += throughput * emission
                break // Terminate ray path once it hits a light source
            }

            let uv = meshTri.getInterpolatedUV(bary: raycastResult.barycentric)

            // Stochastic Dissolve Check for texture cut-outs
            // TODO: if there is a cutout but the material isn't transparent, maybe don't cut it out?
            if material.dissolveTextureIndex != -1 {
                let dissolveTexture = resourceManager.textureSlotCollection[Int(material.dissolveTextureIndex)]
                // TODO: sample texture here
                let dissolve: Float = 0.0
                if randomFloat() > dissolve {
                    // TODO: decrement the bounce one back
                    //bounce -= 1
                    ray.origin = raycastResult.hit + ray.direction * 1e-3
                    continue
                }
            }

            
            let diffuseTexture = resourceManager.textureSlotCollection[Int(material.diffuseTextureIndex)]
            var texColor = simd_make_float4(material.diffuseColor.rgb, 1.0)
            // TODO: sample texture here
            //texColor *= 
            let albedo = mix(material.diffuseColor.rgb, simd_make_float3(texColor), t: texColor.w)

            // BSDF
            var sampleWeight: simd_float3 = [1, 1, 1]
            let ior = material.refractiveIndex
            let isSmoothSpecular = material.roughness < 0.05

            let normal = meshTri.getInterpolatedNormal(bary: raycastResult.barycentric)
            var wi: simd_float3
            let wo = -ray.direction
            let isTransmitting = (1.0 - material.diffuseColor.a) > 0.0

            if isTransmitting {
                let entering = simd_dot(normal, wo) > 0.0
                let correctNormal = entering ? normal : -normal
                let eta = entering ? (1.0 / ior) : ior

                // Compute Fresnel reflectance to stochastically choose Reflection vs Transmission (PBRT Dielectric)
                let cosi = abs(simd_dot(correctNormal, wo))
                let fresnel = F(cosTheta: cosi, f0: dielectricF0(ior: entering ? ior : (1.0 / ior)))

                if (randomFloat() < fresnel) {
                    // Specular Reflection
                    wi = simd_normalize(simd_reflect(-wo, correctNormal))
                    sampleWeight = simd_make_float3(1.0)
                } else {
                    // Transmission / Refraction
                    let refracted = simd_refract(-wo, correctNormal, eta)
                    if (refracted.x == 0 && refracted.y == 0 && refracted.z == 0) {
                        // Total Internal Reflection fallback
                        wi = simd_normalize(simd_reflect(-wo, correctNormal))
                        sampleWeight = simd_make_float3(1.0)
                    } else {
                        wi = refracted
                        sampleWeight = albedo
                    }
                }
            } else if isSmoothSpecular || material.metallic > 0.5 {
                wi = simd_normalize(simd_reflect(-wo, normal))
                let h = simd_normalize(wi + wo)
                let hDotV = max(simd_dot(h, wo), 0.0)
                let f0 = mix(simd_make_float3(0.04), albedo, t: material.metallic)
                sampleWeight = F(cosTheta: hDotV, f0: f0)
            } else {
                // Diffuse / Rough Lambertian
                wi = sampleHemisphere(normal: normal)
                let pdf = max(simd_dot(normal, wi), 0.0) / .pi
                if pdf <= 0.0001 { break }

                let cosTheta = max(simd_dot(normal, wi), 0.0)
                sampleWeight = (albedo / .pi) * cosTheta / pdf
            }

            throughput *= sampleWeight

            // 4. RUSSIAN ROULETTE
            if bounce >= 3 {
                let pCont = min(max(throughput.x, max(throughput.y, throughput.z)), 0.95)
                if randomFloat() > pCont {
                    break
                }
                throughput /= pCont
            }

            let offsetNormal = simd_dot(normal, wi) > 0 ? normal : -normal
            ray = Ray(origin: raycastResult.hit + offsetNormal * 0.001, direction: wi)
        }

        return radiance
    }

    // The Bidirectional Reflectance Distribution Function (BRDF) (Cook et Torrance)
    private func f_r(wi: simd_float3, wo: simd_float3, n: simd_float3, material: BaseMaterial) -> simd_float3 {
        let nDotL = simd_max(simd_dot(n, wi), 0.0)
        let nDotV = simd_max(simd_dot(n, wo), 0.0)
        if nDotL <= 0.0 || nDotV <= 0.0 { return [0, 0, 0] }

        let h = simd_normalize(wi + wo)
        let roughness = max(material.roughness, 0.001)
        let d = D(h: h, n: n, roughness: roughness)

        let hDotV = simd_max(simd_dot(h, wo), 0.0)
        let f0 = F0(material: material)
        let f = F(cosTheta: hDotV, f0: f0)
        let g = G(wi: wi, wo: wo, n: n, roughness: roughness)

        let specular = (d * f * g) / max(4.0 * nDotV * nDotL, 0.001)

        // Diffuse and specular weights together are equal to 1.0
        let kS = f
        let kD = (simd_float3(repeating: 1.0) - kS) * (1.0 - material.metallic)

        // Lambertian diffuse
        let albedo = material.diffuseColor.rgb
        let diffuse = kD * (albedo / .pi)
        return diffuse + specular
    }

    // Bidirectional Transmittance Distribution Function (BTDF) (Walter et al.)
    private func f_t(wi: simd_float3, wo: simd_float3, n: simd_float3, eta: Float, roughness: Float) -> simd_float3 {        
        var h = -(eta * wo + wi)
        h = simd_normalize(h)

        let nDotWi = simd_dot(n, wi)
        let nDotWo = simd_dot(n, wo)
        let hDotWi = simd_dot(h, wi)
        let hDotWo = simd_dot(h, wo)
        if nDotWi == 0.0 || nDotWo == 0.0 || hDotWi == 0.0 || hDotWo == 0.0 { return [0, 0, 0] }

        let d = D(h: h, n: n, roughness: roughness)
        let g = G(wi: wi, wo: wo, n: n, roughness: roughness)
        let cosTheta = abs(hDotWo)
        let f0 = simd_float3(repeating: 0.04) // Dielectric F0 for glass/water
        let f = F(cosTheta: cosTheta, f0: f0)
        let transmissionFactor = simd_float3(repeating: 1.0) - f

        let denomTerm = nDotWo + eta * nDotWi
        let denominator = denomTerm * denomTerm * abs(nDotWo)
        if denominator == 0.0 { return [0, 0, 0] }

        let numerator = (eta * eta) * d * g * transmissionFactor * abs(hDotWi) * abs(hDotWo)
        return numerator / denominator
    }

    // Bidirectional Scattering Distribution Function (BSDF)
    private func f_s(wi: simd_float3, wo: simd_float3, n: simd_float3, material: BaseMaterial, outPdf: inout Float) -> simd_float3 {
        let transmission = 1.0 - material.diffuseColor.a 
        let isTransmitting = transmission > 0.0

        let nDotWi = simd_dot(n, wi)
        let nDotWo = simd_dot(n, wo)
        let sameSide = (nDotWi * nDotWo) > 0.0
        let roughness = max(material.roughness, 0.001)

        // If wi and wo are on the same side it's reflection, otherwise it's transmission
        if sameSide {
            // Reflection (BRDF)
            let brdf = f_r(wi: wi, wo: wo, n: n, material: material)
            // Lambertian Diffuse PDF
            outPdf = max(nDotWi, 0.0) / .pi
            return brdf
        } else {
            // Transmission / Refraction (BTDF)
            if !isTransmitting {
                outPdf = 0.0
                return [0, 0, 0] 
            }
            
            let entering = nDotWo > 0.0
            let iorIncident: Float = entering ? 1.0 : material.refractiveIndex
            let iorTransmitted: Float = entering ? material.refractiveIndex : 1.0
            let eta = iorIncident / iorTransmitted

            let h = simd_normalize(-(eta * wi + wo))
            let hDotWi = simd_dot(h, wi)
            let hDotWo = simd_dot(h, wo)

            // Walter et al. Transmission PDF
            let d = D(h: h, n: n, roughness: roughness)
            let denom = hDotWi + eta * hDotWo
            outPdf = (d * abs(hDotWo) * eta * eta * abs(hDotWi)) / (denom * denom)

            let btdf = f_t(wi: wi, wo: wo, n: n, eta: eta, roughness: material.roughness)
            return btdf * material.diffuseColor.rgb * transmission
        }
    }

    // Microfacet Distribution Function (GGX)
    // Distribution of microfacets describing how much they align
    private func D(h: simd_float3, n: simd_float3, roughness: Float) -> Float {
        let a = roughness * roughness
        let a2 = a * a
        let nDotH = simd_max(simd_dot(n, h), 0.0)
        let nDotH2 = nDotH * nDotH
        let denominator = nDotH2 * (a2 - 1.0) + 1.0
        return a2 / (.pi * denominator * denominator)
    }

    // Fresnel Term (Schlick's Approximation)
    // How much light reflects off a surface versus how much enters it based on viewing angle
    private func F(cosTheta: Float, f0: simd_float3) -> simd_float3 {
        return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0)
    }
    private func F(cosTheta: Float, f0: Float) -> Float {
        return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0)
    }

    // Fresnel Reflectance at Normal Incidence (F0)
    // Most non-metals are around 0.04 unlike metals
    private func F0(material: BaseMaterial) -> simd_float3 {
        return mix(simd_float3(repeating: 0.04), material.diffuseColor.rgb, t: material.metallic)
    }

    private func dielectricF0(ior: Float) -> Float {
        let t = (ior - 1.0) / (ior + 1.0)
        return t * t
    }

    // Bidirectional Shadow Masking Function
    private func G(wi: simd_float3, wo: simd_float3, n: simd_float3, roughness: Float) -> Float {
        let r = roughness + 1.0
        let k = (r * r) / 8.0
        let ggx1 = G_1(v: wi, n: n, k: k)
        let ggx2 = G_1(v: wo, n: n, k: k)
        return ggx1 * ggx2
    }

    // Monodirectional Shadow Masking Function
    private func G_1(v: simd_float3, n: simd_float3, k: Float) -> Float {
        let nDotV = simd_max(simd_dot(n, v), 0.0)
        return nDotV / (nDotV * (1.0 - k) + k)
    }

    private func randomFloat() -> Float {
        return Float(arc4random()) / Float(UINT32_MAX)
    }

    // Generates a random direction on a hemisphere centered around a normal
    private func sampleHemisphere(normal: simd_float3) -> simd_float3 {
        let u1 = randomFloat()
        let u2 = randomFloat()

        let r = sqrt(max(0.0, 1.0 - u1 * u1))
        let phi = 2.0 * .pi * u2
        
        let localDir = simd_float3(cos(phi) * r, sin(phi) * r, u1)

        let tangent = abs(normal.x) > 0.1 ? simd_float3(0, 1, 0) : simd_float3(1, 0, 0)
        let bitangent = simd_normalize(simd_cross(normal, tangent))
        let correctedTangent = simd_cross(bitangent, normal)

        return simd_normalize(localDir.x * correctedTangent + localDir.y * bitangent + localDir.z * normal)
    }
}