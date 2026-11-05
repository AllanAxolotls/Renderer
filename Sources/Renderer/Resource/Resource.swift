import Foundation
import QuartzCore

enum ResourceLoadState {
    case unloaded
    case loading
    case loaded
    case failed
}

class Resource: @unchecked Sendable {
    private var evictionAfterInterval: CFTimeInterval
    var lock: NSLock = NSLock()
    var referenceCount: Int { didSet {
        if referenceCount == 0 { 
            self.evictionTime = CACurrentMediaTime().advanced(by: evictionAfterInterval) 
        }
    } }
    var evictionTime: CFTimeInterval? = nil
    
    /// If the ResourceManager is allowed to evict this resource when the ReferenceCount hits 0
    var evictable: Bool = true

    let name: String
    var assetURL: URL?
    var cacheKey: String
    var isPersistent: Bool = false

    private(set) var loadState: ResourceLoadState = .unloaded

    init(name: String = "Default Resource", assetURL: URL? = nil) {
        print("New Resource \(name) url: \(assetURL?.path ?? "No Path")")
        self.name = name
        self.referenceCount = 0
        self.evictionAfterInterval = 5
        self.assetURL = assetURL
        self.cacheKey = assetURL?.absoluteString ?? UUID().uuidString
    }

    deinit { destroy() }

    func load() throws {
        guard loadState == .unloaded else { return }
        loadState = .loading
        
        do {
            try performLoad()
            loadState = .loaded
        } catch {
            loadState = .failed
            throw error
        }
    }

    func performLoad() throws {}

    func unload() {
        loadState = .unloaded
    }

    func destroy() {
        print("Destroying Resource named: \(name) with assetURL: \(assetURL?.path ?? "No Path")")
        unload()
    }

    func incrementReferenceCount() {
        lock.lock()
        defer { lock.unlock() }
        referenceCount += 1
        self.evictionTime = nil
    }

    func decrementReferenceCount() {
        lock.lock()
        defer { lock.unlock() }
        referenceCount = max(0, referenceCount - 1)
    }
}

class WeakResource : Hashable {
    weak var resource: Resource? = nil
    let objectID: ObjectIdentifier

    init(_ resource: Resource) { 
        self.resource = resource 
        self.objectID = ObjectIdentifier(resource)
    }

    static func == (lhs: WeakResource, rhs: WeakResource) -> Bool {
        return lhs.objectID == rhs.objectID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(objectID)
    }
}

class ResourceHandle<T: Resource>: @unchecked Sendable {
    let resource: T
    
    init(_ resource: T) {
        self.resource = resource
        resource.incrementReferenceCount()
    }
    
    deinit { 
        resource.decrementReferenceCount() 
    }
}
