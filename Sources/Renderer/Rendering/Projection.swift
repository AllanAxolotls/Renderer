import simd

@MainActor var projection_matrix = matrix_float4x4()

@MainActor func update_projection_matrix() {
    let screenSize = getScreenSize()
    let aspect = Float(screenSize.width / screenSize.height)
    let yScale = 1 / tan(FOVRad * 0.5)
    let xScale = yScale / aspect

    projection_matrix = matrix_float4x4(columns: (
        simd_float4(xScale, 0, 0, 0),
        simd_float4(0, yScale, 0, 0),
        simd_float4(0, 0, zFar / (zFar - zNear), 1),
        simd_float4(0, 0, -zNear * zFar / (zFar - zNear), 0)
    ))
}
