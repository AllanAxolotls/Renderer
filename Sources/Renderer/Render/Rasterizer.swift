import Metal
import MetalKit
import Combine

struct RasterizerDirtyFlags : OptionSet {
    let rawValue: UInt32

    static let projectionMatrix = RasterizerDirtyFlags(rawValue: 1 << 0)
    static let meshes           = RasterizerDirtyFlags(rawValue: 1 << 1)
}

struct RasterizerUniforms { //! must match Rasterizer.metal: Uniforms
    var mvpMatrix: simd_float4x4
    var normalMatrix: simd_float3x3
}

@MainActor final class Rasterizer {
    private unowned let sceneManager: SceneManager
    private unowned let renderManager: RenderManager
    private unowned let resourceManager: ResourceManager
    private unowned let commandQueue: MTLCommandQueue

    var renderPipelineState: MTLRenderPipelineState!
    var opaqueDepthState: MTLDepthStencilState!
    var transparentDepthState: MTLDepthStencilState!
    var sampler: MTLSamplerState!

    private var cancellables = Set<AnyCancellable>()
    var dirtyFlags: RasterizerDirtyFlags = RasterizerDirtyFlags([.projectionMatrix])

    private var _projectionMatrix = simd_float4x4()
    var projectionMatrix: simd_float4x4 {
        if (dirtyFlags.contains(.projectionMatrix)) {
            let camera = sceneManager.currentScene?.currentCamera
            let screenSize = renderManager.gameScreenSize
            let aspect = Float(screenSize.width / screenSize.height)
            let fovRad = (camera?.fov ?? RasterizerConstants.defaultFov).radians
            let yScale = 1 / tan(fovRad * 0.5)
            let xScale = yScale / aspect
            let zNear = camera?.zNear ?? RasterizerConstants.defaultZNear
            let zFar = camera?.zFar ?? RasterizerConstants.defaultZFar
            let f = zFar / (zFar - zNear)

            _projectionMatrix = simd_float4x4(columns: (
                [xScale, 0,      0,          0],
                [0,      yScale, 0,          0],
                [0,      0,      f,          1],
                [0,      0,      -zNear * f, 0]
            ))

            dirtyFlags.remove(.projectionMatrix)
        }
        return _projectionMatrix
    }

    // TODO: these meshes probably create a memory leak, make them weak
    private var _cachedOpaqueMeshes: [Mesh] = []
    private var opaqueMeshes: [Mesh] {
        if dirtyFlags.contains(.meshes) { updateCachedMeshes() }
        return _cachedOpaqueMeshes
    }

    private var _cachedTransparentMeshes: [Mesh] = []
    private var transparentMeshes: [Mesh] {
        if dirtyFlags.contains(.meshes) { updateCachedMeshes() }
        return _cachedTransparentMeshes
    }

    init(
        device: MTLDevice,
        sceneManager: SceneManager,
        renderManager: RenderManager,
        resourceManager: ResourceManager,
        commandQueue: MTLCommandQueue
    ) {
        self.sceneManager = sceneManager
        self.renderManager = renderManager
        self.resourceManager = resourceManager
        self.commandQueue = commandQueue  

        // Depth States
        let opaqueDepthDesc = MTLDepthStencilDescriptor()
        opaqueDepthDesc.isDepthWriteEnabled = true
        opaqueDepthDesc.depthCompareFunction = .less
        opaqueDepthState = device.makeDepthStencilState(descriptor: opaqueDepthDesc)!

        let transparentDepthDesc = MTLDepthStencilDescriptor()
        transparentDepthDesc.isDepthWriteEnabled = false
        transparentDepthDesc.depthCompareFunction = .less
        transparentDepthState = device.makeDepthStencilState(descriptor: transparentDepthDesc)!

        initListeners()
    }

    func initListeners() {
        sceneManager.sceneSwitchedPublisher.sink { child in self.dirtyFlags.insert(.meshes) }.store(in: &cancellables)
        sceneManager.sceneChildAddedPublisher.sink { child in self.dirtyFlags.insert(.meshes) }.store(in: &cancellables)
        sceneManager.sceneChildRemovedPublisher.sink { child in self.dirtyFlags.insert(.meshes) }.store(in: &cancellables)
    }

