import Metal
import MetalKit
import simd

let usePrivateBuffers: Bool = false

public enum RenderMode {
    case Rasterizer
    case RayTracer
}

public struct RasterizerUniforms {
    public var mvpMatrix: simd_float4x4
    public var normalMatrix: simd_float3x3
}

public struct RayTracerUniforms {
    let sampleIndex: Int32
    var tileOffset: simd_uint2
    let fovScale: Float
    let cameraPosition: simd_float3
    let cameraForward: simd_float3
    let cameraUp: simd_float3
    let cameraRight: simd_float3
}

public func updateBuffer<T>(
    device: MTLDevice,
    _ buffer: inout MTLBuffer?,
    with elements: [T],
    options: MTLResourceOptions = .storageModeShared
) {
    guard !elements.isEmpty else { buffer = nil; return }
    let requiredBytes = MemoryLayout<T>.stride * elements.count

    if let existing = buffer, existing.length >= requiredBytes && existing.length <= requiredBytes * 2 {
        let _ = elements.withUnsafeBufferPointer { ptr in memcpy(existing.contents(), ptr.baseAddress!, requiredBytes) }
    } else {
        let targetCapacity = Int(Double(requiredBytes) * 1.25)
        guard let newBuffer = device.makeBuffer(length: targetCapacity, options: options) else { buffer = nil; return }
        let _ = elements.withUnsafeBufferPointer { ptr in memcpy(newBuffer.contents(), ptr.baseAddress!, requiredBytes) }
        buffer = newBuffer
    }
}

public func uploadPrivate<T>(_ data: [T], device: MTLDevice, commandQueue: MTLCommandQueue) -> MTLBuffer? {
    let size = MemoryLayout<T>.stride * data.count

    guard let staging = data.withUnsafeBytes({ rawBuffer in
        device.makeBuffer(bytes: rawBuffer.baseAddress!, length: size, options: .storageModeShared)
    }) else { return nil }
    guard let buffer = device.makeBuffer(length: size, options: .storageModePrivate) else { return nil }

    let commandBuffer = commandQueue.makeCommandBuffer()!
    let blit = commandBuffer.makeBlitCommandEncoder()!

    blit.copy(from: staging, sourceOffset: 0, to: buffer, destinationOffset: 0, size: size)
    blit.endEncoding()
    commandBuffer.commit()

    return buffer
}


@MainActor final class RenderHandler {
    public var rasterRenderer: RasterRenderer
    public var rayTracerRenderer: RayTracerRenderer
    public var currentRenderMode: RenderMode = .Rasterizer

    // Shared between Renderers
    public var device: MTLDevice
    public var scene: Scene? = nil
    private var commandQueue: MTLCommandQueue
    private var vertexBuffer: MTLBuffer? = nil
    private var materialDataBuffer: MTLBuffer? = nil

    init(device: MTLDevice, scene: Scene? = nil) {
        self.rasterRenderer = RasterRenderer(device: device, scene: scene)
        self.rayTracerRenderer = RayTracerRenderer(device: device, scene: scene)
        self.device = device
        self.scene = scene
        self.commandQueue = device.makeCommandQueue()!
    }

    public func setScene(_ scene: Scene?) {
        self.scene = scene
        rasterRenderer.scene = self.scene
        rayTracerRenderer.scene = self.scene
    }

    public func switchRenderMode() {
        switch currentRenderMode {
            case .Rasterizer: currentRenderMode = .RayTracer
            case .RayTracer: currentRenderMode = .Rasterizer
        }
    }

    public func flipRayTracerPaused() {
        rayTracerRenderer.isPaused = !rayTracerRenderer.isPaused
    }

    public func draw(in view: MTKView) {
        // Update Dirty Stuff
        if let scene = self.scene {
            if scene.dirtyFlags.flags[DirtyFlagType.Vertices.rawValue] == true { 
                if usePrivateBuffers { vertexBuffer = uploadPrivate(scene.vertices, device: device, commandQueue: commandQueue) }
                else { updateBuffer(device: device, &vertexBuffer, with: scene.vertices) }
                scene.dirtyFlags.flags[DirtyFlagType.Vertices.rawValue] = false
            }

            if scene.dirtyFlags.flags[DirtyFlagType.Indices.rawValue] == true {
                rasterRenderer.updateIndexBuffer()
                scene.dirtyFlags.flags[DirtyFlagType.Indices.rawValue] = false
            }

            if scene.dirtyFlags.flags[DirtyFlagType.MaterialDatas.rawValue] == true {
                scene.dirtyFlags.ignoreTLASMakeDirties = true
                if let textureHandler = scene.textureHandler {
                    print("Updating Materials")
                    
                    for (index, material) in scene.materials.enumerated() {
                        scene.materialDatas[index].diffuseTextureIndex = material.diffuseTexturePath == nil
                            ? 0
                            : UInt16(textureHandler.getTextureIndex(texturePath: material.diffuseTexturePath!.path))
                        scene.materialDatas[index].dissolveTextureIndex = material.dissolveTexturePath == nil
                            ? -1
                            : textureHandler.getTextureIndex(texturePath: material.dissolveTexturePath!.path)
                    }
                }
                if usePrivateBuffers { rayTracerRenderer.updateMaterialDataBuffer(commandQueue) } else { rayTracerRenderer.updateMaterialDataBuffer() }
                scene.dirtyFlags.flags[DirtyFlagType.MaterialDatas.rawValue] = false
                scene.dirtyFlags.ignoreTLASMakeDirties = false
            }

            if scene.dirtyFlags.flags[DirtyFlagType.Meshes.rawValue] == true {
                rasterRenderer.updateDrawlists()
                scene.dirtyFlags.flags[DirtyFlagType.Meshes.rawValue] = false
            }

            if scene.dirtyFlags.flags[DirtyFlagType.RebuildTLAS.rawValue] == true {
                view.window?.title = "Building Acceleration Structure..."
                scene.tlas.build(scene: scene) // TODO: change to reform when reform is implemented
                scene.dirtyFlags.flags[DirtyFlagType.RebuildTLAS.rawValue] = false
            }

            if scene.dirtyFlags.flags[DirtyFlagType.UpdateTLAS.rawValue] == true {
                if usePrivateBuffers {
                    rayTracerRenderer.updateBLASBuffers(commandQueue)
                    rayTracerRenderer.updateTLASBuffers(commandQueue)
                } else {
                    rayTracerRenderer.updateBLASBuffers()
                    rayTracerRenderer.updateTLASBuffers()
                }
               
                rayTracerRenderer.updateTextureCollectionBuffer()
                scene.dirtyFlags.flags[DirtyFlagType.UpdateTLAS.rawValue] = false
            }
        }

        switch currentRenderMode {
            case .Rasterizer: rasterRenderer.draw(view: view, commandQueue: commandQueue, vertexBuffer: vertexBuffer)
            case .RayTracer: rayTracerRenderer.draw(view: view, commandQueue: commandQueue, vertexBuffer: vertexBuffer)
        }
    }
}

