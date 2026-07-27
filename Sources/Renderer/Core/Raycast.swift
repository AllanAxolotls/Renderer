// TODO: ADD INSTANCING: if the BLAS structure is the same for a model, make only one BLAS and reference it via both TLASInstances

import simd

let maxFacesInLeafBLASNode: Int = 8
let epsilon: Float = 0.0001

public struct RaycastResult {
    var hit: simd_float3 = simd_float3(0, 0, 0)
    var normal: simd_float3 = simd_float3(0, 1, 0)
    var distance: Float = .infinity
    var barycentric: simd_float3 = simd_float3(1, 0, 0)
    var faceIndex: Int32 = -1
    var instanceIndex: Int32 = -1
}

public class BLASNodeBVH2 {
    var minBounds: simd_float3
    var maxBounds: simd_float3
    var left: BLASNodeBVH2? = nil
    var right: BLASNodeBVH2? = nil
    var faceOffset: Int32 = 0
    var faceCount: Int32 = 0
    init(minBounds: simd_float3, maxBounds: simd_float3) {
        self.minBounds = minBounds
        self.maxBounds = maxBounds
    }
}

public class TLASNodeBVH2 {
    var minBounds: simd_float3
    var maxBounds: simd_float3
    var left: TLASNodeBVH2? = nil
    var right: TLASNodeBVH2? = nil
    var instanceIndex: Int32 = -1
    init(minBounds: simd_float3, maxBounds: simd_float3) {
        self.minBounds = minBounds
        self.maxBounds = maxBounds
    }
}

public struct BLASNode {
    var minBoundsX: simd_float4 = simd_float4(repeating: .infinity)
    var minBoundsY: simd_float4 = simd_float4(repeating: .infinity)
    var minBoundsZ: simd_float4 = simd_float4(repeating: .infinity)
    var maxBoundsX: simd_float4 = simd_float4(repeating: -.infinity)
    var maxBoundsY: simd_float4 = simd_float4(repeating: -.infinity)
    var maxBoundsZ: simd_float4 = simd_float4(repeating: -.infinity)
    var childIndices: simd_int4 = simd_int4(repeating: -1)
    var faceOffsets: simd_int4 = simd_int4(repeating: 0)
    var faceCounts: simd_int4 = simd_int4(repeating: 0)
}

public struct TLASInstance {
    var blasStartIndex: Int32
    var modelMatrix: simd_float4x4
    var invModelMatrix: simd_float4x4
    var invNormalMatrix: simd_float3x3
}

public struct TLASNode {
    var minBoundsX: simd_float4 = simd_float4(repeating: .infinity)
    var minBoundsY: simd_float4 = simd_float4(repeating: .infinity)
    var minBoundsZ: simd_float4 = simd_float4(repeating: .infinity)
    var maxBoundsX: simd_float4 = simd_float4(repeating: -.infinity)
    var maxBoundsY: simd_float4 = simd_float4(repeating: -.infinity)
    var maxBoundsZ: simd_float4 = simd_float4(repeating: -.infinity)
    var childIndices: simd_int4 = simd_int4(repeating: -1)
    var tlasInstanceIndices: simd_int4 = simd_int4(repeating: -1)
}

public func intersectsAABB(origin: simd_float3, invDirection: simd_float3, min: simd_float3, max: simd_float3) -> Bool {
    var tmin: Float = (min.x - origin.x) * invDirection.x
    var tmax: Float = (max.x - origin.x) * invDirection.x
    if tmin > tmax { 
        let tmp = tmin
        tmin = tmax
        tmax = tmp
    }
    
    var tymin: Float = (min.y - origin.y) * invDirection.y
    var tymax: Float = (max.y - origin.y) * invDirection.y
    if tymin > tymax { 
        let tmp = tymin
        tymin = tymax
        tymax = tmp
    }

    if tmin > tymax || tymin > tmax { return false; }

    if tymin > tmin { tmin = tymin }
    if tymax < tmax { tmax = tymax }

    var tzmin: Float = (min.z - origin.z) * invDirection.z
    var tzmax: Float = (max.z - origin.z) * invDirection.z
    if (tzmin > tzmax) { 
        let tmp = tzmin
        tzmin = tzmax
        tzmax = tmp
    }

    if tmin > tzmax || tzmin > tmax { return false }
    return true
}

