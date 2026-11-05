import MetalKit
import Combine

@MainActor final class RasterRenderer {
    let device: MTLDevice!
    var pipeline: MTLRenderPipelineState
    var pipelineBuilder: PipelineBuilder!
    var sampler: MTLSamplerState!
    public var scene: Scene? = nil

    var transparentSubMeshes: [SubMesh] = []
    var opaqueSubMeshes: [SubMesh] = []

    var indexBuffer: MTLBuffer? = nil
    var uniformsBuffer: MTLBuffer!

    var opaqueDepthState: MTLDepthStencilState!
    var transparentDepthState: MTLDepthStencilState!

    private(set) var lastFrameDuration: Double = 0
    private var lastTitleUpdateTimestamp: CFAbsoluteTime = 0.0
    private let titleUpdateInterval: CFAbsoluteTime = 0.25 // Update max 4 times/sec

    var projectionMatrix = simd_float4x4()

    // Connections
    var sceneChangedConnection: AnyCancellable? = nil

    init(device: MTLDevice, scene: Scene? = nil) {
        self.device = device
        self.scene = scene
        pipelineBuilder = PipelineBuilder(device: device)
        pipeline = pipelineBuilder.makeRasterPipeline()
        sampler = pipelineBuilder.sampler

        uniformsBuffer = device.makeBuffer(length: MemoryLayout<RasterizerUniforms>.stride)

        // Depth state for opaque objects
        let opaqueDepthDesc = MTLDepthStencilDescriptor()
        opaqueDepthDesc.isDepthWriteEnabled = true
        opaqueDepthDesc.depthCompareFunction = .less
        opaqueDepthState = device.makeDepthStencilState(descriptor: opaqueDepthDesc)!

        // Depth state for transparent objects
        let transparentDepthDesc = MTLDepthStencilDescriptor()
        transparentDepthDesc.isDepthWriteEnabled = false
        transparentDepthDesc.depthCompareFunction = .less
        transparentDepthState = device.makeDepthStencilState(descriptor: transparentDepthDesc)!

        updateProjectionMatrix()
    }

    func updateProjectionMatrix() {
        let screenSize = getScreenSize()
        let aspect = Float(screenSize.width / screenSize.height)
        let fovRad = (scene?.camera.fov ?? 90) * .pi / 180
        let yScale = 1 / tan(fovRad * 0.5)
        let xScale = yScale / aspect
        let zNear = scene?.camera.zNear ?? 0.1
        let zFar = scene?.camera.zFar ?? 1000

        projectionMatrix = simd_float4x4(columns: (
            simd_float4(xScale, 0, 0, 0),
            simd_float4(0, yScale, 0, 0),
            simd_float4(0, 0, zFar / (zFar - zNear), 1),
            simd_float4(0, 0, -zNear * zFar / (zFar - zNear), 0)
        ))
    }

    public func updateIndexBuffer() {
        guard let scene = scene else { return }
        updateBuffer(device: device, &indexBuffer, with: scene.indices)
    }

    public func updateDrawlists() {
        guard let scene = scene else { return }
        opaqueSubMeshes = []
        transparentSubMeshes = []

        for mesh in scene.meshes {
            for subMesh in mesh.subMeshes {
                if scene.materialDatas[Int(subMesh.materialIndex)].diffuseColor.w >= 1.0 {
                    opaqueSubMeshes.append(subMesh)
                } else {
                    transparentSubMeshes.append(subMesh)
                }
            }
        }
    }

    func draw(view: MTKView, commandQueue: MTLCommandQueue, vertexBuffer: MTLBuffer?) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTitleUpdateTimestamp >= titleUpdateInterval {
            lastTitleUpdateTimestamp = now
            
            if let window = view.window {
                let title = String(format: "[ Rasterizer | GPU: %.2f ms ]", self.lastFrameDuration)
                DispatchQueue.main.async { window.title = title }
            }
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        let camera: Camera? = scene?.camera
        let P = camera?.position    ?? simd_float3(0, 0, 0)
        let R = camera?.right       ?? simd_float3(1, 0, 0)
        let U = camera?.up          ?? simd_float3(0, 1, 0)
        let F = camera?.forward     ?? simd_float3(0, 0, 1)

        let viewMatrix = simd_float4x4(columns: (
            simd_float4(R.x, U.x, F.x, 0),
            simd_float4(R.y, U.y, F.y, 0),
            simd_float4(R.z, U.z, F.z, 0),
            simd_float4(-dot(R,P), -dot(U,P), -dot(F,P), 1)
        ))

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
        encoder.setCullMode(MTLCullMode.back)
        encoder.setFrontFacing(MTLWinding.clockwise)

        let vertices = scene?.vertices ?? []
        let meshes = scene?.meshes ?? []
        let materialDatas = scene?.materialDatas ?? []
        let textures = scene?.textureHandler?.textures ?? []

        func drawSubMesh(subMesh: SubMesh) {
            let mesh = meshes[Int(subMesh.meshIndex)]
            let mvpMatrix = projectionMatrix * viewMatrix * mesh.modelMatrix
            var uniforms = RasterizerUniforms(mvpMatrix: mvpMatrix, normalMatrix: mesh.normalMatrix)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RasterizerUniforms>.stride, index: 1)

            var indexedMaterial = materialDatas[Int(subMesh.materialIndex)]
            if indexedMaterial.diffuseTextureIndex >= 0 && indexedMaterial.diffuseTextureIndex < textures.count {
                encoder.setFragmentTexture(textures[Int(indexedMaterial.diffuseTextureIndex)], index: 0)
            } else {
                encoder.setFragmentTexture(nil, index: 0)
            }

            if indexedMaterial.dissolveTextureIndex >= 0 && indexedMaterial.dissolveTextureIndex < textures.count {
                encoder.setFragmentTexture(textures[Int(indexedMaterial.dissolveTextureIndex)], index: 1)
            } else {
                encoder.setFragmentTexture(nil, index: 1)
            }

            encoder.setFragmentBytes(&indexedMaterial, length: MemoryLayout<Material>.stride, index: 2)

            // Normal Method
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: Int(subMesh.indexCount), 
                indexType: MTLIndexType.uint32, 
                indexBuffer: indexBuffer!, 
                indexBufferOffset: Int(subMesh.indexOffset) * MemoryLayout<UInt32>.stride
            )
        } 

        func distToCamera(_ subMesh: SubMesh) -> Float {
            let vertex = vertices[Int(subMesh.vertexOffset)]
            return length(P - vertex.position)
        }  

        // TODO: add frustum culling by walking the TLAS 
        if let _ = indexBuffer {
            encoder.setDepthStencilState(opaqueDepthState)
            for subMesh in opaqueSubMeshes { drawSubMesh(subMesh: subMesh) }

            encoder.setDepthStencilState(transparentDepthState)
            let sortedTransparentCalls = transparentSubMeshes.sorted { distToCamera($0) > distToCamera($1) }
            for call in sortedTransparentCalls { drawSubMesh(subMesh: call) }
        }

        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] cb in  
            guard let self = self else { return }
            let durationMS = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            Task { @MainActor in self.lastFrameDuration = durationMS }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()    
    }
}
