import simd

let epsilon: Float = 0.0001

public struct Ray {
    let origin: simd_float3
    let direction: simd_float3
}

public struct RaycastResult {
    let hit: simd_float3
    let hitFace: RayTraceTriangleGPU
    let normal: simd_float3
    let distance: Float
    let barycentric: simd_float3
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
    var modelMatrix: matrix_float4x4
    var invModelMatrix: matrix_float4x4
    var invNormalMatrix: matrix_float3x3
}

public struct TLASNode {
    var minBounds: simd_float3
    var maxBounds: simd_float3
    var leftIndex: Int32 = -1
    var escapeIndex: Int32 = -1
    var instanceIndex: Int32 = -1
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

    public var blas_s: [BLAS] = []
    public var blasNodes: [BLASNode] = []
    public var faces: [RayTraceTriangleGPU] = []

    init(scene: Scene) {
        self.scene = scene;
        self.build()
    }

    public func build() {
        print("Building Acceleration Structure")
        tlasNodes = []
        tlasInstances = []
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
            tlasInstances.append(TLASInstance(
                blasStartIndex: 0, // Gets set in build()
                modelMatrix: meshes[0].modelMatrix ,
                invModelMatrix: meshes[0].invModelMatrix,
                invNormalMatrix: simd_transpose(matrix_float3x3(columns: (
                    simd_float3(meshes[0].invModelMatrix.columns.0.x, meshes[0].invModelMatrix.columns.0.y, meshes[0].invModelMatrix.columns.0.z),
                    simd_float3(meshes[0].invModelMatrix.columns.1.x, meshes[0].invModelMatrix.columns.1.y, meshes[0].invModelMatrix.columns.1.z),
                    simd_float3(meshes[0].invModelMatrix.columns.2.x, meshes[0].invModelMatrix.columns.2.y, meshes[0].invModelMatrix.columns.2.z)
                )))
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

    public func reform() {

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











public struct BVHNode {
    var boundsMin: simd_float3
    var boundsMax: simd_float3
    var leftIndex: Int32 = -1
    var rightIndex: Int32 = -1
    var faceOffset: Int32 = 0
    var faceCount: Int32 = 0
}

final class BVH {
    public var nodes: [BVHNode] = []
    public var leafFaces: [RayTraceTriangleGPU] = []
    public var headNodeIndex: Int32 = 0
    private var scene: Scene

    init(scene: Scene) {
        self.scene = scene
        self.build()
    }

    private func computeBounds(faces: [RayTraceTriangleGPU]) -> (min: simd_float3, max: simd_float3) {
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

    func intersectAABB(origin: simd_float3, direction: simd_float3, min: simd_float3, max: simd_float3) -> Bool {
        let invDirection = 1.0 / direction

        var tmin = (min.x - origin.x) * invDirection.x
        var tmax = (max.x - origin.x) * invDirection.x
        if tmin > tmax { swap(&tmin, &tmax) }
        
        var tymin = (min.y - origin.y) * invDirection.y
        var tymax = (max.y - origin.y) * invDirection.y
        if tymin > tymax { swap(&tymin, &tymax) }

        if (tmin > tymax || tymin > tmax) { return false }

        if tymin > tmin { tmin = tymin }
        if tymax < tmax { tmax = tymax }

        var tzmin = (min.z - origin.z) * invDirection.z
        var tzmax = (max.z - origin.z) * invDirection.z
        if tzmin > tzmax { swap(&tzmin, &tzmax) }

        if (tmin > tzmax || tzmin > tmax) { return false }
        return true
    }

    private func intersectsFace(ray: Ray, face: RayTraceTriangleGPU) -> RaycastResult? {
        let origin = ray.origin
        let direction = ray.direction
        let vertex1 = face.vertex1.position
        //let vertex2 = face.vertex2.position
        //let vertex3 = face.vertex3.position
        let edge1 = face.edge1
        let edge2 = face.edge2
        let normal = face.normal
        // Backface Culling, keeps CCW-wound triangles
        if (simd_dot(normal, direction) > 0) { return nil }

        let direction_cross_edge2 = simd_cross(direction, edge2)
        let det: Float = simd_dot(edge1, direction_cross_edge2)
        if abs(det) < epsilon { return nil }

        let inv_det: Float = 1.0 / det
        let s: simd_float3 = origin - vertex1
        let u: Float = inv_det * simd_dot(s, direction_cross_edge2)
        if u < -epsilon || u - 1 > epsilon { return nil }

        let s_cross_edge1 = simd_cross(s, edge1)
        let v: Float = inv_det * simd_dot(direction, s_cross_edge1)
        if v < -epsilon || u + v - 1 > epsilon { return nil }

        let t: Float = inv_det * simd_dot(edge2, s_cross_edge1)
        if (t > epsilon) { // && t <= 1) { // if t > 1 then ray is longer than segment length
            return RaycastResult(
                hit: origin + direction * t, 
                hitFace: face,
                normal: normal, 
                distance: t,
                barycentric: simd_float3(1.0-u-v, u, v)
            )
        }

        return nil
    }

    func traverse(ray: Ray) -> RaycastResult? {
        var stack: [Int32] = [headNodeIndex]
        var closestResult: RaycastResult? = nil

        while let nodeIndex = stack.popLast() {
            let node = nodes[Int(nodeIndex)]

            if !intersectAABB(origin: ray.origin, direction: ray.direction, min: node.boundsMin, max: node.boundsMax) {
                continue
            }

            switch (node.leftIndex, node.rightIndex) {
            case (-1, -1):
                for i in 0..<node.faceCount {
                    let face = leafFaces[Int(i + node.faceOffset)]
                    if let result = intersectsFace(ray: ray, face: face) {
                        if closestResult == nil || result.distance < closestResult!.distance {
                            closestResult = result
                        }
                    }
                }
            case let (leftIndex, -1):
                stack.append(leftIndex)
            case let (-1, rightIndex):
                stack.append(rightIndex)
            case let (leftIndex, rightIndex):
                stack.append(leftIndex)
                stack.append(rightIndex)
            }
        }

        return closestResult
    }


    func buildNode(faces: [RayTraceTriangleGPU]) -> Int32 {
        let bounds = computeBounds(faces: faces)
        let count = Int32(truncatingIfNeeded: faces.count)
        if count <= 4 {
            let index = Int32(truncatingIfNeeded: nodes.count)
            let faceOffset = Int32(truncatingIfNeeded: leafFaces.count)
            leafFaces.append(contentsOf: faces)
            nodes.append(BVHNode(
                boundsMin: bounds.min, boundsMax: bounds.max, 
                leftIndex: -1, rightIndex: -1,
                faceOffset: faceOffset, faceCount: count
            ))
            return index
        }

        let axis = longestAxis(bounds: bounds)
        let sorted = faces.sorted { centroid($0)[axis] < centroid($1)[axis] }
        let middle = sorted.count / 2
        let leftFaces = Array(sorted[..<middle])
        let rightFaces = Array(sorted[middle...])
        let leftNodeIndex = buildNode(faces: leftFaces)
        let rightNodeIndex = buildNode(faces: rightFaces)
        let index = Int32(truncatingIfNeeded: nodes.count)
        nodes.append(BVHNode(
            boundsMin: bounds.min, boundsMax: bounds.max, 
            leftIndex: leftNodeIndex, rightIndex: rightNodeIndex,
            faceOffset: 0, faceCount: 0,
        ))
        return index
    }

    func build() {
        var facesToGPU: [RayTraceTriangleGPU] = []
        func faceToGPU(_ face: Face) -> RayTraceTriangleGPU {
            let subMesh = scene.subMeshes[Int(face.subMeshIndex)]
            let vertex1 = scene.vertices[Int(face.vertexIndices.x)]
            let vertex2 = scene.vertices[Int(face.vertexIndices.y)]
            let vertex3 = scene.vertices[Int(face.vertexIndices.z)]
            let edge1 = vertex2.position - vertex1.position
            let edge2 = vertex3.position - vertex1.position
            return RayTraceTriangleGPU(
                vertex1: vertex1, vertex2: vertex2, vertex3: vertex3, 
                edge1: edge1, edge2: edge2,
                normal: simd_normalize(simd_cross(edge1, edge2)),
                materialIndex: subMesh.materialIndex
            )
        }
        for face in scene.faces { facesToGPU.append(faceToGPU(face)) }
        print("Building BVH")
        headNodeIndex = buildNode(faces: facesToGPU)
        print("Finished BVH")
    }
}



/*
final class BVHNode: @unchecked Sendable {
    var boundsMin: simd_float3
    var boundsMax: simd_float3
    var left: BVHNode?
    var right: BVHNode?
    var triangles: [Triangle]

    init(
        boundsMin: simd_float3,
        boundsMax: simd_float3,
        left: BVHNode? = nil,
        right: BVHNode? = nil,
        triangles: [Triangle] = []
    ) {
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.left = left
        self.right = right
        self.triangles = triangles
    }
}

public struct RaycastResult {
    var intersection: simd_float3
    var intersected: Triangle
    var normal: simd_float3
    var distance: Float
    var barycentric: simd_float3
    
}

public struct IntersectResult {
    var intersection: simd_float3
    var normal: simd_float3
    var distance: Float
    var barycentric: simd_float3
}

private func computeBounds(triangles: [Triangle]) -> (min: simd_float3, max: simd_float3) {
    var minV = simd_float3(repeating: Float.greatestFiniteMagnitude)
    var maxV = simd_float3(repeating: -Float.greatestFiniteMagnitude)

    func include(_ p: simd_float3) {
        minV = min(minV, p)
        maxV = max(maxV, p)
    }

    for triangle in triangles {
        include(triangle.vertices[0].position)
        include(triangle.vertices[1].position)
        include(triangle.vertices[2].position)
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

func centroid(_ triangle: Triangle) -> simd_float3 {
    return (triangle.vertices[0].position + triangle.vertices[1].position + triangle.vertices[2].position) / 3.0
}

func buildBVH(triangles: [Triangle]) -> BVHNode {
    let bounds = computeBounds(triangles: triangles)
    if triangles.count <= 4 {
        return BVHNode(boundsMin: bounds.min, boundsMax: bounds.max, triangles: triangles)
    }

    let axis = longestAxis(bounds: bounds)
    let sorted = triangles.sorted {
        centroid($0)[axis] < centroid($1)[axis]
    }

    let middle = sorted.count / 2
    let leftTriangles = Array(sorted[..<middle])
    let rightTriangles = Array(sorted[middle...])
    let leftNode = buildBVH(triangles: leftTriangles)
    let rightNode = buildBVH(triangles: rightTriangles)
    return BVHNode(boundsMin: bounds.min, boundsMax: bounds.max, left: leftNode, right: rightNode)
}

func intersectAABB(origin: simd_float3, direction: simd_float3, min: simd_float3, max: simd_float3) -> Bool {
    let invDirection = 1.0 / direction

    var tmin = (min.x - origin.x) * invDirection.x
    var tmax = (max.x - origin.x) * invDirection.x
    if tmin > tmax { swap(&tmin, &tmax) }
    
    var tymin = (min.y - origin.y) * invDirection.y
    var tymax = (max.y - origin.y) * invDirection.y
    if tymin > tymax { swap(&tymin, &tymax) }

    if (tmin > tymax || tymin > tmax) { return false }

    if tymin > tmin { tmin = tymin }
    if tymax < tmax { tmax = tymax }

    var tzmin = (min.z - origin.z) * invDirection.z
    var tzmax = (max.z - origin.z) * invDirection.z
    if tzmin > tzmax { swap(&tzmin, &tzmax) }

    if (tmin > tzmax || tzmin > tmax) { return false }
    return true
}

func traverseBVH(node: BVHNode?, origin: simd_float3, direction: simd_float3, filter: [Triangle]?, onlyCCW: Bool) -> RaycastResult? {
    guard let node = node else { return nil }
    if !intersectAABB(origin: origin, direction: direction, min: node.boundsMin, max: node.boundsMax) { 
        return nil 
    }
    // If it's a Leaf node then check triangles
    if node.left == nil && node.right == nil {
        var closest: RaycastResult?
        var closestDistance = Float.greatestFiniteMagnitude

        for triangle in node.triangles {
            if let filter = filter {
                var skip: Bool = false
                for filterTriangle in filter {
                    if filterTriangle === triangle { 
                        skip = true
                        break
                    }
                }

                if skip { continue }
            }

            if onlyCCW {
                if let result = intersectTriangleCCW(origin: origin, direction: direction, triangle: triangle) {
                    if result.distance < closestDistance {
                        closestDistance = result.distance
                        closest = RaycastResult(
                            intersection: result.intersection,
                            intersected: triangle,
                            normal: result.normal,
                            distance: result.distance,
                            barycentric: result.barycentric
                        )
                    }
                }
            } else {
                if let result = intersectTriangle(origin: origin, direction: direction, triangle: triangle) {
                    if result.distance < closestDistance {
                        closestDistance = result.distance
                        closest = RaycastResult(
                            intersection: result.intersection,
                            intersected: triangle,
                            normal: result.normal,
                            distance: result.distance,
                            barycentric: result.barycentric
                        )
                    }
                }
            }
        }

        return closest
    }

    let left = traverseBVH(node: node.left, origin: origin, direction: direction, filter: filter, onlyCCW: onlyCCW)
    let right = traverseBVH(node: node.right, origin: origin, direction: direction, filter: filter, onlyCCW: onlyCCW)

    switch (left, right) {
        case (nil, nil): return nil
        case let (l?, nil): return l
        case let (nil, r?): return r
        case let (l?, r?): return l.distance < r.distance ? l : r
    }
}

func intersectTriangle(origin: simd_float3, direction: simd_float3, triangle: Triangle) -> IntersectResult? {
    let v1 = triangle.vertices[0].position
    let v2 = triangle.vertices[1].position
    let v3 = triangle.vertices[2].position
    let edge1 = v2 - v1
    let edge2 = v3 - v1
    let normal = simd_cross(edge1, edge2)
    // Backface Culling, assumes CCW-wound triangles
    //if (simd_dot(normal, direction) > 0) { return nil }

    let direction_cross_edge2 = simd_cross(direction, edge2)
    let det: Float = simd_dot(edge1, direction_cross_edge2)
    if abs(det) < epsilon { return nil }

    let inv_det: Float = 1.0 / det
    let s: simd_float3 = origin - v1
    let u: Float = inv_det * simd_dot(s, direction_cross_edge2)
    if u < -epsilon || u - 1 > epsilon { return nil }

    let s_cross_edge1 = simd_cross(s, edge1)
    let v: Float = inv_det * simd_dot(direction, s_cross_edge1)
    if v < -epsilon || u + v - 1 > epsilon { return nil }

    let t: Float = inv_det * simd_dot(edge2, s_cross_edge1)
    if (t > epsilon) { // && t <= 1) { // if t > 1 then ray is longer than segment length
        return IntersectResult(
            intersection: origin + direction * t,
            normal: simd_normalize(normal), 
            distance: t,
            barycentric: simd_float3(1.0-u-v, u, v)
        )
    }

    return nil
}

// For CounterClockWise Rotated Triangles ONLY
func intersectTriangleCCW(origin: simd_float3, direction: simd_float3, triangle: Triangle) -> IntersectResult? {
    let v1 = triangle.vertices[0].position
    let v2 = triangle.vertices[1].position
    let v3 = triangle.vertices[2].position
    let edge1 = v2 - v1
    let edge2 = v3 - v1
    let normal = simd_cross(edge1, edge2)
    // Backface Culling, assumes CCW-wound triangles
    if (simd_dot(normal, direction) > 0) { return nil }

    let direction_cross_edge2 = simd_cross(direction, edge2)
    let det: Float = simd_dot(edge1, direction_cross_edge2)
    if abs(det) < epsilon { return nil }

    let inv_det: Float = 1.0 / det
    let s: simd_float3 = origin - v1
    let u: Float = inv_det * simd_dot(s, direction_cross_edge2)
    if u < -epsilon || u - 1 > epsilon { return nil }

    let s_cross_edge1 = simd_cross(s, edge1)
    let v: Float = inv_det * simd_dot(direction, s_cross_edge1)
    if v < -epsilon || u + v - 1 > epsilon { return nil }

    let t: Float = inv_det * simd_dot(edge2, s_cross_edge1)
    if (t > epsilon) { // && t <= 1) { // if t > 1 then ray is longer than segment length
        return IntersectResult(
            intersection: origin + direction * t,
            normal: simd_normalize(normal), 
            distance: t,
            barycentric: simd_float3(1.0-u-v, u, v)
        )
    }

    return nil
}


func castRay(origin: simd_float3, direction: simd_float3, meshes: [Mesh]) -> RaycastResult? {
    var smallestDistance: Float = Float.infinity
    var closestResult: RaycastResult? = nil

    for mesh in meshes {
        for submesh in mesh.subMeshes {
            for i in 0 ..< submesh.triangles.count {
                let triangle = submesh.triangles[i]
                if let intersectResult = intersectTriangleCCW(origin: origin, direction: direction, triangle: triangle) {
                    if intersectResult.distance < smallestDistance {
                        smallestDistance = intersectResult.distance
                        closestResult = RaycastResult(
                            intersection: intersectResult.intersection, 
                            intersected: triangle, 
                            normal: intersectResult.normal, 
                            distance: intersectResult.distance,
                            barycentric: intersectResult.barycentric,
                        )
                    }
                }
            }
        } 
    }
    return closestResult
}
*/