import simd

protocol BvhNode {}

protocol Bvh2Node : BvhNode {
    var aabb        : AABB      { get set }
    var leafIndices : simd_int2 { get set }
}

protocol Bvh4Node : BvhNode {
    var aabb4       : AABB4     { get set }
    var leafIndices : simd_int4 { get set }
}

protocol BvhIntersector<Node> {
    associatedtype Node: BvhNode

    var ray            : Ray                         { get set }
    var raycastResult  : RaycastResult               { get set }
    var nodeBuffer     : MTLBufferAllocator<Node>    { get set } 
    var triangleBuffer : MTLBufferAllocator<MeshTri> { get set }
    var baseNode       : Int32                       { get set }
    var baseMeshTri    : Int32                       { get set }

    mutating func traverse() -> RaycastResult
}

protocol Bvh2Intersector: BvhIntersector where Node: Bvh2Node {
    func intersectsNode(_ node: Node) -> Bool
    mutating func processLeaf(_ node: Node)
}

protocol Bvh4Intersector: BvhIntersector where Node: Bvh4Node {
    func intersectsNode(_ node: Node) -> simd_float4
    mutating func processLeaf(_ node: Node, lane: Int)
}

extension Bvh2Intersector {
    mutating func traverse() -> RaycastResult {
        var nodeIndex : Int32   = baseNode
        var stack     : [Int32] = []
        stack.reserveCapacity(16)

        while nodeIndex != -1 {
            defer { nodeIndex = stack.popLast() ?? -1 }

            guard let node = nodeBuffer[Int(nodeIndex)] else {
                fatalError("Missing Node at nodeIndex: \(nodeIndex) in Bvh2")
            }

            if !intersectsNode(node) { 
                continue 
            }

            // If this node is not a leaf, this will simply do nothing
            processLeaf(node)

            // Check if this node has leafs (TODO: currently doesn't sort on distance!)
            let leftIndex  : Int32 = node.leafIndices.x
            let rightIndex : Int32 = node.leafIndices.y
            if leftIndex  != -1 { stack.append(leftIndex  + baseNode) }
            if rightIndex != -1 { stack.append(rightIndex + baseNode) }
        }

        return raycastResult
    }
}

extension Bvh4Intersector {
    mutating func traverse() -> RaycastResult {
        var nodeIndex : Int32   = baseNode
        var stack     : [Int32] = []
        stack.reserveCapacity(16)

        while nodeIndex != -1 {
            defer { nodeIndex = stack.popLast() ?? -1 }

            guard let node = nodeBuffer[Int(nodeIndex)] else {
                fatalError("Missing Node at nodeIndex: \(nodeIndex) in Bvh2")
            }

            let hits = intersectsNode(node)
            let validHit = hits .< simd_float4(repeating: raycastResult.distance)

            for lane in 0 ..< 4 {
                if validHit[lane] == false { continue }

                let leafIndex = node.leafIndices[lane]
                if leafIndex == -1 {
                    processLeaf(node, lane: lane)
                } else {
                    stack.append(leafIndex + baseNode)
                }
            }
        }

        return raycastResult
    }
}