import Metal
import simd

/// Bottom Level Acceleration Structure
class Blas {
    let meshResourceHandle: ResourceHandle<MeshResource>

    var blasNodeHandle: MTLBufferAllocator<RayTracerConstants.BlasNode>.Handle? = nil
    var meshTriHandle: MTLBufferAllocator<MeshTri>.Handle? = nil
    
    init(meshResourceHandle: ResourceHandle<MeshResource>) {
        self.meshResourceHandle = meshResourceHandle
    }

    func reset() {
        blasNodeHandle = nil
        meshTriHandle = nil
    }

    func build(
        blasNodeAllocator: MTLBufferAllocator<RayTracerConstants.BlasNode>,
        meshTriAllocator: MTLBufferAllocator<MeshTri>
    ) {
        reset()

        guard let vertexHandle = meshResourceHandle.resource.vertexHandle,
              let indexHandle = meshResourceHandle.resource.indexHandle else { return }

        var triangles: [MeshTri] = []
        let baseVertex = vertexHandle.index
        for i in stride(from: 0, to: indexHandle.count, by: 3) {
            let localIdx0 = indexHandle[i + 0]!
            let localIdx1 = indexHandle[i + 1]!
            let localIdx2 = indexHandle[i + 2]!
            
            let globalIdx0 = Int(localIdx0) + baseVertex
            let globalIdx1 = Int(localIdx1) + baseVertex
            let globalIdx2 = Int(localIdx2) + baseVertex
            
            let vertexAllocator = vertexHandle.parentAllocator!
            let vertex0 = vertexAllocator[globalIdx0]!
            let vertex1 = vertexAllocator[globalIdx1]!
            let vertex2 = vertexAllocator[globalIdx2]!

            triangles.append(MeshTri(vertex0: vertex0, vertex1: vertex1, vertex2: vertex2 ))
        }

        var blasNodes: [RayTracerConstants.BlasNode] = []
        var meshTris: [MeshTri] = []

        var blas2Nodes: [Blas2Node] = []
        if RayTracerConstants.BlasNode.self == Blas2Node.self {
            buildBvh2(blas2Nodes: &blas2Nodes, trianglesOut: &meshTris, trianglesIn: triangles)
            blasNodes = blas2Nodes as Any as! [RayTracerConstants.BlasNode]

        } else if RayTracerConstants.BlasNode.self == Blas4Node.self {
            buildBvh2(blas2Nodes: &blas2Nodes, trianglesOut: &meshTris, trianglesIn: triangles)
            var blas4Nodes: [Blas4Node] = []
            buildBvh4(blas4Nodes: &blas4Nodes, blas2Nodes: blas2Nodes) 
            blasNodes = blas4Nodes as Any as! [RayTracerConstants.BlasNode]
        }

        blasNodeHandle = blasNodeAllocator.allocAndInit(count: blasNodes.count, pointer: &blasNodes)
        meshTriHandle = meshTriAllocator.allocAndInit(count: meshTris.count, pointer: &meshTris)
    }