    func deinitListeners() {
        cancellables.removeAll()
    }

    func updateCachedMeshes() {
        _cachedOpaqueMeshes.removeAll()
        _cachedTransparentMeshes.removeAll()
        for mesh in sceneManager.currentScene?.renderableMeshes ?? [] {
            if mesh.isTransparent {
                _cachedTransparentMeshes.append(mesh)
            } else {
                _cachedOpaqueMeshes.append(mesh)
            }
        }
        dirtyFlags.remove(.meshes)
    }

    var frameElapsedTime: CFTimeInterval = 0.0
    func render(in view: MTKView) {
        let result = renderManager.inflightSemaphore.wait(timeout: .now())
        if result == .timedOut { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable 
        else {
            renderManager.inflightSemaphore.signal() 
            return 
        }
        
        let scene = sceneManager.currentScene
        let camera = scene?.currentCamera
        let viewMatrix = camera?.viewMatrix ?? matrix_identity_float4x4

        // Encoder Initialization
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(renderPipelineState)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setCullMode(MTLCullMode.back)
        encoder.setFrontFacing(MTLWinding.clockwise)

        // Vertex Shader
        encoder.setVertexBuffer(resourceManager.vertexAllocator.buffer, offset: 0, index: 0)
        
        func drawMesh(mesh: Mesh) {
            guard let vertexHandle = mesh.vertexHandle, let indexHandle = mesh.indexHandle else { return }

            var uniforms = RasterizerUniforms(
                mvpMatrix: projectionMatrix * viewMatrix * mesh.modelMatrix, 
                normalMatrix: mesh.normalMatrix
            )

            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RasterizerUniforms>.stride, index: 1)

            // Fragment Shader
            var material = mesh.baseMaterial ?? BaseMaterial(
                diffuseColor: Color4(1, 0, 0, 1), emissionColor: Color4(0, 0, 0, 1), 
                roughness: 1.0, metallic: 0.0, refractiveIndex: 1.0, 
                flags: MaterialFlags(rawValue: 0),
            )

            // Diffuse Texture
            encoder.setFragmentTexture(mesh.material.diffuseMTLTexture ?? resourceManager.defaultTexture.mtlTexture, index: 0)
            // Dissolve Texture
            encoder.setFragmentTexture(mesh.material.dissolveMTLTexture ?? resourceManager.defaultTexture.mtlTexture, index: 1) 
            encoder.setFragmentBytes(&material, length: MemoryLayout<BaseMaterial>.stride, index: 2)

            encoder.drawIndexedPrimitives(
                type: .triangle, 
                indexCount: indexHandle.count,
                indexType: MTLIndexType.uint32, 
                indexBuffer: indexHandle.parentAllocator?.buffer ?? resourceManager.indexAllocator.buffer, 
                indexBufferOffset: indexHandle.offset,
                instanceCount: 1,
                baseVertex: vertexHandle.index, 
                baseInstance: 0
            )
        }

        func distToCamera(_ mesh: Mesh) -> Float {
            let vertex = mesh.vertexHandle!.first!
            return length((sceneManager.currentScene?.currentCamera.position ?? simd_float3(0, 0, 0)) - vertex.position)
        }  

        if RasterizerConstants.logMeshCounts {
            print("OPA: \(opaqueMeshes.count), XLU: \(transparentMeshes.count)")
        }

        // Opaque Submeshes
        encoder.setDepthStencilState(opaqueDepthState)
        for mesh in opaqueMeshes { drawMesh(mesh: mesh) }

        // Transparent Submeshes
        encoder.setDepthStencilState(transparentDepthState)
        let sortedTransparentMeshes = transparentMeshes.sorted { distToCamera($0) > distToCamera($1) }
        for mesh in sortedTransparentMeshes { drawMesh(mesh: mesh) }

        encoder.endEncoding()

        commandBuffer.addCompletedHandler { cb in
            let gpuStartTime = cb.gpuStartTime
            let gpuEndTime = cb.gpuEndTime

            DispatchQueue.main.async {
                self.frameElapsedTime = (gpuEndTime - gpuStartTime) * 1000
                self.renderManager.inflightSemaphore.signal()
            }
             
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}