public func intersects4AABBs(
    origin: simd_float3, invDirection: simd_float3, 
    minBoundsX: simd_float4, minBoundsY: simd_float4, minBoundsZ: simd_float4,
    maxBoundsX: simd_float4, maxBoundsY: simd_float4, maxBoundsZ: simd_float4
) -> [Bool] {
    let t1 = (minBoundsX - simd_float4(repeating: origin.x)) * invDirection.x
    let t2 = (maxBoundsX - simd_float4(repeating: origin.x)) * invDirection.x
    var tmin = fmin(t1, t2);
    var tmax = fmax(t1, t2);

    let ty1 = (minBoundsY - simd_float4(repeating: origin.y)) * invDirection.y
    let ty2 = (maxBoundsY - simd_float4(repeating: origin.y)) * invDirection.y
    tmin = fmax(tmin, fmin(ty1, ty2))
    tmax = fmin(tmax, fmax(ty1, ty2))

    let tz1 = (minBoundsZ - simd_float4(repeating: origin.z)) * invDirection.z
    let tz2 = (maxBoundsZ - simd_float4(repeating: origin.z)) * invDirection.z
    tmin = fmax(tmin, fmin(tz1, tz2))
    tmax = fmin(tmax, fmax(tz1, tz2))

    return [tmin[0] <= tmax[0], tmin[1] <= tmax[1], tmin[2] <= tmax[2], tmin[3] <= tmax[3]]
}

public func intersectsFace(origin: simd_float3, direction: simd_float3, face: RayTraceTriangleGPU, vertices: [Vertex]) -> RaycastResult {
    let position0 = face.position0
    let edge1 = face.position1 - position0
    let edge2 = face.position2 - position0
    let normal = simd_cross(edge1, edge2)
    // Backface Culling, keeps CCW-wound triangles
    if simd_dot(normal, direction) > 0 { return RaycastResult() }

    let direction_cross_edge2 = simd_cross(direction, edge2)
    let det = simd_dot(edge1, direction_cross_edge2) // Triple Scalar Product
    if abs(det) < epsilon { return RaycastResult() }

    let invDet = 1.0 / det
    let s = origin - position0
    let u = invDet * simd_dot(s, direction_cross_edge2)
    if u < -epsilon || u - 1 > epsilon { return RaycastResult() }

    let s_cross_edge1 = simd_cross(s, edge1)
    let v = invDet * simd_dot(direction, s_cross_edge1)
    if v < -epsilon || u + v - 1 > epsilon { return RaycastResult() }

    let t = invDet * simd_dot(edge2, s_cross_edge1)
    if t > epsilon {
        var result = RaycastResult()
        result.hit = origin + direction * t
        result.normal = normal
        result.distance = t
        result.barycentric = simd_float3(1.0-u-v, u, v)
        return result
    }
    return RaycastResult()
}


final class BLAS {
    private var scene: Scene
    private var mesh: Mesh
    public var blasNodes: [BLASNode] = []
    public var leafFaces: [RayTraceTriangleGPU] = []
    public var blasStartIndex: Int32 = 0
    public var leafFaceOffset: Int32 = 0
    public var nodeOffset: Int32 = 0
    public var faceOffset: Int32 = 0 // Because there are multiple BLAS's and there is one flat face
    // array, this gives the offset to the global face instead of the local BLAS array

    init(scene: Scene, mesh: Mesh, nodeOffset: Int32, faceOffset: Int32) {
        self.scene = scene
        self.mesh = mesh
        self.nodeOffset = nodeOffset
        self.faceOffset = faceOffset
        self.build()
    }

