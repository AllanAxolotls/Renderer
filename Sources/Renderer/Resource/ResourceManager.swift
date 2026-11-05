import Foundation
import Metal
import QuartzCore
import Combine
import simd

final class ResourceManager: @unchecked Sendable {
    private unowned let device: MTLDevice
    private let queue = DispatchQueue(label: "engine.resourcemanager.queue", attributes: .concurrent)

    // Cached based on assetURL (faster)
    private var cache: [String : Resource] = [:] 

    // Cached but needs a for-loop for equality check
    var cachedMeshResources: [MeshResource] = []
    var cachedMaterialResources: [MaterialResource] = []

    let vertexAllocator   : MTLBufferAllocator<Vertex>
    let indexAllocator    : MTLBufferAllocator<UInt32>
    let materialAllocator : MTLBufferAllocator<BaseMaterial>
    let textureSlotCollection : SlotCollection<MTLTexture> = SlotCollection()

    var defaultTexture  : Texture!
    var defaultMaterial : Material!

    let objectLoadedPublisher   = PassthroughSubject<MeshLibraryResource, Never>()
    let materialLoadedPublisher = PassthroughSubject<MaterialLibraryResource, Never>()
    let textureLoadedPublisher  = PassthroughSubject<TextureResource, Never>()

    let intervalBetweenEvictChecks: CFTimeInterval = 5
    var upcomingEvictCheckAtTime: CFTimeInterval

    init(device: MTLDevice) {
        self.device = device
        self.vertexAllocator   = MTLBufferAllocator(device: device, initialCount: 100)
        self.indexAllocator    = MTLBufferAllocator(device: device, initialCount: 100)
        self.materialAllocator = MTLBufferAllocator(device: device, initialCount: 10)

        upcomingEvictCheckAtTime = CACurrentMediaTime().advanced(by: intervalBetweenEvictChecks)

        // Load Default Texture
        do {
            self.defaultTexture = try loadTexture(url: URL(fileURLWithPath: "Assets/.Core/DefaultTexture.png"))
        } catch { 
            fatalError("Failed to load default texture, \(error)")
        }

        // Load Default Material
        do {
            let materialLibraryResourceHandle: ResourceHandle<MaterialLibraryResource> = try loadMaterialLibraryResource(url: URL(fileURLWithPath: "Assets/.Core/DefaultMaterial.mtl"))
            let materialLibraryResource: MaterialLibraryResource = materialLibraryResourceHandle.resource
            materialLibraryResource.evictable = false

            if let defaultMaterial = materialLibraryResource.getMaterialByName("DefaultMaterial") {
                self.defaultMaterial = defaultMaterial
            } else {
                throw NSError(domain: "ResourceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Default MaterialResource does not exist!"])
            }
        } catch { 
            fatalError("Failed to load default material, \(error)") 
        }
    }

    deinit {
        // In the case that the ResourceManager gets deinitialized before the resources, deactivate them
        cachedMeshResources.removeAll()
        cachedMaterialResources.removeAll()
        cache.removeAll()
    }

    func clearCache() {
        queue.async(flags: .barrier) { self.cache.removeAll() }
    }

    func evictUnusedResources() {
        let now = CACurrentMediaTime()

        func evictable(_ resource: Resource) -> Bool {
            guard let evictionTime = resource.evictionTime else { return false }
            guard resource.evictable else { return false }
            return now >= evictionTime
        }

        let resourcesToEvict: [Resource] = queue.sync {
            let cacheValues = Array(cache.values)
            let combinedList = cacheValues + cachedMeshResources + cachedMaterialResources
            return combinedList.filter { $0.referenceCount == 0 && evictable($0) }
        }

        for resource in resourcesToEvict {
            removeResource(resource)
        }
    }

    func removeResource(_ resource: Resource) {
        resource.destroy()

        queue.async(flags: .barrier) {
            if let resource = resource as? MeshResource { 
                self.cachedMeshResources.removeAll { $0 === resource }
            } else if let resource = resource as? MaterialResource {
                self.cachedMaterialResources.removeAll { $0 === resource }
            }
            if let url = resource.assetURL {
                self.cache.removeValue(forKey: url.absoluteString)
            }
        }
    }


    func update(deltaTime: CFTimeInterval) {
        let now = CACurrentMediaTime()
        if now >= upcomingEvictCheckAtTime {
            upcomingEvictCheckAtTime = now.advanced(by: intervalBetweenEvictChecks)
            evictUnusedResources()
        }
    }
}

