import MetalKit
import Combine

@MainActor final class RasterRenderer: Renderer {
    let device: MTLDevice!
    var pipeline: MTLRenderPipelineState
    var pipelineBuilder: PipelineBuilder!
    var sampler: MTLSamplerState!
    var scene: Scene? = nil

    var transparentSubMeshes: [SubMesh] = []
    var opaqueSubMeshes: [SubMesh] = []

    var vertexBuffer: MTLBuffer? = nil
    var indexBuffer: MTLBuffer? = nil
    var uniformsBuffer: MTLBuffer!

    var opaqueDepthState: MTLDepthStencilState!
    var transparentDepthState: MTLDepthStencilState!

    private(set) var lastFrameDuration: Double = 0
    private var lastTitleUpdateTimestamp: CFAbsoluteTime = 0.0
    private let titleUpdateInterval: CFAbsoluteTime = 0.25 // Update max 4 times/sec

    var projectionMatrix = simd_float4x4()

    // Connections
    var sceneVerticesAddedConnection: AnyCancellable? = nil
    var sceneFacesAddedConnection: AnyCancellable? = nil
    var sceneSubMeshesAddedConnection: AnyCancellable? = nil


    init(device: MTLDevice, scene: Scene?) {
        self.device = device
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

        setScene(scene)
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

    public func setScene(_ newScene: Scene?) {
        if (self.scene != nil) {
            // Disconnect Subscriptions
            if let connection = sceneVerticesAddedConnection    { connection.cancel() }
            if let connection = sceneFacesAddedConnection       { connection.cancel() }
            if let connection = sceneSubMeshesAddedConnection   { connection.cancel() }
            
            sceneVerticesAddedConnection = nil
            sceneFacesAddedConnection = nil
            sceneSubMeshesAddedConnection = nil
        }

        self.scene = newScene

        // Create new subscriptions
        guard let newScene = newScene else { return }
        // TODO: should maybe merge vertices added and faces added?
        sceneVerticesAddedConnection  = newScene.verticesAdded.sink  { [weak self] in self?.updateVertexBuffer() }
        sceneFacesAddedConnection     = newScene.facesAdded.sink     { [weak self] in self?.updateIndexBuffer()  }
        sceneSubMeshesAddedConnection = newScene.subMeshesAdded.sink { [weak self] in self?.updateDrawlists()    } 

        updateBuffers()
    }

    private func updateBuffer<T>(
        _ buffer: inout MTLBuffer?,
        with elements: [T],
        options: MTLResourceOptions = .storageModeShared
    ) {
        guard !elements.isEmpty else { buffer = nil; return }
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

    public func updateVertexBuffer() {
        guard let scene = scene else { vertexBuffer = nil; return }
        updateBuffer(&vertexBuffer, with: scene.vertices)
    }

    public func updateIndexBuffer() {
        guard let scene = scene else { indexBuffer = nil; return }
        let faces = scene.faces
        guard !faces.isEmpty else { indexBuffer = nil; return }

        let indexCount = faces.count * 3
        let requiredBytes = MemoryLayout<UInt32>.stride * indexCount

        if let existing = indexBuffer, existing.length >= requiredBytes && existing.length <= requiredBytes * 2 {
            let dest = existing.contents().bindMemory(to: UInt32.self, capacity: indexCount)
            for (i, face) in faces.enumerated() {
                let offset = i * 3
                dest[offset]     = face.vertexIndex0
                dest[offset + 1] = face.vertexIndex1
                dest[offset + 2] = face.vertexIndex2
            }
            return
        }

        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        for face in faces {
            indices.append(face.vertexIndex0)
            indices.append(face.vertexIndex1)
            indices.append(face.vertexIndex2)
        }

        let targetCapacity = Int(Double(requiredBytes) * 1.25)
        guard let newBuffer = device.makeBuffer(length: targetCapacity, options: .storageModeShared) else {
            indexBuffer = nil
            return
        }

        let _ = indices.withUnsafeBufferPointer { ptr in
            memcpy(newBuffer.contents(), ptr.baseAddress!, requiredBytes)
        }

        self.indexBuffer = newBuffer
    }


    public func updateBuffers() {
        updateVertexBuffer()
        updateIndexBuffer()
        updateDrawlists()
    }

    public func updateDrawlists() {
        guard let scene = scene else { return }
        opaqueSubMeshes = scene.subMeshes.filter({ scene.materials[Int($0.materialIndex)].dissolve >= 1.0})
        transparentSubMeshes = scene.subMeshes.filter({ scene.materials[Int($0.materialIndex)].dissolve < 1.0})
    }

    func draw(view: MTKView, commandQueue: MTLCommandQueue) {
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
        let materials = scene?.materials ?? []
        let textures = scene?.textures ?? []

        func drawSubMesh(subMesh: SubMesh) {
            let mesh = meshes[Int(subMesh.meshIndex)]
            let mvpMatrix = projectionMatrix * viewMatrix * mesh.modelMatrix
            var uniforms = RasterizerUniforms(mvpMatrix: mvpMatrix, normalMatrix: mesh.normalMatrix)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RasterizerUniforms>.stride, index: 1)

            var indexedMaterial = materials[Int(subMesh.materialIndex)]
   
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
            let indexCount = 3 * Int(subMesh.faceCount)
            let indexBufferOffset = 3 * Int(subMesh.faceOffset) * MemoryLayout<UInt32>.stride
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: MTLIndexType.uint32, indexBuffer: indexBuffer!, indexBufferOffset: indexBufferOffset)
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