    public func build() {
        blasNodes = []
        leafFaces = []
        leafFaceOffset = 0
        //blasStartIndex = buildNodeBySplitMedian(faces: makeGPUFaces())
        blasStartIndex = nodeOffset
        flattenBVH2(node: buildBVH2Node(faces: makeGPUFaces(), isRight: true, vertices: scene.vertices))
    }


    public typealias BoundsTuple = (min: simd_float3, max: simd_float3)

    @inline(__always)
    private func surfaceArea(bounds: BoundsTuple) -> Float {
        let d = bounds.max - bounds.min
        // Handle negative or invalid bounds gracefully
        let x = max(0.0, d.x)
        let y = max(0.0, d.y)
        let z = max(0.0, d.z)
        return 2.0 * (x * y + y * z + z * x)
    }

    @inline(__always)
    private func unionBounds(_ a: BoundsTuple, _ b: BoundsTuple) -> BoundsTuple {
        return (
            min: min(a.min, b.min),
            max: max(a.max, b.max)
        )
    }
    public func buildBVH2Node(faces: [RayTraceTriangleGPU], isRight: Bool, vertices: [Vertex]) -> BLASNodeBVH2 {
        let bounds = computeBounds(faces: faces, vertices: vertices)
        let node = BLASNodeBVH2(minBounds: bounds.min, maxBounds: bounds.max)
        let faceCount = faces.count
        
        if faceCount <= 4 { 
            return makeLeafNode(node, faces: faces)
        }

        let extents = bounds.max - bounds.min
        var bestAxis = 0
        var bestSplitValue: Float = 0.0
        var minCost = Float.infinity
        
        let cTrav: Float = 1.0
        let cIsect: Float = 1.5 // Sightly higher weight to intersections helps reduce leaf size
        let parentSA = surfaceArea(bounds: bounds)
        
        // Number of spatial bins to test
        let numBins = 16
        
        // 1. Find the best split using spatial binning
        for axis in 0..<3 {
            if extents[axis] < 1e-5 { continue } // Skip flat axes
            
            // Allocate bins
            var binCount = [Int](repeating: 0, count: numBins)
            var binBounds = [BoundsTuple](repeating: (min: simd_float3(repeating: Float.infinity), max: simd_float3(repeating: -Float.infinity)), count: numBins)
            
            // Populate bins
            for face in faces {
                let c = centroid(face)[axis]
                // Map centroid to a bin index [0 ... numBins-1]
                var binIdx = Int(((c - bounds.min[axis]) / extents[axis]) * Float(numBins))
                binIdx = max(0, min(numBins - 1, binIdx))
                
                binCount[binIdx] += 1
                let faceB = computeBounds(faces: [face], vertices: scene.vertices)
                binBounds[binIdx] = unionBounds(binBounds[binIdx], faceB)
            }
            
            // Evaluate SAH cost at each of the (numBins - 1) split planes
            // Precompute right-to-left suffix bounds for the bins
            var rightBounds = [BoundsTuple](repeating: (min: simd_float3(repeating: 0), max: simd_float3(repeating: 0)), count: numBins)
            var rightCount = [Int](repeating: 0, count: numBins)
            
            var currentRightBounds = (min: simd_float3(repeating: Float.infinity), max: simd_float3(repeating: -Float.infinity))
            var currentRightCount = 0
            
            for i in (0..<numBins).reversed() {
                currentRightBounds = unionBounds(currentRightBounds, binBounds[i])
                currentRightCount += binCount[i]
                rightBounds[i] = currentRightBounds
                rightCount[i] = currentRightCount
            }
            
            // Sweep left-to-right over bin boundaries
            var leftBounds = (min: simd_float3(repeating: Float.infinity), max: simd_float3(repeating: -Float.infinity))
            var leftCount = 0
            
            for i in 0..<(numBins - 1) {
                leftBounds = unionBounds(leftBounds, binBounds[i])
                leftCount += binCount[i]
                
                if leftCount == 0 || rightCount[i + 1] == 0 { continue }
                
                let saLeft = surfaceArea(bounds: leftBounds)
                let saRight = surfaceArea(bounds: rightBounds[i + 1])
                
                let cost = cTrav + (saLeft / parentSA * Float(leftCount) * cIsect) + (saRight / parentSA * Float(rightCount[i + 1]) * cIsect)
                
                if cost < minCost {
                    minCost = cost
                    bestAxis = axis
                    // The spatial split plane value
                    bestSplitValue = bounds.min[axis] + (extents[axis] / Float(numBins)) * Float(i + 1)
                }
            }
        }

        // Fallback to leaf if splitting doesn't help
        let leafCost = Float(faceCount) * cIsect
        if minCost >= leafCost && faceCount <= 8 {
            return makeLeafNode(node, faces: faces)
        }

        let left = faces.filter { centroid($0)[bestAxis] < bestSplitValue }
        let right = faces.filter { centroid($0)[bestAxis] >= bestSplitValue }
        
        if left.isEmpty || right.isEmpty {
            let middle = faces.count / 2
            let sorted = faces.sorted { centroid($0)[bestAxis] < centroid($1)[bestAxis] }
            return buildLeftRightNodes(node, left: Array(sorted[..<middle]), right: Array(sorted[middle...]), isRight: isRight)
        }

        return buildLeftRightNodes(node, left: left, right: right, isRight: isRight)
    }

