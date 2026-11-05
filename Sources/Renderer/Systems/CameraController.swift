import simd
import QuartzCore

final class CameraController {
    private unowned let sceneManager: SceneManager
    private unowned let inputManager: InputManager

    init(
        sceneManager: SceneManager,
        inputManager: InputManager
    ) {
        self.sceneManager = sceneManager
        self.inputManager = inputManager
    }

    @MainActor func update(deltaTime: CFTimeInterval) {
        guard let camera = sceneManager.currentScene?.currentCamera else { return }

        let deltaTime: Float = Float(deltaTime)
        let moveSpeed: Float = camera.moveSpeed * deltaTime
        let rotSpeed: Float = camera.rotateSpeed * deltaTime
        var moveDirection = simd_float3(0, 0, 0)

        if inputManager.isKeyDown(.Equals) { camera.moveSpeed = fmax(camera.moveSpeed + 20 * deltaTime, 0) } // Go Faster
        if inputManager.isKeyDown(.Minus)  { camera.moveSpeed = fmax(camera.moveSpeed - 20 * deltaTime, 0) } // Go Slower

        // WASD movement
        if inputManager.isKeyDown(.W) { moveDirection += camera.forward } // Forwards
        if inputManager.isKeyDown(.S) { moveDirection -= camera.forward } // Backwards
        if inputManager.isKeyDown(.A) { moveDirection -= camera.right   } // Left
        if inputManager.isKeyDown(.D) { moveDirection += camera.right   } // Right
        if inputManager.isKeyDown(.Q) { moveDirection += camera.up      } // Down
        if inputManager.isKeyDown(.E) { moveDirection -= camera.up      } // Up
        if simd_length(moveDirection) != 0 { camera.position += simd_normalize(moveDirection) * moveSpeed }

        // Arrow rotation
        if inputManager.isKeyDown(.LeftArrow)  { camera.rotate(yaw: -rotSpeed, pitch: 0) } // Rotate Left
        if inputManager.isKeyDown(.RightArrow) { camera.rotate(yaw: rotSpeed, pitch: 0)  } // Rotate Right
        if inputManager.isKeyDown(.UpArrow)    { camera.rotate(yaw: 0, pitch: rotSpeed)  } // Rotate Up
        if inputManager.isKeyDown(.DownArrow)  { camera.rotate(yaw: 0, pitch: -rotSpeed) } // Rotate Down

        let mouseYaw = min(max(inputManager.rightJoystick.x * camera.mouseSensivity, -100), 100)
        let mousePitch = min(max(inputManager.rightJoystick.y * camera.mouseSensivity, -100), 100)
        camera.rotate(yaw: mouseYaw, pitch: 0)
        camera.rotate(yaw: 0, pitch: mousePitch)
        inputManager.rightJoystick.x = 0; inputManager.rightJoystick.y = 0
    }
}