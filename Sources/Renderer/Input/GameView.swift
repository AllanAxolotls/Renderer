import MetalKit
import QuartzCore

class GameView: MTKView {

    var keysDown: Set<UInt16> = []
    var lastUpdate = CACurrentMediaTime()

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

        let moveSpeed: Float = camera_move_speed * delta
        let rotSpeed: Float = camera_rotate_speed * delta

        // WASD movement
        if self.keysDown.contains(13) { camera.position += camera.forward * moveSpeed } // W
        if self.keysDown.contains(1) { camera.position -= camera.forward * moveSpeed } // S
        if self.keysDown.contains(0) { camera.position -= camera.right * moveSpeed } // A
        if self.keysDown.contains(2) { camera.position += camera.right * moveSpeed } // D
        if self.keysDown.contains(12) { camera.position += camera.up * moveSpeed } // Q
        if self.keysDown.contains(14) { camera.position -= camera.up * moveSpeed } // E
        // Arrow rotation
        if self.keysDown.contains(123) { camera.rotate(yaw: -rotSpeed, pitch: 0) } // Left
        if self.keysDown.contains(124) { camera.rotate(yaw: rotSpeed, pitch: 0) } // Right
        if self.keysDown.contains(126) { camera.rotate(yaw: 0, pitch: -rotSpeed) } // Up
        if self.keysDown.contains(125) { camera.rotate(yaw: 0, pitch: rotSpeed) } // Down
    }
}