    private func buildLeftRightNodes(_ node: BLASNodeBVH2, left: [RayTraceTriangleGPU], right: [RayTraceTriangleGPU], isRight: Bool) -> BLASNodeBVH2 {
        node.left = buildBVH2Node(faces: left, isRight: false, vertices: scene.vertices)
        node.right = buildBVH2Node(faces: right, isRight: isRight, vertices: scene.vertices)
        return node
    }

    private func makeLeafNode(_ node: BLASNodeBVH2, faces: [RayTraceTriangleGPU]) -> BLASNodeBVH2 {
        node.left = nil
        node.right = nil
        node.faceOffset = leafFaceOffset + faceOffset
        leafFaceOffset += Int32(faces.count)
        node.faceCount = Int32(faces.count)
        self.leafFaces.append(contentsOf: faces)
        return node
    }

    /*
    public func buildBVH2Node(faces: [RayTraceTriangleGPU], isRight: Bool) -> BLASNodeBVH2 {
        let bounds = computeBounds(faces: faces)
        let node = BLASNodeBVH2(minBounds: bounds.min, maxBounds: bounds.max)
        let faceCount: Int32 = Int32(faces.count)
        if faceCount <= 8 { // try 4 and 2
            node.left = nil
            node.right = nil
            node.faceOffset = leafFaceOffset + faceOffset
            leafFaceOffset += faceCount
            node.faceCount = faceCount
            self.leafFaces.append(contentsOf: faces)
            return node
        }

        let axis = longestAxis(bounds: bounds)
        let sorted = faces.sorted { centroid($0)[axis] < centroid($1)[axis] }
        let middle = sorted.count / 2
        let left = Array(sorted[..<middle])
        let right = Array(sorted[middle...])
        node.left = buildBVH2Node(faces: left, isRight: false)
        node.right = buildBVH2Node(faces: right, isRight: isRight)
        return node
    }*/