    /// Builds a Binary BVH from a list of triangles using SAH
    /// TODO: Add an option back for SplitMedian
    private func buildBvh2(blas2Nodes: inout [Blas2Node], trianglesOut: inout [MeshTri], trianglesIn: [MeshTri], isRight: Bool = true) {
        let aabb = AABB(from: trianglesIn)
        var node = Blas2Node(aabb: aabb)

        let triangleCount = trianglesIn.count
        if triangleCount <= 4 {
            // Make a Leaf Node
            node.triangleIndex = UInt32(trianglesOut.count)
            node.triangleCount = UInt32(trianglesIn.count)
            trianglesOut.append(contentsOf: trianglesIn)
            blas2Nodes.append(node)
            return
        }

        let extents = aabb.maxBounds - aabb.minBounds
        var bestAxis: Axis = .X
        var bestSplitValue: Float = 0.0
        var minCost = Float.infinity

        let cTrav: Float = 1.0
        let cIsect: Float = 1.5
        let parentSurfaceArea = aabb.surfaceArea()

        let numBins = 16

        for axis in Axis.allCases {
            // Skip flat axes
            if extents[axis] < 1e-5 { continue }

            var binCount = [Int](repeating: 0, count: numBins)
            var binBounds = [AABB](repeating: AABB(), count: numBins)

            for triangle in trianglesIn {
                let c = triangle.centroid()[axis]
                var binIndex = Int(((c - aabb.minBounds[axis]) / extents[axis]) * Float(numBins))
                binIndex = max(0, min(numBins - 1, binIndex))

                binCount[binIndex] += 1
                binBounds[binIndex].extend(with: AABB(from: triangle))
            }

            // Suffix Bounds Sweep
            var rightBounds = [AABB](repeating: AABB(minBounds: .zero, maxBounds: .zero), count: numBins)
            var rightCount = [Int](repeating: 0, count: numBins)

            var currentRightAabb = AABB()
            var currentRightCount = 0

            for i in (0 ..< numBins).reversed() {
                currentRightAabb.extend(with: binBounds[i])
                currentRightCount += binCount[i]
                rightBounds[i] = currentRightAabb
                rightCount[i] = currentRightCount
            }

            // Prefix Bounds Sweep and SAH Cost Evaluation
            var leftBounds = AABB()
            var leftCount = 0

            for i in 0 ..< (numBins - 1) {
                leftBounds.extend(with: binBounds[i])
                leftCount += binCount[i]

                if (leftCount == 0) || (rightCount[i + 1] == 0) { continue }

                let surfaceAreaLeft = leftBounds.surfaceArea()
                let surfaceAreaRight = rightBounds[i + 1].surfaceArea()
                let cost = cTrav + 
                    (surfaceAreaLeft / parentSurfaceArea * Float(leftCount) * cIsect) +
                    (surfaceAreaRight / parentSurfaceArea * Float(rightCount[i + 1]) * cIsect)

                if cost < minCost {
                    minCost = cost
                    bestAxis = axis
                    bestSplitValue = aabb.minBounds[axis] + (extents[axis] / Float(numBins) * Float(i + 1))
                }
            }
        }

        // If splitting doesn't improve the cost, fallback to making a Leaf Node
        let leafCost = Float(triangleCount) * cIsect
        if minCost >= leafCost && triangleCount <= 8 {
            node.triangleIndex = UInt32(trianglesOut.count)
            node.triangleCount = UInt32(trianglesIn.count)
            trianglesOut.append(contentsOf: trianglesIn)
            blas2Nodes.append(node)
            return
        }

        var leftTriangles  : [MeshTri] = []
        var rightTriangles : [MeshTri] = []

        leftTriangles.reserveCapacity(trianglesIn.count / 2)
        rightTriangles.reserveCapacity(trianglesIn.count / 2)

        for triangle in trianglesIn {
            if triangle.centroid()[bestAxis] < bestSplitValue {
                leftTriangles.append(triangle)
            } else {
                rightTriangles.append(triangle)
            }
        }
    
        // Median Fallback if SAH produces an empty side
        if leftTriangles.isEmpty || rightTriangles.isEmpty {
            var sorted = trianglesIn
            sorted.sort { $0.centroid()[bestAxis] < $1.centroid()[bestAxis] }

            leftTriangles.removeAll(keepingCapacity: true)
            rightTriangles.removeAll(keepingCapacity: true)

            let mid = sorted.count / 2
            leftTriangles.append(contentsOf: sorted[..<mid])
            rightTriangles.append(contentsOf: sorted[mid...])
        }
    
        let parentIndex = blas2Nodes.count
        blas2Nodes.append(node)
        blas2Nodes[parentIndex].leafIndices.x = Int32(blas2Nodes.count)
        buildBvh2(blas2Nodes: &blas2Nodes, trianglesOut: &trianglesOut, trianglesIn: leftTriangles, isRight: false)

        blas2Nodes[parentIndex].leafIndices.y = Int32(blas2Nodes.count)
        buildBvh2(blas2Nodes: &blas2Nodes, trianglesOut: &trianglesOut, trianglesIn: rightTriangles, isRight: true)
    }

