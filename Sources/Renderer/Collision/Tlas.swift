import simd
import Metal

/// Top Level Acceleration Structure
class Tlas {
    unowned let tlasNodeAllocator     : MTLBufferAllocator<RayTracerConstants.TlasNode>
    unowned let tlasInstanceAllocator : MTLBufferAllocator<TlasInstance>
    unowned let blasNodeAllocator     : MTLBufferAllocator<RayTracerConstants.BlasNode>
    unowned let meshTriAllocator      : MTLBufferAllocator<MeshTri>

    var tlasNodeHandle: MTLBufferAllocator<RayTracerConstants.TlasNode>.Handle? = nil
    var tlasInstanceHandle: MTLBufferAllocator<TlasInstance>.Handle? = nil

    init(
        device: MTLDevice,
        tlasNodeAllocator: MTLBufferAllocator<RayTracerConstants.TlasNode>,
        tlasInstanceAllocator: MTLBufferAllocator<TlasInstance>,
        blasNodeAllocator: MTLBufferAllocator<RayTracerConstants.BlasNode>,
        meshTriAllocator: MTLBufferAllocator<MeshTri>
    ) {
        self.tlasNodeAllocator = tlasNodeAllocator
        self.tlasInstanceAllocator = tlasInstanceAllocator
        self.blasNodeAllocator = blasNodeAllocator
        self.meshTriAllocator = meshTriAllocator
    }

    func reset() {
        tlasNodeHandle = nil
        tlasInstanceHandle = nil
    }

    /// Builds a BVH based on Median Split
    func build(meshes: [Mesh]) {
        reset()

        var tlasNodes: [RayTracerConstants.TlasNode] = []
        var tlasInstances: [TlasInstance] = []

        if RayTracerConstants.TlasNode.self == Tlas2Node.self {
            var tlas2Nodes: [Tlas2Node] = []
            buildBvh2(tlas2Nodes: &tlas2Nodes, tlasInstances: &tlasInstances, meshes: meshes)
            tlasNodes = tlas2Nodes as Any as! [RayTracerConstants.TlasNode]
           
        } else if RayTracerConstants.TlasNode.self == Tlas4Node.self {
            var tlas4Nodes: [Tlas4Node] = []
            buildBvh4(tlas4Nodes: &tlas4Nodes, tlasInstances: &tlasInstances, meshes: meshes)
            tlasNodes = tlas4Nodes as Any as! [RayTracerConstants.TlasNode]

        } else {
            fatalError("Invalid TlasNode type for RayTracerConstants.TlasNode")
        }

        tlasNodeHandle = tlasNodeAllocator.allocAndInit(count: tlasNodes.count, pointer: &tlasNodes)
        tlasInstanceHandle = tlasInstanceAllocator.allocAndInit(count: tlasInstances.count, pointer: &tlasInstances)
    }

    static func raycast(
        ray: Ray,
        nodeBuffer: MTLBufferAllocator<RayTracerConstants.TlasNode>, 
        tlasInstanceBuffer: MTLBufferAllocator<TlasInstance>, 
        blasNodeBuffer: MTLBufferAllocator<RayTracerConstants.BlasNode>, 
        triangleBuffer: MTLBufferAllocator<MeshTri>
    ) -> RaycastResult {
        if RayTracerConstants.TlasNode.self == Tlas2Node.self {
            var intersector = Tlas2Intersector(
                ray: ray, 
                nodeBuffer: nodeBuffer as Any as! MTLBufferAllocator<Tlas2Node>, 
                tlasInstanceBuffer: tlasInstanceBuffer, 
                blasNodeBuffer: blasNodeBuffer, 
                triangleBuffer: triangleBuffer, 
                baseNode: 0, 
                baseMeshTri: 0
            )
            return intersector.traverse()
        } else if RayTracerConstants.TlasNode.self == Tlas4Node.self {
            var intersector = Tlas4Intersector(
                ray: ray, 
                nodeBuffer: nodeBuffer as Any as! MTLBufferAllocator<Tlas4Node>, 
                tlasInstanceBuffer: tlasInstanceBuffer, 
                blasNodeBuffer: blasNodeBuffer, 
                triangleBuffer: triangleBuffer, 
                baseNode: 0, 
                baseMeshTri: 0
            )
            return intersector.traverse()
        } else {
            fatalError("")
        }
    }