    public func flattenBVH2(node: BLASNodeBVH2) {
        let nodeIndex = blasNodes.count
        var blasNode = BLASNode()
        blasNodes.append(blasNode) // placeholder

        // For nodes that have 4 or less faces in the root
        if node.left == nil && node.right == nil {
            blasNode.minBoundsX[0] = node.minBounds.x
            blasNode.minBoundsY[0] = node.minBounds.y
            blasNode.minBoundsZ[0] = node.minBounds.z

            blasNode.maxBoundsX[0] = node.maxBounds.x
            blasNode.maxBoundsY[0] = node.maxBounds.y
            blasNode.maxBoundsZ[0] = node.maxBounds.z

            blasNode.faceOffsets[0] = node.faceOffset
            blasNode.faceCounts[0] = node.faceCount

            blasNodes[nodeIndex] = blasNode
            return
        }

        func setLane(child: BLASNodeBVH2?, grandChild: BLASNodeBVH2?, index: Int) {
            guard let child = child else { return }
            if child.left == nil && child.right == nil {
                if index == 0 || index == 2 {
                    blasNode.faceOffsets[index] = child.faceOffset
                    blasNode.faceCounts[index] = child.faceCount
                    blasNode.minBoundsX[index] = child.minBounds.x
                    blasNode.minBoundsY[index] = child.minBounds.y
                    blasNode.minBoundsZ[index] = child.minBounds.z
                    blasNode.maxBoundsX[index] = child.maxBounds.x
                    blasNode.maxBoundsY[index] = child.maxBounds.y
                    blasNode.maxBoundsZ[index] = child.maxBounds.z
                }
            }

            guard let grandChild = grandChild else { return }
            blasNode.minBoundsX[index] = grandChild.minBounds.x
            blasNode.minBoundsY[index] = grandChild.minBounds.y
            blasNode.minBoundsZ[index] = grandChild.minBounds.z
            blasNode.maxBoundsX[index] = grandChild.maxBounds.x
            blasNode.maxBoundsY[index] = grandChild.maxBounds.y
            blasNode.maxBoundsZ[index] = grandChild.maxBounds.z

            if grandChild.left != nil || grandChild.right != nil {
                blasNode.childIndices[index] = Int32(blasNodes.count) + nodeOffset
                flattenBVH2(node: grandChild)
            } else {
                blasNode.faceOffsets[index] = grandChild.faceOffset
                blasNode.faceCounts[index] = grandChild.faceCount
            }
        }

        setLane(child: node.left, grandChild: node.left?.left, index: 0)
        setLane(child: node.left, grandChild: node.left?.right, index: 1)
        setLane(child: node.right, grandChild: node.right?.left, index: 2)
        setLane(child: node.right, grandChild: node.right?.right, index: 3)

        blasNodes[nodeIndex] = blasNode
    }

    public func buildNodeBySplitMedian(faces: [RayTraceTriangleGPU], vertices: [Vertex]) -> Int32 {
        let startIndex = Int32(blasNodes.count)

        func buildLeaf(faces: [RayTraceTriangleGPU], index: Int) {
            let faceCount = Int32(faces.count)
            blasNodes[Int(startIndex)].faceOffsets[index] = leafFaceOffset + faceOffset
            leafFaceOffset += faceCount
            blasNodes[Int(startIndex)].faceCounts[index] = faceCount
            self.leafFaces.append(contentsOf: faces)
        }

        func splitMedian(splitFaces: [RayTraceTriangleGPU]) -> (left: [RayTraceTriangleGPU], right: [RayTraceTriangleGPU]) {
            let bounds = computeBounds(faces: splitFaces, vertices: vertices)
            let axis = longestAxis(bounds: bounds)
            let sorted = splitFaces.sorted { centroid($0)[axis] < centroid($1)[axis] }
            let middle = sorted.count / 2
            let left = Array(sorted[..<middle])
            let right = Array(sorted[middle...])
            return (left: left, right: right)
        }

        let (left, right) = splitMedian(splitFaces: faces)
        let (partition0, partition1) = splitMedian(splitFaces: left)
        let (partition2, partition3) = splitMedian(splitFaces: right)

        blasNodes.append(BLASNode())
        for (index, partition) in [partition0, partition1, partition2, partition3].enumerated() {
            if partition.count == 0 { continue }

            let bounds = computeBounds(faces: partition, vertices: vertices)
            blasNodes[Int(startIndex)].minBoundsX[index] = bounds.min.x
            blasNodes[Int(startIndex)].minBoundsY[index] = bounds.min.y
            blasNodes[Int(startIndex)].minBoundsZ[index] = bounds.min.z
            blasNodes[Int(startIndex)].maxBoundsX[index] = bounds.max.x
            blasNodes[Int(startIndex)].maxBoundsY[index] = bounds.max.y
            blasNodes[Int(startIndex)].maxBoundsZ[index] = bounds.max.z
            if partition.count > maxFacesInLeafBLASNode { // Becomes a branch
                blasNodes[Int(startIndex)].childIndices[index] = buildNodeBySplitMedian(faces: partition, vertices: vertices)
            } else { // Leaf node
                buildLeaf(faces: partition, index: index)
            }
        }

        return startIndex + nodeOffset
    }