    /// Flattens a Binary BVH into a 4 leaf BVH
    private func buildBvh4(blas4Nodes: inout [Blas4Node], blas2Nodes: [Blas2Node], currentBlas2Node: Blas2Node? = nil) {
        let nodeIndex = blas4Nodes.count
        var blas4Node = Blas4Node(aabb4: AABB4())
        blas4Nodes.append(blas4Node)
        defer { blas4Nodes[nodeIndex] = blas4Node }

        let blas2Node = currentBlas2Node ?? blas2Nodes[0]

        // For root-nodes that have 4 or less faces, everything is put in one lane; the first
        if blas2Node.isLeaf() {
            blas4Node.aabb4.minBoundsX[0] = blas2Node.aabb.minBounds.x
            blas4Node.aabb4.minBoundsY[0] = blas2Node.aabb.minBounds.y
            blas4Node.aabb4.minBoundsZ[0] = blas2Node.aabb.minBounds.z
            blas4Node.aabb4.maxBoundsX[0] = blas2Node.aabb.maxBounds.x
            blas4Node.aabb4.maxBoundsY[0] = blas2Node.aabb.maxBounds.y
            blas4Node.aabb4.maxBoundsZ[0] = blas2Node.aabb.maxBounds.z
            blas4Node.triangleIndices [0] = blas2Node.triangleIndex
            blas4Node.triangleCounts  [0] = blas2Node.triangleCount
            return
        }

        func setLane(child: Blas2Node?, grandChild: Blas2Node?, lane: Int) {
            guard let child = child else { return }
            if child.isLeaf() {
                // Only set lane 0 and lane 2 to avoid duplicating the BVH2 Nodes to two lanes instead of just one
                if (lane == 0) || (lane == 2) {
                    blas4Node.triangleIndices[lane] = child.triangleIndex
                    blas4Node.triangleCounts [lane] = child.triangleCount
                    blas4Node.aabb4.minBoundsX[lane] = child.aabb.minBounds.x
                    blas4Node.aabb4.minBoundsY[lane] = child.aabb.minBounds.y
                    blas4Node.aabb4.minBoundsZ[lane] = child.aabb.minBounds.z
                    blas4Node.aabb4.maxBoundsX[lane] = child.aabb.maxBounds.x
                    blas4Node.aabb4.maxBoundsY[lane] = child.aabb.maxBounds.y
                    blas4Node.aabb4.maxBoundsZ[lane] = child.aabb.maxBounds.z
                }
            }

            guard let grandChild = grandChild else { return }
            blas4Node.aabb4.minBoundsX[lane] = grandChild.aabb.minBounds.x
            blas4Node.aabb4.minBoundsY[lane] = grandChild.aabb.minBounds.y
            blas4Node.aabb4.minBoundsZ[lane] = grandChild.aabb.minBounds.z
            blas4Node.aabb4.maxBoundsX[lane] = grandChild.aabb.maxBounds.x
            blas4Node.aabb4.maxBoundsY[lane] = grandChild.aabb.maxBounds.y
            blas4Node.aabb4.maxBoundsZ[lane] = grandChild.aabb.maxBounds.z

            if !grandChild.isLeaf() {
                blas4Node.leafIndices[lane] = Int32(blas4Nodes.count)
                buildBvh4(blas4Nodes: &blas4Nodes, blas2Nodes: blas2Nodes, currentBlas2Node: grandChild)
            } else {
                blas4Node.triangleIndices[lane] = grandChild.triangleIndex
                blas4Node.triangleCounts [lane] = grandChild.triangleCount
            }
        }

        let leftChild = blas2Node.getLeftNode(blas2Nodes: blas2Nodes)
        let rightChild = blas2Node.getRightNode(blas2Nodes: blas2Nodes)
        let leftLeftGrandChild = leftChild?.getLeftNode(blas2Nodes: blas2Nodes)
        let leftRightGrandChild = leftChild?.getRightNode(blas2Nodes: blas2Nodes)
        let rightLeftGrandChild = rightChild?.getLeftNode(blas2Nodes: blas2Nodes)
        let rightRightGrandChild = rightChild?.getRightNode(blas2Nodes: blas2Nodes)

        setLane(child: leftChild, grandChild: leftLeftGrandChild, lane: 0)
        setLane(child: leftChild, grandChild: leftRightGrandChild, lane: 1)
        setLane(child: rightChild, grandChild: rightLeftGrandChild, lane: 2)
        setLane(child: rightChild, grandChild: rightRightGrandChild, lane: 3)
    }
    
    func reform() {
        fatalError("Blas.reform() is unimplemented!")
    }

