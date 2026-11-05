import Metal
import MetalKit
import Foundation

public enum RenderMode {
    case Rasterizer
    case RayTracer
}

@MainActor final class RenderManager {
    private unowned let device: MTLDevice
    private unowned let sceneManager: SceneManager
    private unowned let resourceManager: ResourceManager
    private unowned let collisionManager: CollisionManager
    private unowned let inputController: InputController

    let commandQueue: MTLCommandQueue
    var sampler: MTLSamplerState!
    var inflightSemaphore = DispatchSemaphore(value: 2)

    var rasterizer: Rasterizer!
    var rayTracer: RayTracer!

    public var renderMode: RenderMode = .Rasterizer
    public var gameScreenSize: CGSize = CGSize(width: WindowConstants.initialWidth, height: WindowConstants.initialHeight) { 
        didSet { rasterizer.dirtyFlags.insert(.projectionMatrix) } 
    }

    init(
        device: MTLDevice,
        sceneManager: SceneManager,
        resourceManager: ResourceManager,
        collisionManager: CollisionManager,
        inputController: InputController
    ) {
        self.device = device
        self.sceneManager = sceneManager
        self.resourceManager = resourceManager
        self.collisionManager = collisionManager
        self.inputController = inputController

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create MTLCommandQueue. Check your MTLDevice initialization.")
        }
        self.commandQueue = commandQueue

        initSampler()
        initRasterizer()
        initRayTracer()
    }

    var lastTitleUpdateTimestamp: CFTimeInterval = 0.0
    var titleUpdateInterval: CFTimeInterval = 0.25
    public func render(in view: MTKView) {
        if inputController.renderModeDirty {
            inputController.renderModeDirty = false
            lastTitleUpdateTimestamp = 0.0

            switch renderMode {
                case .Rasterizer: renderMode = .RayTracer
                case .RayTracer:  renderMode = .Rasterizer
            }
        }

        if inputController.pausedDirty {
            inputController.pausedDirty = false
            if renderMode == .RayTracer {
                rayTracer.isPaused = !rayTracer.isPaused
            }
        }

        switch renderMode { 
            case .Rasterizer: rasterizer.render (in: view)
            case .RayTracer:  rayTracer.render  (in: view)
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTitleUpdateTimestamp >= titleUpdateInterval {
            lastTitleUpdateTimestamp = now

            if let window = view.window {
                let title: String
                switch renderMode {
                    case .Rasterizer: 
                        title = String(format: "[ Rasterizer | GPU: %.2f ms ]", rasterizer.frameElapsedTime)
                    case .RayTracer:
                        if rayTracer.isPaused {
                            title = String(format: "[ RayTracer (Paused) (%d / %d) | GPU: %.2f ms, Avg: %.2f ms, Total: %.2f ms ]", rayTracer.sampleIndex, RayTracerConstants.maxSampleCount, rayTracer.frameElapsedTime,  rayTracer.averageElapsedTime, rayTracer.totalElapsedTime)
                        } else {
                            title = String(format: "[ RayTracer (%d / %d) | GPU: %.2f ms, Avg: %.2f ms, Total: %.2f ms ]", rayTracer.sampleIndex, RayTracerConstants.maxSampleCount, rayTracer.frameElapsedTime,  rayTracer.averageElapsedTime, rayTracer.totalElapsedTime)
                        }
                }

                window.title = title
            }
        }
    }
}

extension RenderManager {
    func initSampler() {
        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .repeat
        sampDesc.tAddressMode = .repeat
        self.sampler = device.makeSamplerState(descriptor: sampDesc)!
    }

    func initRasterizer() {
        rasterizer = Rasterizer(
            device: device,
            sceneManager: sceneManager,
            renderManager: self,
            resourceManager: resourceManager,
            commandQueue: commandQueue
        )

        let rasterizerLib = try! device.makeLibrary(URL: URL(fileURLWithPath: "Resources/Rasterizer.metallib"))
        let renderPipelineDesc = MTLRenderPipelineDescriptor()
        renderPipelineDesc.vertexFunction = rasterizerLib.makeFunction(name: "vmain")!
        renderPipelineDesc.fragmentFunction = rasterizerLib.makeFunction(name: "fmain")!

        let colorAttachment = renderPipelineDesc.colorAttachments[0]!
        colorAttachment.pixelFormat = .bgra8Unorm_srgb
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        rasterizer.sampler = sampler
        rasterizer.renderPipelineState = try! device.makeRenderPipelineState(descriptor: renderPipelineDesc)
    }

    func initRayTracer() {
        rayTracer = RayTracer(
            device: device, 
            renderManager: self,
            resourceManager: resourceManager,
            sceneManager: sceneManager,
            collisionManager: collisionManager,
            commandQueue: commandQueue
        )

        let rayTracerLib = try! device.makeLibrary(URL: URL(fileURLWithPath: "Resources/RayTracer.metallib"))
        let rayTraceFunction = rayTracerLib.makeFunction(name: "raytrace")!
        let textureArgumentEncoder = rayTraceFunction.makeArgumentEncoder(bufferIndex: RayTracerConstants.textureBufferIndex)

        let textureBuffer = device.makeBuffer(length: textureArgumentEncoder.encodedLength, options: [])!
        textureArgumentEncoder.setArgumentBuffer(textureBuffer, offset: 0)
        textureArgumentEncoder.setSamplerState(sampler, index: 0)

        let textures: [MTLTexture] = [] // TODO: make this get textures from ResourceManager
        textureArgumentEncoder.setTextures(textures, range: 1 ..< textures.count + 1)

        let upscaleLib = try! device.makeLibrary(URL: URL(fileURLWithPath: "Resources/Upscale.metallib"))
        let renderPipelineDesc = MTLRenderPipelineDescriptor()
        renderPipelineDesc.vertexFunction = upscaleLib.makeFunction(name: "fullscreenVertex")!
        renderPipelineDesc.fragmentFunction = upscaleLib.makeFunction(name: "upscaleFragment")!
        renderPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge

        rayTracer.textureArgumentEncoder = textureArgumentEncoder
        rayTracer.textureBuffer = textureBuffer
        rayTracer.computePipelineState = try! device.makeComputePipelineState(function: rayTraceFunction)
        rayTracer.renderPipelineState = try! device.makeRenderPipelineState(descriptor: renderPipelineDesc)
        rayTracer.upscaleSampler = device.makeSamplerState(descriptor: sampDesc)!
    }
}