    public func computeBounds(faces: [RayTraceTriangleGPU], vertices: [Vertex]) -> (min: simd_float3, max: simd_float3) {
        var minV = simd_float3(repeating: Float.greatestFiniteMagnitude)
        var maxV = simd_float3(repeating: -Float.greatestFiniteMagnitude)

        func include(_ p: simd_float3) {
            minV = min(minV, p)
            maxV = max(maxV, p)
        }

        for face in faces {
            include(face.position0)
            include(face.position1)
            include(face.position2)
        }

        return (min: minV, max: maxV)
    }

    private func longestAxis(bounds: (min: simd_float3, max: simd_float3)) -> Int {
        let extents = bounds.max - bounds.min
        if extents.x > extents.y && extents.x > extents.z {
            return 0 // X
        } else if extents.y > extents.z {
            return 1 // Y
        } else {
            return 2 // Z
        }
    }

    private func centroid(_ face: RayTraceTriangleGPU) -> simd_float3 {
        return (face.position0 + face.position1 + face.position2) / 3.0
    }

    public func makeGPUFaces() -> [RayTraceTriangleGPU] {
        var faces: [RayTraceTriangleGPU] = []
        for faceIndex in mesh.faceOffset ..< mesh.faceOffset + mesh.faceCount {
            let face = scene.faces[Int(faceIndex)]
            let subMesh = scene.subMeshes[Int(face.subMeshIndex)]
            let position0 = scene.vertices[Int(face.vertexIndex0)].position
            let position1 = scene.vertices[Int(face.vertexIndex1)].position
            let position2 = scene.vertices[Int(face.vertexIndex2)].position
            //let edge1 = vertex2.position - vertex1.position
            //let edge2 = vertex3.position - vertex1.position
            faces.append(RayTraceTriangleGPU(
                position0: position0, position1: position1, position2: position2, 
                vertexIndex0: face.vertexIndex0, vertexIndex1: face.vertexIndex1, vertexIndex2: face.vertexIndex2,
                // TODO: Change to 3 normals in future
                //normal: simd_normalize(simd_cross(edge1, edge2)),
                materialIndex: subMesh.materialIndex
            ))
        }
        return faces
    }
}

final class TLAS {
    private var scene: Scene
    public var tlasNodes: [TLASNode] = []
    public var tlasInstances: [TLASInstance] = []
    public var tlasInstancesToMeshes: [Mesh] = []

    public var blas_s: [BLAS] = []
    public var blasNodes: [BLASNode] = []
    public var faces: [RayTraceTriangleGPU] = []

    init(scene: Scene) {
        self.scene = scene;
        self.build()
    }

    public func raycast(origin: simd_float3, direction: simd_float3) -> RaycastResult {
        let invDirection = 1.0 / direction
        return traverseTLAS(origin: origin, direction: direction, invDirection: invDirection)
    }

