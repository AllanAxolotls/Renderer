import MetalKit

@MainActor final class RasterRenderer: Renderer {
    var pipeline: MTLRenderPipelineState
    var pipelineBuilder: PipelineBuilder!
    var sampler: MTLSamplerState!
    var scene: Scene

    var transparentSubMeshes: [SubMesh]
    var opaqueSubMeshes: [SubMesh]

    var vertexBuffer: MTLBuffer!
    var matrixBuffer: MTLBuffer!

    var opaqueDepthState: MTLDepthStencilState!
    var transparentDepthState: MTLDepthStencilState!

    init(device: MTLDevice, scene: Scene) {
        self.scene = scene
        pipelineBuilder = PipelineBuilder(device: device)
        pipeline = pipelineBuilder.makeRasterPipeline()
        sampler = pipelineBuilder.sampler

        vertexBuffer = device.makeBuffer(
            bytes: scene.vertices,
            length: MemoryLayout<Vertex>.stride * scene.vertices.count
        )

        matrixBuffer = device.makeBuffer(length: MemoryLayout<matrix_float4x4>.stride)

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
    }

    func draw(
        view: MTKView,
        commandQueue: MTLCommandQueue,
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        let camera = scene.camera
        let P = camera.position
        let R = camera.right
        let U = camera.up
        let F = camera.forward

        let viewMatrix = matrix_float4x4(columns: (
            simd_float4(R.x, U.x, F.x, 0),
            simd_float4(R.y, U.y, F.y, 0),
            simd_float4(R.z, U.z, F.z, 0),
            simd_float4(-dot(R,P), -dot(U,P), -dot(F,P), 1)
        ))

        /*
        let modelMatrix = matrix_float4x4(columns: (
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(70, -30, -70, 1),
        ))
        */

        var finalMatrix = projection_matrix * viewMatrix //* modelMatrix
        memcpy(matrixBuffer.contents(), &finalMatrix,
               MemoryLayout<matrix_float4x4>.stride)

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        //encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(matrixBuffer, offset: 0, index: 1)
        encoder.setCullMode(MTLCullMode.back)

        func drawSubMesh(subMesh: SubMesh) {
            let indexedMaterial = scene.materials[Int(subMesh.materialIndex)]
            encoder.setFragmentTexture(scene.textures[Int(indexedMaterial.ambientTextureIndex)], index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var material = MaterialGPU(dissolve: indexedMaterial.dissolve)
            encoder.setFragmentBytes(&material, length: MemoryLayout<MaterialGPU>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: Int(subMesh.vertexOffset), vertexCount: Int(subMesh.vertexCount))
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

        commandBuffer.present(drawable)
        commandBuffer.commit()    
    }
}