    @discardableResult
    func buildBvh2(
        tlas2Nodes: inout [Tlas2Node], 
        tlasInstances: inout [TlasInstance],
        meshes: [Mesh]
    ) -> Int {
        let nodeIndex = tlas2Nodes.count
        var tlas2Node = Tlas2Node(aabb: AABB())
        tlas2Nodes.append(tlas2Node)
        defer { tlas2Nodes[nodeIndex] = tlas2Node }

        if meshes.count == 1 {
            let mesh = meshes[0]
            let tlasInstanceIndex = Int32(tlasInstances.count)
            tlas2Node.instanceIndex = tlasInstanceIndex

            var blas: Blas? = mesh.meshResource.blas
            if blas == nil {
                let newBlas = Blas(meshResourceHandle: mesh.meshResourceHandle)
                mesh.meshResource.blas = newBlas
                newBlas.build(blasNodeAllocator: blasNodeAllocator, meshTriAllocator: meshTriAllocator)
                blas = newBlas
            }

            guard let blas = blas else { return nodeIndex }
            tlasInstances.append(TlasInstance(
                modelMatrix: mesh.modelMatrix, 
                invModelMatrix: mesh.invModelMatrix, 
                baseBlasNode: Int32(blas.blasNodeHandle!.index),
                baseMeshTri: Int32(blas.meshTriHandle!.index),
                materialId: Int32(mesh.material.materialResource.materialHandle!.index)
            ))
            return nodeIndex
        }

        let bounds = AABB(from: meshes)
        let axis = bounds.longestAxis()
        let sortedMeshes = meshes.sorted { $0.pivot[axis] < $1.pivot[axis] }
        let middle = sortedMeshes.count / 2
        let leftMeshes = Array(sortedMeshes[..<middle])
        let rightMeshes = Array(sortedMeshes[middle...])

        // Build left child subtree
        if !leftMeshes.isEmpty {
            tlas2Node.leafIndices.x = Int32(buildBvh2(
                tlas2Nodes: &tlas2Nodes, 
                tlasInstances: &tlasInstances, 
                meshes: leftMeshes
            ))
        }

        // Build right child subtree
        if !rightMeshes.isEmpty {
            tlas2Node.leafIndices.y = Int32(buildBvh2(
                tlas2Nodes: &tlas2Nodes, 
                tlasInstances: &tlasInstances, 
                meshes: rightMeshes
            ))
        }

        return nodeIndex
    }