    private func traverseTLAS(origin: simd_float3, direction: simd_float3, invDirection: simd_float3) -> RaycastResult {
        var nodeIndex: Int = 0
        var stack: [Int32] = []
        var closest = RaycastResult()

        while (nodeIndex != -1) {
            let node = tlasNodes[nodeIndex]
            let hits = intersects4AABBs(
                origin: origin, invDirection: invDirection, 
                minBoundsX: node.minBoundsX, minBoundsY: node.minBoundsY, minBoundsZ: node.minBoundsZ, 
                maxBoundsX: node.maxBoundsX, maxBoundsY: node.maxBoundsY, maxBoundsZ: node.maxBoundsZ
            )

            for (index, hit) in hits.enumerated() {
                if !hit { continue }
                if node.childIndices[index] == -1 {
                    let instanceIndex = node.tlasInstanceIndices[index]
                    if instanceIndex == -1 { continue }

                    let tlasInstance = tlasInstances[Int(instanceIndex)]
                    let localOrigin4 = tlasInstance.invModelMatrix * simd_float4(origin, 1)
                    let localOrigin = simd_float3(localOrigin4.x, localOrigin4.y, localOrigin4.z)
                    let localDirection4 = tlasInstance.invModelMatrix * simd_float4(direction, 0)
                    let localDirection = simd_normalize(simd_float3(localDirection4.x, localDirection4.y, localDirection4.z))
                    let localInvDirection = 1.0 / localDirection
                    var result = traverseBLAS(
                        origin: localOrigin, direction: localDirection, invDirection: localInvDirection, 
                        blasStartIndex: tlasInstance.blasStartIndex
                    )

                    if result.distance != .infinity {
                        let worldHit4 = tlasInstance.modelMatrix * simd_float4(result.hit, 1)
                        let worldHit = simd_float3(worldHit4.x, worldHit4.y, worldHit4.z)
                        result.distance = simd_length(worldHit - origin)

                        if result.distance < closest.distance {
                            result.hit = worldHit
                            result.normal = simd_normalize(tlasInstance.invNormalMatrix * result.normal)
                            result.instanceIndex = instanceIndex
                            closest = result
                        }
                    }
                } else {
                    stack.append(node.childIndices[index])
                }
            }

            nodeIndex = -1
            if stack.count != 0 {
                nodeIndex = Int(stack.popLast()!)
            }
        }

        return closest
    }

    private func traverseBLAS(origin: simd_float3, direction: simd_float3, invDirection: simd_float3, blasStartIndex: Int32) -> RaycastResult {
        var nodeIndex = Int(blasStartIndex)
        var stack: [Int32] = []
        var closest = RaycastResult()

        while nodeIndex != -1 {
            let node = blasNodes[nodeIndex]
            let hits = intersects4AABBs(
                origin: origin, invDirection: invDirection, 
                minBoundsX: node.minBoundsX, minBoundsY: node.minBoundsY, minBoundsZ: node.minBoundsZ, 
                maxBoundsX: node.maxBoundsX, maxBoundsY: node.maxBoundsY, maxBoundsZ: node.maxBoundsZ
            )

            for (index, hit) in hits.enumerated() {
                if !hit { continue }
                if node.childIndices[index] == -1 {
                    for j in node.faceOffsets[index] ..< node.faceCounts[index] + node.faceOffsets[index] {
                        let face = faces[Int(j)]
                        var result = intersectsFace(origin: origin, direction: direction, face: face, vertices: scene.vertices)
                        if result.distance < closest.distance {
                            result.faceIndex = j
                            closest = result
                        }
                    }
                } else {
                    stack.append(node.childIndices[index])
                }
            }

            nodeIndex = -1
            if stack.count != 0 {
                nodeIndex = Int(stack.popLast()!)
            }
        }

        return closest
    }

    public func build() {
        print("Building Acceleration Structure")
        tlasNodes = []
        tlasInstances = []
        tlasInstancesToMeshes = []
        blas_s = []
        blasNodes = []
        faces = []
        _ = buildNodeByMedianSplit(meshes: scene.meshes)

        print("Finished Building Acceleration Structure")
    }