    static func raycast(
        ray: Ray, 
        nodeBuffer: MTLBufferAllocator<RayTracerConstants.BlasNode>, 
        triangleBuffer: MTLBufferAllocator<MeshTri>,
        baseNode: Int32,
        baseMeshTri: Int32
    ) -> RaycastResult {
        if RayTracerConstants.BlasNode.self == Blas2Node.self {
            var intersector = Blas2Intersector(
                ray: ray, 
                nodeBuffer: nodeBuffer as Any as! MTLBufferAllocator<Blas2Node>, 
                triangleBuffer: triangleBuffer, 
                baseNode: baseNode, 
                baseMeshTri: baseMeshTri
            )
            return intersector.traverse()
        } else if RayTracerConstants.BlasNode.self == Blas4Node.self {
            var intersector = Blas4Intersector(
                ray: ray, 
                nodeBuffer: nodeBuffer as Any as! MTLBufferAllocator<Blas4Node>, 
                triangleBuffer: triangleBuffer, 
                baseNode: baseNode, 
                baseMeshTri: baseMeshTri
            )
            return intersector.traverse()
        } else {
            fatalError("Invalid BlasNode type for RayTracerConstants.BlasNode")
        }
    }
}

struct Blas2Node : Bvh2Node {
    var aabb            : AABB
    var leafIndices     : simd_int2 = [-1, -1]
    var triangleIndex   : simd_uint1 = 0
    var triangleCount   : simd_uint1 = 0

    func isLeaf() -> Bool {
        return (leafIndices.x == -1) && (leafIndices.y == -1)
    }

    func getLeftNode(blas2Nodes: [Blas2Node]) -> Blas2Node? {
        guard leafIndices.x != -1 else { return nil }
        return blas2Nodes[Int(leafIndices.x)]
    }

    func getRightNode(blas2Nodes: [Blas2Node]) -> Blas2Node? {
        guard leafIndices.y != -1 else { return nil }
        return blas2Nodes[Int(leafIndices.y)]
    }
}

struct Blas4Node : Bvh4Node {
    var aabb4           : AABB4
    var leafIndices     : simd_int4 = [-1, -1, -1, -1]
    var triangleIndices : simd_uint4 = [0, 0, 0, 0]
    var triangleCounts  : simd_uint4 = [0, 0, 0, 0]
}

struct Blas2Intersector : Bvh2Intersector {
    var ray            : Ray                            
    var raycastResult  : RaycastResult = RaycastResult()               

    var nodeBuffer     : MTLBufferAllocator<Blas2Node>   
    var triangleBuffer : MTLBufferAllocator<MeshTri>
    var baseNode       : Int32
    var baseMeshTri    : Int32

    func intersectsNode(_ node: Blas2Node) -> Bool {
        return ray.intersectsAABB(node.aabb)
    }

    mutating func processLeaf(_ node: Blas2Node) {
        let startAt : Int32 = Int32(node.triangleIndex)
        let stopAt  : Int32 = startAt + Int32(node.triangleCount)

        for i in startAt ..< stopAt {
            guard let triangle = triangleBuffer[Int(i + baseMeshTri)] else {
                fatalError("Missing Triangle in MeshTri MTLBuffer at index: \(i)")
            }

            var result = ray.intersectsTriangle(triangle)
            if result.distance < raycastResult.distance {
                result.primitiveId = Int32(i + baseMeshTri)
                raycastResult = result
            }
        }
    }
}

struct Blas4Intersector : Bvh4Intersector {
    var ray            : Ray                            
    var raycastResult  : RaycastResult = RaycastResult()                    

    var nodeBuffer     : MTLBufferAllocator<Blas4Node>
    var triangleBuffer : MTLBufferAllocator<MeshTri>
    var baseNode       : Int32
    var baseMeshTri    : Int32

    func intersectsNode(_ node: Blas4Node) -> simd_float4 {
        return ray.intersectsAABB4(node.aabb4)
    }

    mutating func processLeaf(_ node: Blas4Node, lane: Int) {
        let startAt : Int32 = Int32(node.triangleIndices[lane])
        let stopAt  : Int32 = startAt + Int32(node.triangleCounts[lane]) 

        for i in startAt ..< stopAt {
            guard let triangle = triangleBuffer[Int(i + baseMeshTri)] else {
                fatalError("Missing Triangle in MeshTri MTLBuffer at index: \(i)")
            }

            var result = ray.intersectsTriangle(triangle)
            if result.distance < raycastResult.distance {
                result.primitiveId = Int32(i + baseMeshTri)
                raycastResult = result
            }
        }
    }
}