    @discardableResult 
    func buildBvh4(
        tlas4Nodes: inout [Tlas4Node], 
        tlasInstances: inout [TlasInstance], 
        meshes: [Mesh]
    ) -> Int {
        let nodeIndex = tlas4Nodes.count
        var tlas4Node = Tlas4Node(aabb4: AABB4())
        tlas4Nodes.append(tlas4Node)
        defer { tlas4Nodes[nodeIndex] = tlas4Node }

        func buildLeaf(mesh: Mesh, lane: Int) {
            tlas4Node.aabb4.minBoundsX[lane] = mesh.worldMinBounds.x
            tlas4Node.aabb4.minBoundsY[lane] = mesh.worldMinBounds.y
            tlas4Node.aabb4.minBoundsZ[lane] = mesh.worldMinBounds.z
            tlas4Node.aabb4.maxBoundsX[lane] = mesh.worldMaxBounds.x
            tlas4Node.aabb4.maxBoundsY[lane] = mesh.worldMaxBounds.y
            tlas4Node.aabb4.maxBoundsZ[lane] = mesh.worldMaxBounds.z

            let tlasInstanceIndex = Int32(tlasInstances.count)
            tlas4Node.instanceIndices[lane] = tlasInstanceIndex

            var blas: Blas? = mesh.meshResource.blas
            if blas == nil {
                let newBlas = Blas(meshResourceHandle: mesh.meshResourceHandle)
                mesh.meshResource.blas = newBlas
                newBlas.build(blasNodeAllocator: blasNodeAllocator, meshTriAllocator: meshTriAllocator)
                blas = newBlas
            }

            guard let blas = blas else { return }
            tlasInstances.append(TlasInstance(
                modelMatrix: mesh.modelMatrix, 
                invModelMatrix: mesh.invModelMatrix, 
                baseBlasNode: Int32(blas.blasNodeHandle!.index),
                baseMeshTri: Int32(blas.meshTriHandle!.index),
                // TODO: make this always link?
                materialId: Int32(mesh.material.materialResource.materialHandle!.index)
            ))
        }

        // No Subdividing
        if meshes.count <= 4 {
            for (lane, mesh) in meshes.enumerated() { buildLeaf(mesh: mesh, lane: lane) }
            return nodeIndex
        }
    
        // Subdividing
        func splitMedian(meshes: [Mesh]) -> (left: [Mesh], right: [Mesh]) {
            let bounds = AABB(from: meshes)
            let axis = bounds.longestAxis()
            let sortedMeshes = meshes.sorted { $0.pivot[axis] < $1.pivot[axis] }
            let middle = sortedMeshes.count / 2
            let left = Array(sortedMeshes[..<middle])
            let right = Array(sortedMeshes[middle...])
            return (left: left, right: right)
        }

        let (left, right) = splitMedian(meshes: meshes)
        let (partition0, partition1) = splitMedian(meshes: left)
        let (partition2, partition3) = splitMedian(meshes: right)

        for (lane, partition) in [partition0, partition1, partition2, partition3].enumerated() {
            if partition.count > 1 { // Becomes a branch
                let bounds = AABB(from: partition)
                tlas4Node.aabb4.minBoundsX[lane] = bounds.minBounds.x
                tlas4Node.aabb4.minBoundsY[lane] = bounds.minBounds.y
                tlas4Node.aabb4.minBoundsZ[lane] = bounds.minBounds.z
                tlas4Node.aabb4.maxBoundsX[lane] = bounds.maxBounds.x
                tlas4Node.aabb4.maxBoundsY[lane] = bounds.maxBounds.y
                tlas4Node.aabb4.maxBoundsZ[lane] = bounds.maxBounds.z
                tlas4Node.leafIndices[lane] = Int32(buildBvh4(tlas4Nodes: &tlas4Nodes, tlasInstances: &tlasInstances, meshes: partition))
            } else { // Becomes a Leaf
                buildLeaf(mesh: partition[0], lane: lane)
            }
        }

        return nodeIndex
    }

    func reform() {
        fatalError("Tlas.reform() is unimplemented!")
    }
}

struct Tlas2Node : Bvh2Node {
    var aabb            : AABB
    var leafIndices     : simd_int2 = [-1, -1]
    var instanceIndex   : simd_int1 = -1
}

struct Tlas4Node : Bvh4Node {
    var aabb4           : AABB4
    var leafIndices     : simd_int4 = [-1, -1, -1, -1]
    var instanceIndices : simd_int4 = [-1, -1, -1, -1]
}

struct TlasInstance {
    var modelMatrix     : simd_float4x4
    var invModelMatrix  : simd_float4x4
    var baseBlasNode    : Int32
    var baseMeshTri     : Int32
    var materialId      : Int32
}

struct Tlas2Intersector : Bvh2Intersector {
    var ray                : Ray                               
    var raycastResult      : RaycastResult = RaycastResult()         

    var nodeBuffer         : MTLBufferAllocator<Tlas2Node>
    var tlasInstanceBuffer : MTLBufferAllocator<TlasInstance>
    var blasNodeBuffer     : MTLBufferAllocator<RayTracerConstants.BlasNode>
    var triangleBuffer     : MTLBufferAllocator<MeshTri>
    var baseNode           : Int32
    var baseMeshTri        : Int32

    func intersectsNode(_ node: Tlas2Node) -> Bool {
        return ray.intersectsAABBWithSmallerT(node.aabb, t: raycastResult.distance)
    }

