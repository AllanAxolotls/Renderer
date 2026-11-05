import Combine
import Metal

final class CollisionManager {
    private unowned let device: MTLDevice
    private unowned let sceneManager: SceneManager

    let tlasNodeAllocator     : MTLBufferAllocator<RayTracerConstants.TlasNode>
    let tlasInstanceAllocator : MTLBufferAllocator<TlasInstance>
    let blasNodeAllocator     : MTLBufferAllocator<RayTracerConstants.BlasNode>
    let meshTriAllocator      : MTLBufferAllocator<MeshTri>

    let tlas: Tlas
    var cancellables = Set<AnyCancellable>()

    @MainActor init(
        device: MTLDevice,
        sceneManager: SceneManager
    ) {
        self.device = device
        self.sceneManager = sceneManager
       
        self.tlasNodeAllocator     = MTLBufferAllocator<RayTracerConstants.TlasNode>    (device: device, initialCount: 10 )
        self.tlasInstanceAllocator = MTLBufferAllocator<TlasInstance>                   (device: device, initialCount: 10 )
        self.meshTriAllocator      = MTLBufferAllocator<MeshTri>                        (device: device, initialCount: 100)
        self.blasNodeAllocator     = MTLBufferAllocator<RayTracerConstants.BlasNode>    (device: device, initialCount: 4  )

        self.tlas = Tlas(
            device: device,
            tlasNodeAllocator: tlasNodeAllocator,
            tlasInstanceAllocator: tlasInstanceAllocator,
            blasNodeAllocator: blasNodeAllocator,
            meshTriAllocator: meshTriAllocator
        )

        // TODO: make a separate publisher for this sort of stuff
        //sceneManager.sceneSwitchedPublisher.sink { scene in self.buildTlas()}.store(in: &cancellables)
        //sceneManager.sceneChildAddedPublisher.sink { object in self.buildTlas()}.store(in: &cancellables)
        //sceneManager.sceneChildRemovedPublisher.sink { object in self.buildTlas()}.store(in: &cancellables)
    }

    func buildTlas() {
        tlas.build(meshes: Array(sceneManager.currentScene?.queryableMeshes ?? []))
    }

    func raycast(ray: Ray) -> RaycastResult {
        return Tlas.raycast(
            ray: ray, 
            nodeBuffer: tlasNodeAllocator, 
            tlasInstanceBuffer: tlasInstanceAllocator, 
            blasNodeBuffer: blasNodeAllocator, 
            triangleBuffer: meshTriAllocator
        )
    }
}