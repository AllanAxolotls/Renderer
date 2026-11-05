import MetalKit
import QuartzCore
import Combine

public enum KeyCodes : UInt16 {
    case A = 0
    case S = 1
    case D = 2
    case E = 12
    case W = 13
    case Q = 14
    case R = 15
    case Equals = 24
    case Minus = 27
    case LeftArrow = 123
    case RightArrow = 124
    case UpArrow = 125
    case DownArrow = 126
    case Space = 49
}

class GameView: MTKView {
    private var keysDown: Set<UInt16> = []
    private var lastUpdate = CACurrentMediaTime()
    public var rightJoystick = simd_float2(0, 0)
    private var ignoreNextMouseDelta = false

    override var acceptsFirstResponder: Bool { true }

    public var renderModeDirty: Bool = false
    public var renderPausedDirty: Bool = false

    override func keyDown(with event: NSEvent) {
        keysDown.insert(event.keyCode)
        switch event.keyCode {
            case KeyCodes.R.rawValue: renderModeDirty = true
            case KeyCodes.Space.rawValue: renderPausedDirty = true
            default: break
        }
    }

    override func keyUp(with event: NSEvent) {
        keysDown.remove(event.keyCode)
    }

    public let mouseDownBinding = PassthroughSubject<NSEvent, Never>()
    override func mouseDown(with event: NSEvent) {
        mouseDownBinding.send(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        NSCursor.hide()
        ignoreNextMouseDelta = true
        recenterMouse()
    }
    
    override func rightMouseUp(with event: NSEvent) {
        NSCursor.unhide()
    }

    override func rightMouseDragged(with event: NSEvent) {
        if ignoreNextMouseDelta {
            ignoreNextMouseDelta = false
            return
        }

        let screenSize = getScreenSize()
        rightJoystick.x += min(max(Float(event.deltaX) / Float(screenSize.width), -2), 2)
        rightJoystick.y += min(max(Float(event.deltaY) / Float(screenSize.height), -2), 2)
        recenterMouse()
    }

    public func recenterMouse() {
        if let window = self.window {
            let centerPointInView = NSPoint(x: self.bounds.midX, y: self.bounds.midY)
            let centerPointInWindow = self.convert(centerPointInView, to: nil)
            let centerPointInScreen = window.convertPoint(toScreen: centerPointInWindow)
            CGWarpMouseCursorPosition(centerPointInScreen)
        }
    }

    public func updateCamera(_ camera: inout Camera) {
        let now = CACurrentMediaTime()
        let delta = Float(now - lastUpdate)
        lastUpdate = now

        let moveSpeed: Float = camera.moveSpeed * delta
        let rotSpeed: Float = camera.rotateSpeed * delta
        var moveDirection = simd_float3(0, 0, 0)

        // Camera Speed Adjustment
        if self.keysDown.contains(KeyCodes.Equals.rawValue) { camera.moveSpeed = fmax(camera.moveSpeed + 20 * delta, 0) } // Go Faster
        if self.keysDown.contains(KeyCodes.Minus.rawValue)  { camera.moveSpeed = fmax(camera.moveSpeed - 20 * delta, 0) } // Go Slower

        // WASD movement
        if self.keysDown.contains(KeyCodes.W.rawValue) { moveDirection += camera.forward } // Forwards
        if self.keysDown.contains(KeyCodes.S.rawValue) { moveDirection -= camera.forward } // Backwards
        if self.keysDown.contains(KeyCodes.A.rawValue) { moveDirection -= camera.right   } // Left
        if self.keysDown.contains(KeyCodes.D.rawValue) { moveDirection += camera.right   } // Right
        if self.keysDown.contains(KeyCodes.Q.rawValue) { moveDirection += camera.up      } // Down
        if self.keysDown.contains(KeyCodes.E.rawValue) { moveDirection -= camera.up      } // Up
        if simd_length(moveDirection) != 0 { camera.position += simd_normalize(moveDirection) * moveSpeed }

        // Arrow rotation
        if self.keysDown.contains(KeyCodes.LeftArrow.rawValue)  { camera.rotate(yaw: -rotSpeed, pitch: 0) } // Rotate Left
        if self.keysDown.contains(KeyCodes.RightArrow.rawValue) { camera.rotate(yaw: rotSpeed, pitch: 0)  } // Rotate Right
        if self.keysDown.contains(KeyCodes.UpArrow.rawValue)    { camera.rotate(yaw: 0, pitch: rotSpeed)  } // Rotate Up
        if self.keysDown.contains(KeyCodes.DownArrow.rawValue)  { camera.rotate(yaw: 0, pitch: -rotSpeed) } // Rotate Down

        let mouseYaw = min(max(rightJoystick.x * camera.mouseSensivity, -100), 100)
        let mousePitch = min(max(rightJoystick.y * camera.mouseSensivity, -100), 100)
        camera.rotate(yaw: mouseYaw, pitch: 0)
        camera.rotate(yaw: 0, pitch: mousePitch)
        rightJoystick.x = 0; rightJoystick.y = 0
    }
}