    mutating func processLeaf(_ node: Tlas2Node) {
        let instanceIndex = node.instanceIndex

        if instanceIndex == -1 {
            return
        }
        
        guard let tlasInstance = tlasInstanceBuffer[Int(instanceIndex)] else {
            fatalError("Missing TlasInstance in MTLBuffer with index: \(instanceIndex)")
        }

        let origin4 = simd_float4(ray.origin, 1.0)
        let direction4 = simd_float4(ray.direction, 0.0)
        let localOrigin4 = tlasInstance.invModelMatrix * origin4
        let localOrigin3 = simd_float3(localOrigin4.x, localOrigin4.y, localOrigin4.z)
        let localDirection4 = tlasInstance.invModelMatrix * direction4
        let localDirection3 = simd_normalize(simd_float3(localDirection4.x, localDirection4.y, localDirection4.z))

        var blasResult = Blas.raycast(
            ray: Ray(origin: localOrigin3, direction: localDirection3), 
            nodeBuffer: blasNodeBuffer, 
            triangleBuffer: triangleBuffer,
            baseNode: tlasInstance.baseBlasNode,
            baseMeshTri: tlasInstance.baseMeshTri
        )

        if blasResult.didHit() {
            let worldHit = simd_make_float3(tlasInstance.modelMatrix * simd_float4(simd_make_float3(blasResult.hit), 1.0))
            blasResult.distance = simd_length(worldHit - ray.origin)
            blasResult.materialId = tlasInstance.materialId
            blasResult.instanceId = instanceIndex

            if blasResult.distance < raycastResult.distance {
                blasResult.hit = worldHit
                raycastResult = blasResult
            }
        }
    }
}

struct Tlas4Intersector : Bvh4Intersector {
    var ray                : Ray                               
    var raycastResult      : RaycastResult = RaycastResult()                 

    var nodeBuffer         : MTLBufferAllocator<Tlas4Node>
    var tlasInstanceBuffer : MTLBufferAllocator<TlasInstance>
    var blasNodeBuffer     : MTLBufferAllocator<RayTracerConstants.BlasNode>
    var triangleBuffer     : MTLBufferAllocator<MeshTri>
    var baseNode           : Int32
    var baseMeshTri        : Int32

    func intersectsNode(_ node: Tlas4Node) -> simd_float4 {
        return ray.intersectsAABB4WithSmallerT(node.aabb4, t: raycastResult.distance)
    }

    mutating func processLeaf(_ node: Tlas4Node, lane: Int) {
        let instanceIndex = node.instanceIndices[lane]

        if instanceIndex == -1 {
            return
        }

        guard let tlasInstance = tlasInstanceBuffer[Int(instanceIndex)] else {
            fatalError("Missing TlasInstance in MTLBuffer with index: \(instanceIndex)")
        }

        let origin4 = simd_float4(ray.origin, 1.0)
        let direction4 = simd_float4(ray.direction, 0.0)
        let localOrigin4 = tlasInstance.invModelMatrix * origin4
        let localOrigin3 = simd_float3(localOrigin4.x, localOrigin4.y, localOrigin4.z)
        let localDirection4 = tlasInstance.invModelMatrix * direction4
        let localDirection3 = simd_normalize(simd_float3(localDirection4.x, localDirection4.y, localDirection4.z))

        var blasResult = Blas.raycast(
            ray: Ray(origin: localOrigin3, direction: localDirection3), 
            nodeBuffer: blasNodeBuffer, 
            triangleBuffer: triangleBuffer,
            baseNode: tlasInstance.baseBlasNode,
            baseMeshTri: tlasInstance.baseMeshTri
        )

        if blasResult.didHit() {
            let worldHit = simd_make_float3(tlasInstance.modelMatrix * simd_float4(simd_make_float3(blasResult.hit), 1.0))
            blasResult.distance = simd_length(worldHit - ray.origin)
            blasResult.materialId = tlasInstance.materialId
            blasResult.instanceId = instanceIndex

            if blasResult.distance < raycastResult.distance {
                blasResult.hit = worldHit
                raycastResult = blasResult
            }
        }
    }
}