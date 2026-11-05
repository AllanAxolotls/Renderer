import Foundation
import Metal
import Combine

final class Scene : Object {
    lazy var currentCamera = Camera(name: "Camera", parent: self)

    private(set) var renderableMeshes = Set<Mesh>()
    private(set) var queryableMeshes  = Set<Mesh>()

    private var cancellables = Set<AnyCancellable>()
    let updatedRenderableMeshesPublisher = PassthroughSubject<Void, Never>()
    
    // TODO: make it so when canQuery of a mesh changes, it gets removed
    // Also add a setting to meshes canRender or something similar
    init(name: String = "Scene") {
        super.init(name: name)

        childAddedPublisher.sink { [weak self] child in 
            if let mesh = child as? Mesh { self?.meshAdded(mesh) }
            for mesh: Mesh in child.descendants.filter({ $0 is Mesh }) as! [Mesh] { self?.meshAdded(mesh) }
            self?.updatedRenderableMeshesPublisher.send()
        }.store(in: &cancellables)

        childRemovedPublisher.sink { [weak self] child in
            if let mesh = child as? Mesh { self?.meshRemoved(mesh) }
            for mesh: Mesh in child.descendants.filter({ $0 is Mesh }) as! [Mesh] { self?.meshRemoved(mesh) }
            self?.updatedRenderableMeshesPublisher.send()
        }.store(in: &cancellables)
    }

    private func meshAdded(_ mesh: Mesh) {
        renderableMeshes.insert(mesh)
        if mesh.canQuery { queryableMeshes.insert(mesh) }
    }

    private func meshRemoved(_ mesh: Mesh) {
        renderableMeshes.remove(mesh)
        queryableMeshes.remove(mesh)
    }
}