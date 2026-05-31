import MetalKit
import QuartzCore

class GameView: MTKView {
    private var keysDown: Set<UInt16> = []
    private var lastUpdate = CACurrentMediaTime()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        keysDown.insert(event.keyCode)

        if event.keyCode == 15 { // R
            renderMode = renderMode == .Raytracer ? .Rasterizer : .Raytracer
        }
    }

    override func keyUp(with event: NSEvent) {
        keysDown.remove(event.keyCode)
    }

    public func updateControls(camera: inout Camera) {
        let now = CACurrentMediaTime()
        let delta = Float(now - lastUpdate)
        lastUpdate = now

        let moveSpeed: Float = camera.moveSpeed * delta
        let rotSpeed: Float = camera.rotateSpeed * delta
        var moveDirection = simd_float3(0, 0, 0)

        // WASD movement
        if self.keysDown.contains(13) { moveDirection += camera.forward } // W
        if self.keysDown.contains(1) { moveDirection -= camera.forward } // S
        if self.keysDown.contains(0) { moveDirection -= camera.right } // A
        if self.keysDown.contains(2) { moveDirection += camera.right } // D
        if self.keysDown.contains(12) { moveDirection += camera.up } // Q
        if self.keysDown.contains(14) { moveDirection -= camera.up } // E
        if simd_length(moveDirection) != 0 { camera.position += simd_normalize(moveDirection) * moveSpeed }

        // Arrow rotation
        if self.keysDown.contains(123) { camera.rotate(yaw: -rotSpeed, pitch: 0) } // Left
        if self.keysDown.contains(124) { camera.rotate(yaw: rotSpeed, pitch: 0) } // Right
        if self.keysDown.contains(126) { camera.rotate(yaw: 0, pitch: -rotSpeed) } // Up
        if self.keysDown.contains(125) { camera.rotate(yaw: 0, pitch: rotSpeed) } // Down

        
    }
}