    // Median Split Based
    public func buildNodeByMedianSplit(meshes: [Mesh]) -> Int32 {
        let startIndex = Int32(tlasNodes.count)
        tlasNodes.append(TLASNode())

        func buildLeaf(mesh: Mesh, index: Int) {
            tlasNodes[Int(startIndex)].minBoundsX[index] = mesh.worldMinBounds.x
            tlasNodes[Int(startIndex)].minBoundsY[index] = mesh.worldMinBounds.y
            tlasNodes[Int(startIndex)].minBoundsZ[index] = mesh.worldMinBounds.z
            tlasNodes[Int(startIndex)].maxBoundsX[index] = mesh.worldMaxBounds.x
            tlasNodes[Int(startIndex)].maxBoundsY[index] = mesh.worldMaxBounds.y
            tlasNodes[Int(startIndex)].maxBoundsZ[index] = mesh.worldMaxBounds.z

            let tlasInstanceIndex = Int32(tlasInstances.count)
            tlasNodes[Int(startIndex)].tlasInstanceIndices[index] = tlasInstanceIndex
            tlasInstancesToMeshes.append(mesh)

            let blasNodeOffset = Int32(blasNodes.count)
            tlasInstances.append(TLASInstance(
                blasStartIndex: blasNodeOffset, 
                modelMatrix: mesh.modelMatrix, 
                invModelMatrix: mesh.invModelMatrix, 
                invNormalMatrix: mesh.normalMatrix
            ))

            let blas = BLAS(scene: scene, mesh: mesh, nodeOffset: blasNodeOffset, faceOffset: Int32(faces.count))
            self.blas_s.append(blas)
            self.faces.append(contentsOf: blas.leafFaces)
            self.blasNodes.append(contentsOf: blas.blasNodes)
            
            // Child Index = -1 (default is -1)
        }

        if meshes.count <= 4 { // Don't subdivide
            for (index, mesh) in meshes.enumerated() {
                buildLeaf(mesh: mesh, index: index)
            }

            return startIndex
        }

        // Subdivide
        func splitMedian(meshes: [Mesh]) -> (left: [Mesh], right: [Mesh]) {
            let bounds = computeMeshBounds(meshes: meshes)
            let axis = longestAxis(bounds: bounds)
            let sorted = meshes.sorted { $0.pivot[axis] < $1.pivot[axis] }
            let middle = sorted.count / 2
            let left = Array(sorted[..<middle])
            let right = Array(sorted[middle...])
            return (left: left, right: right)
        }

        let (left, right) = splitMedian(meshes: meshes)
        let (partition0, partition1) = splitMedian(meshes: left)
        let (partition2, partition3) = splitMedian(meshes: right)

        for (index, partition) in [partition0, partition1, partition2, partition3].enumerated() {
            if partition.count > 1 { // Becomes a branch
                let bounds = computeMeshBounds(meshes: partition)
                tlasNodes[Int(startIndex)].minBoundsX[index] = bounds.min.x
                tlasNodes[Int(startIndex)].minBoundsY[index] = bounds.min.y
                tlasNodes[Int(startIndex)].minBoundsZ[index] = bounds.min.z
                tlasNodes[Int(startIndex)].maxBoundsX[index] = bounds.max.x
                tlasNodes[Int(startIndex)].maxBoundsY[index] = bounds.max.y
                tlasNodes[Int(startIndex)].maxBoundsZ[index] = bounds.max.z
                tlasNodes[Int(startIndex)].childIndices[index] = buildNodeByMedianSplit(meshes: partition)
            } else { // Leaf node
                buildLeaf(mesh: partition[0], index: index)
            }
        }

        return startIndex
    }

    public func reform() {
        print("TLAS Reforming is currently not supported!")
    }

    // Helpers
    private func computeMeshBounds(meshes: [Mesh]) -> (min: simd_float3, max: simd_float3) {
        var minV = simd_float3(repeating: Float.greatestFiniteMagnitude)
        var maxV = simd_float3(repeating: -Float.greatestFiniteMagnitude)

        func include(_ p: simd_float3) {
            minV = min(minV, p)
            maxV = max(maxV, p)
        }

        for mesh in meshes {
            include(mesh.worldMinBounds)
            include(mesh.worldMaxBounds)
        }

        return (min: minV, max: maxV)
    }

    private func longestAxis(bounds: (min: simd_float3, max: simd_float3)) -> Int {
        let extents = bounds.max - bounds.min
        if extents.x > extents.y && extents.x > extents.z {
            return 0 // X
        } else if extents.y > extents.z {
            return 1 // Y
        } else {
            return 2 // Z
        }
    }
}