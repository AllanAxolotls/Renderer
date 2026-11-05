// TODO: ADD INSTANCING: if the BLAS structure is the same for a model, make only one BLAS and reference it via both TLASInstances

import simd

let epsilon: Float = 0.0001

public struct Ray {
    let origin: simd_float3
    let direction: simd_float3
}

public struct RaycastResult {
    var hit: simd_float3 = simd_float3(0, 0, 0)
    var hitFace: RayTraceTriangleGPU? = nil
    var normal: simd_float3 = simd_float3(0, 1, 0)
    var distance: Float = .infinity
    var barycentric: simd_float3 = simd_float3(1, 0, 0)
}

public struct BLASNode {
    var minBounds: simd_float3
    var maxBounds: simd_float3
    var leftIndex: Int32 = -1
    var escapeIndex: Int32 = -1
    var faceOffset: Int32 = 0
    var faceCount: Int32 = 0
}

public struct TLASInstance {
    var blasStartIndex: Int32
    var modelMatrix: simd_float4x4
    var invModelMatrix: simd_float4x4
    var invNormalMatrix: simd_float3x3
}

public struct TLASNode {
    var minBounds: simd_float3
    var maxBounds: simd_float3
    var leftIndex: Int32 = -1
    var escapeIndex: Int32 = -1
    var instanceIndex: Int32 = -1
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

public func intersectsFace(origin: simd_float3, direction: simd_float3, face: RayTraceTriangleGPU) -> RaycastResult {
    let normal = face.normal
    // Backface Culling, keeps CCW-wound triangles
    if simd_dot(normal, direction) > 0 { return RaycastResult() }

    let edge1 = face.edge1
    let edge2 = face.edge2
    let direction_cross_edge2 = simd_cross(direction, edge2)
    let det = simd_dot(edge1, direction_cross_edge2) // Triple Scalar Product
    if abs(det) < epsilon { return RaycastResult() }

    let invDet = 1.0 / det
    let vertex1 = face.vertex1.position
    let s = origin - vertex1
    let u = invDet * simd_dot(s, direction_cross_edge2)
    if u < -epsilon || u - 1 > epsilon { return RaycastResult() }

    let s_cross_edge1 = simd_cross(s, edge1)
    let v = invDet * simd_dot(direction, s_cross_edge1)
    if v < -epsilon || u + v - 1 > epsilon { return RaycastResult() }

    let t = invDet * simd_dot(edge2, s_cross_edge1)
    if t > epsilon {
        var result = RaycastResult()
        result.hit = origin + direction * t
        result.hitFace = face
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

    init(scene: Scene, mesh: Mesh) {
        self.scene = scene
        self.mesh = mesh
        self.build()
    }

    public func build() {
        blasNodes = []
        leafFaces = []
        leafFaceOffset = 0
        blasStartIndex = buildNode(faces: makeGPUFaces(), isRight: true)
    }

    @discardableResult
    public func buildNode(faces: [RayTraceTriangleGPU], isRight: Bool) -> Int32 {
        assert(!faces.isEmpty)
        let startIndex = Int32(blasNodes.count)
        let bounds = computeBounds(faces: faces)
        var node = BLASNode(minBounds: bounds.min, maxBounds: bounds.max)
        let faceCount: Int32 = Int32(faces.count)
        if faceCount <= 8 { // try 4 and 2
            node.leftIndex = -1
            node.escapeIndex = isRight ? -1 : startIndex + 1
            node.faceOffset = leafFaceOffset
            leafFaceOffset += faceCount
            node.faceCount = faceCount
            self.leafFaces.append(contentsOf: faces)
            blasNodes.append(node)
            return startIndex
        }

        blasNodes.append(node)
        let axis = longestAxis(bounds: bounds)
        let sorted = faces.sorted { centroid($0)[axis] < centroid($1)[axis] }
        let middle = sorted.count / 2
        let left = Array(sorted[..<middle])
        let right = Array(sorted[middle...])
        let leftIndex = buildNode(faces: left, isRight: false)
        buildNode(faces: right, isRight: isRight)
        let subtreeEnd = Int32(blasNodes.count)
        blasNodes[Int(startIndex)].leftIndex = leftIndex
        blasNodes[Int(startIndex)].escapeIndex = isRight ? -1 : subtreeEnd
        return startIndex
    }

    public func computeBounds(faces: [RayTraceTriangleGPU]) -> (min: simd_float3, max: simd_float3) {
        var minV = simd_float3(repeating: Float.greatestFiniteMagnitude)
        var maxV = simd_float3(repeating: -Float.greatestFiniteMagnitude)

        func include(_ p: simd_float3) {
            minV = min(minV, p)
            maxV = max(maxV, p)
        }

        for face in faces {
            include(face.vertex1.position)
            include(face.vertex2.position)
            include(face.vertex3.position)
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
        return (face.vertex1.position + face.vertex2.position + face.vertex3.position) / 3.0
    }

    public func makeGPUFaces() -> [RayTraceTriangleGPU] {
        var faces: [RayTraceTriangleGPU] = []
        for faceIndex in mesh.faceOffset ..< mesh.faceOffset + mesh.faceCount {
            let face = scene.faces[Int(faceIndex)]
            let subMesh = scene.subMeshes[Int(face.subMeshIndex)]
            let vertex1 = scene.vertices[Int(face.vertexIndices.x)]
            let vertex2 = scene.vertices[Int(face.vertexIndices.y)]
            let vertex3 = scene.vertices[Int(face.vertexIndices.z)]
            let edge1 = vertex2.position - vertex1.position
            let edge2 = vertex3.position - vertex1.position
            faces.append(RayTraceTriangleGPU(
                vertex1: vertex1, vertex2: vertex2, vertex3: vertex3, 
                edge1: edge1, edge2: edge2,
                // TODO: Change to 3 normals in future
                normal: simd_normalize(simd_cross(edge1, edge2)),
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

    private func traverseBLAS(origin: simd_float3, direction: simd_float3, invDirection: simd_float3, blasStartIndex: Int32) -> RaycastResult {
        var closestResult = RaycastResult()
        var nodeIndex: Int = Int(blasStartIndex)

        while nodeIndex != -1 {
            let node: BLASNode = blasNodes[nodeIndex]
            if intersectsAABB(origin: origin, invDirection: invDirection, min: node.minBounds, max: node.maxBounds) {
                if node.leftIndex == -1 {
                    for i in node.faceOffset ..< node.faceCount + node.faceOffset {
                        let face = faces[Int(i)]
                        let result = intersectsFace(origin: origin, direction: direction, face: face)
                        if result.distance < closestResult.distance {
                            closestResult = result
                        } 
                    }
                    nodeIndex = Int(node.escapeIndex)
                } else {
                    nodeIndex = Int(node.leftIndex)
                }
            } else {
                nodeIndex = Int(node.escapeIndex)
            }
        }

        return closestResult
    }

    private func traverseTLAS(origin: simd_float3, direction: simd_float3, invDirection: simd_float3) -> RaycastResult {
        var closestResult = RaycastResult()
        var nodeIndex: Int = 0
        
        while nodeIndex != -1 {
            let node: TLASNode = tlasNodes[nodeIndex]
            if intersectsAABB(origin: origin, invDirection: invDirection, min: node.minBounds, max: node.maxBounds) {
                if node.leftIndex == -1 {
                    let instance: TLASInstance = tlasInstances[Int(node.instanceIndex)]
                    let localOrigin4 = instance.invModelMatrix * simd_float4(origin, 1)
                    let localOrigin = simd_float3(localOrigin4.x, localOrigin4.y, localOrigin4.z)
                    let localDirection4 = instance.invModelMatrix * simd_float4(direction, 0)
                    let localDirection = simd_normalize(simd_float3(localDirection4.x, localDirection4.y, localDirection4.z))
                    let localInverseDirection = 1.0 / localDirection
                    var result = traverseBLAS(origin: localOrigin, direction: localDirection, invDirection: localInverseDirection, blasStartIndex: instance.blasStartIndex)

                    if result.distance != .infinity {
                        let worldHit4 = instance.modelMatrix * simd_float4(result.hit, 1)
                        let worldHit = simd_float3(worldHit4.x, worldHit4.y, worldHit4.z)
                        result.distance = simd_length(worldHit - origin)

                        if result.distance < closestResult.distance {
                            result.hit = worldHit
                            result.normal = simd_normalize(instance.invNormalMatrix * result.normal)
                            closestResult = result
                        }
                    }
                    nodeIndex = Int(node.escapeIndex)
                } else {
                    nodeIndex = Int(node.leftIndex)
                }
            } else {
                nodeIndex = Int(node.escapeIndex)
            }
        }
        return closestResult
    }

    public func raycast(origin: simd_float3, direction: simd_float3) -> RaycastResult {
        let invDirection = 1.0 / direction
        return traverseTLAS(origin: origin, direction: direction, invDirection: invDirection)
    }

    public func build() {
        print("Building Acceleration Structure")
        tlasNodes = []
        tlasInstances = []
        tlasInstancesToMeshes = []
        blas_s = []
        blasNodes = []
        faces = []
        _ = buildNode(meshes: scene.meshes, isRight: true)

        for (index, blas) in blas_s.enumerated() {
            let nodeShift = Int32(self.blasNodes.count)
            self.tlasInstances[index].blasStartIndex = nodeShift
            let faceOffset = Int32(self.faces.count)
            for blasNodeIndex in 0..<blas.blasNodes.count {
                var blasNode = blas.blasNodes[blasNodeIndex]
                if blasNode.leftIndex >= 0 { blasNode.leftIndex += nodeShift }
                if blasNode.escapeIndex >= 0 { blasNode.escapeIndex += nodeShift }
                blasNode.faceOffset += faceOffset
                self.blasNodes.append(blasNode)
            }
            self.faces.append(contentsOf: blas.leafFaces)
        }

        print("Finished Building Acceleration Structure")
    }

    @discardableResult
    public func buildNode(meshes: [Mesh], isRight: Bool) -> Int32 {
        assert(!meshes.isEmpty)
        let startIndex = Int32(tlasNodes.count)
        let bounds = computeMeshBounds(meshes: meshes)
        var node = TLASNode(minBounds: bounds.min, maxBounds: bounds.max)

        if meshes.count == 1 {
            node.leftIndex = -1
            node.escapeIndex = isRight ? -1 : startIndex + 1 // if every branch is right, this is the last node thus escape index should be -1 to mark traversal stop

            let instanceIndex = Int32(tlasInstances.count)
            tlasInstancesToMeshes.append(meshes[0])
            tlasInstances.append(TLASInstance(
                blasStartIndex: 0, // Gets set in build()
                modelMatrix: meshes[0].modelMatrix ,
                invModelMatrix: meshes[0].invModelMatrix,
                invNormalMatrix: meshes[0].normalMatrix
            ))

            self.blas_s.append(BLAS(scene: scene, mesh: meshes[0]))
           
            node.instanceIndex = instanceIndex
            tlasNodes.append(node)
            return startIndex
        }

        tlasNodes.append(node)

        let axis = longestAxis(bounds: bounds)
        let sorted = meshes.sorted { $0.pivot[axis] < $1.pivot[axis] }
        let middle = sorted.count / 2
        let left = Array(sorted[..<middle])
        let right = Array(sorted[middle...])
        let leftIndex = buildNode(meshes: left, isRight: false)
        buildNode(meshes: right, isRight: isRight)
        let subtreeEnd = Int32(tlasNodes.count)
        tlasNodes[Int(startIndex)].leftIndex = leftIndex
        tlasNodes[Int(startIndex)].escapeIndex = isRight ? -1 : subtreeEnd
        return startIndex
    }

    public func reform() { // This only fixes bounds, over time with many modelMatrix adjustments, the TLAS becomes less and less efficient
        // Update Instances with new transformations
        for i in 0..<tlasInstances.count {
            let mesh = tlasInstancesToMeshes[i] // Only works if TLASInstances and meshes are in this exact order
            tlasInstances[i].modelMatrix = mesh.modelMatrix
            tlasInstances[i].invModelMatrix = mesh.invModelMatrix
            tlasInstances[i].invNormalMatrix = mesh.normalMatrix
        }

        for i in (0..<tlasNodes.count).reversed() {
            if tlasNodes[i].leftIndex == -1 {
                // Leaf Node: Bound it tightly to its moved instance world bounds
                let instanceIndex = Int(tlasNodes[i].instanceIndex)
                let mesh = tlasInstancesToMeshes[instanceIndex]
                tlasNodes[i].minBounds = mesh.worldMinBounds
                tlasNodes[i].maxBounds = mesh.worldMaxBounds
            } else {
                let leftIndex = Int(tlasNodes[i].leftIndex)
                let rightIndex = Int(tlasNodes[leftIndex].escapeIndex)
                let leftMin = tlasNodes[leftIndex].minBounds
                let leftMax = tlasNodes[leftIndex].maxBounds
                let rightMin = tlasNodes[rightIndex].minBounds
                let rightMax = tlasNodes[rightIndex].maxBounds
                tlasNodes[i].minBounds = min(leftMin, rightMin)
                tlasNodes[i].maxBounds = max(leftMax, rightMax)
            }
        }
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