// Resource Loading
extension ResourceManager {
    func loadMeshLibraryResource(url: URL) throws -> ResourceHandle<MeshLibraryResource> {
        let key = url.absoluteString

        if let cachedResource = queue.sync(execute: { cache[key] }) as? MeshLibraryResource {
            return ResourceHandle(cachedResource)
        }

        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let resource: MeshLibraryResource

        // TODO: add .fbx and others in the future
        switch ext {
        case "obj": 
            resource = MeshLibraryResource(from: self, name: fileName, assetURL: url)
        default:
            throw NSError(domain: "ResourceManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unsupported file extension: .\(ext)"])
        }

        try resource.load()
        Task { @MainActor in objectLoadedPublisher.send(resource) }
        queue.async(flags: .barrier) { self.cache[key] = resource }
        return ResourceHandle(resource)
    }


    func loadMaterialLibraryResource(url: URL) throws -> ResourceHandle<MaterialLibraryResource> {
        let key = url.absoluteString

        if let cachedResource = queue.sync(execute: { cache[key] }) as? MaterialLibraryResource {
            return ResourceHandle(cachedResource)
        }

        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let resource: MaterialLibraryResource

        switch ext {
        case "mtl": 
            resource = MaterialLibraryResource(from: self, name: fileName, assetURL: url)
        default:
            throw NSError(domain: "ResourceManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unsupported file extension: .\(ext)"])
        }

        try resource.load()
        Task { @MainActor in materialLoadedPublisher.send(resource) }
        queue.async(flags: .barrier) { self.cache[key] = resource }
        return ResourceHandle(resource)
    }
    

    func loadTextureResource(url: URL) throws -> ResourceHandle<TextureResource> {
        let key = url.absoluteString

        if let cachedResource = queue.sync(execute: { cache[key] }) as? TextureResource {
            return ResourceHandle(cachedResource)
        }

        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let resource: TextureResource

        switch ext {
        case "png", "jpg", "jpeg": 
            resource = TextureResource(device: device, from: self, name: fileName, assetURL: url)
        default:
            throw NSError(domain: "ResourceManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unsupported file extension: .\(ext)"])
        }

        try resource.load()
        Task { @MainActor in textureLoadedPublisher.send(resource) }
        queue.async(flags: .barrier) { self.cache[key] = resource }
        return ResourceHandle(resource)
    }

    func loadTexture(url: URL) throws -> Texture {
        let resourceHandle = try loadTextureResource(url: url)
        return Texture(textureResourceHandle: resourceHandle)
    }
}

// Asynchronous Loading Wrappers
extension ResourceManager {
    func loadMeshLibraryResourceAsync(url: URL) async throws -> ResourceHandle<MeshLibraryResource> {
        return try await Task.detached(priority: .userInitiated) {
            return try self.loadMeshLibraryResource(url: url)
        }.value
    }

    func loadMaterialLibraryResourceAsync(url: URL) async throws -> ResourceHandle<MaterialLibraryResource> {
        return try await Task.detached(priority: .userInitiated) {
            return try self.loadMaterialLibraryResource(url: url)
        }.value
    }

    func loadTextureResourceAsync(url: URL) async throws -> ResourceHandle<TextureResource> {
        return try await Task.detached(priority: .userInitiated) {
            return try self.loadTextureResource(url: url)
        }.value
    }

    func loadTextureAsync(url: URL) async throws -> Texture {
        return try await Task.detached(priority: .userInitiated) {
            return try self.loadTexture(url: url)
        }.value
    }
}

// Resource Matching & Cacheing
extension ResourceManager {
    func getEquivalentMeshResource(with desc: MeshResourceDescription) -> (MeshResource, simd_float4x4)? {
        for meshResource in self.cachedMeshResources {
            if let transform = meshResource.findTransform(to: desc) {
                return (meshResource, transform)
            }
        }
        return nil
    }

    func getEquivalentMaterialResource(with desc: MaterialResourceDescription) -> MaterialResource? {
        return self.cachedMaterialResources.first(where: { $0.matchesDescription(desc: desc) })
    }
}