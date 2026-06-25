import MetalKit

private let benchmarkGPUTime: Bool = false

@MainActor final class RasterRenderer: Renderer {
    var pipeline: MTLRenderPipelineState
    var pipelineBuilder: PipelineBuilder!
    var sampler: MTLSamplerState!
    var scene: Scene

    var transparentSubMeshes: [SubMesh]
    var opaqueSubMeshes: [SubMesh]

    var vertexBuffer: MTLBuffer!
    var indexBuffer: MTLBuffer!
    var uniformsBuffer: MTLBuffer!

    var opaqueDepthState: MTLDepthStencilState!
    var transparentDepthState: MTLDepthStencilState!

    var projectionMatrix = simd_float4x4()

    init(device: MTLDevice, scene: Scene) {
        self.scene = scene
        pipelineBuilder = PipelineBuilder(device: device)
        pipeline = pipelineBuilder.makeRasterPipeline()
        sampler = pipelineBuilder.sampler

        vertexBuffer = device.makeBuffer(
            bytes: scene.vertices,
            length: MemoryLayout<Vertex>.stride * scene.vertices.count
        )
        var indices: [UInt32] = []
        for face in scene.faces { indices.append(contentsOf: [face.vertexIndices.x, face.vertexIndices.y, face.vertexIndices.z]) }
        indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<RasterizerUniforms>.stride)

        // Depth state for opaque objects
        let opaqueDepthDesc = MTLDepthStencilDescriptor()
        opaqueDepthDesc.isDepthWriteEnabled = true
        opaqueDepthDesc.depthCompareFunction = .less
        opaqueDepthState = device.makeDepthStencilState(descriptor: opaqueDepthDesc)!
        opaqueSubMeshes = scene.subMeshes.filter({ scene.materials[Int($0.materialIndex)].dissolve >= 1.0 })

        // Depth state for transparent objects
        let transparentDepthDesc = MTLDepthStencilDescriptor()
        transparentDepthDesc.isDepthWriteEnabled = false
        transparentDepthDesc.depthCompareFunction = .less
        transparentDepthState = device.makeDepthStencilState(descriptor: transparentDepthDesc)!
        transparentSubMeshes = scene.subMeshes.filter({ scene.materials[Int($0.materialIndex)].dissolve < 1.0 })

        updateProjectionMatrix()
    }

    func updateProjectionMatrix() {
        let screenSize = getScreenSize()
        let aspect = Float(screenSize.width / screenSize.height)
        let yScale = 1 / tan(FOVRad * 0.5)
        let xScale = yScale / aspect

        projectionMatrix = simd_float4x4(columns: (
            simd_float4(xScale, 0, 0, 0),
            simd_float4(0, yScale, 0, 0),
            simd_float4(0, 0, zFar / (zFar - zNear), 1),
            simd_float4(0, 0, -zNear * zFar / (zFar - zNear), 0)
        ))
    }

    func draw(view: MTKView, commandQueue: MTLCommandQueue) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        let camera = scene.camera
        let P = camera.position
        let R = camera.right
        let U = camera.up
        let F = camera.forward

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

        func drawSubMesh(subMesh: SubMesh) {
            let mesh = scene.meshes[Int(subMesh.meshIndex)]
            let mvpMatrix = projectionMatrix * viewMatrix * mesh.modelMatrix
            var uniforms = RasterizerUniforms(mvpMatrix: mvpMatrix, normalMatrix: mesh.normalMatrix)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RasterizerUniforms>.stride, index: 1)

            var indexedMaterial = scene.materials[Int(subMesh.materialIndex)]
            encoder.setFragmentTexture(scene.textures[indexedMaterial.diffuseTextureIndex == -1 ? 0 : Int(indexedMaterial.diffuseTextureIndex)], index: 0)
            encoder.setFragmentBytes(&indexedMaterial, length: MemoryLayout<Material>.stride, index: 2)
            let indexCount = 3 * Int(subMesh.faceCount)
            let indexBufferOffset = 3 * Int(subMesh.faceOffset) * MemoryLayout<UInt32>.stride
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: MTLIndexType.uint32, indexBuffer: indexBuffer, indexBufferOffset: indexBufferOffset)
            // Unindexed old approach:
            //encoder.drawPrimitives(type: .triangle, vertexStart: Int(subMesh.vertexOffset), vertexCount: Int(subMesh.vertexCount))
        }       
        
        encoder.setDepthStencilState(opaqueDepthState)
        for subMesh in opaqueSubMeshes { drawSubMesh(subMesh: subMesh) }

        func distToCamera(_ subMesh: SubMesh) -> Float {
            let vertex = scene.vertices[Int(subMesh.vertexOffset)]
            return length(camera.position - vertex.position)
        }

        encoder.setDepthStencilState(transparentDepthState)
        let sortedTransparentCalls = transparentSubMeshes.sorted { distToCamera($0) > distToCamera($1) }
        for call in sortedTransparentCalls { drawSubMesh(subMesh: call) }

        encoder.endEncoding()

        if benchmarkGPUTime {
            if #available(macOS 10.15, *) {
                commandBuffer.addCompletedHandler { cb in  
                    let gpuTime = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                    print("GPU Time: \(gpuTime) ms")
                }
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()    
    }
}
