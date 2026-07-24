import MetalKit
import QuartzCore

class GameView: MTKView {
    private var keysDown: Set<UInt16> = []
    private var lastUpdate = CACurrentMediaTime()
    public var rightJoystick = simd_float2(0, 0)
    private var ignoreNextMouseDelta = false
    public var scene: Scene? = nil

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

    override func mouseDown(with event: NSEvent) {
        if let scene = scene {
            let mouseLocation = event.locationInWindow
            let viewSize = self.bounds.size
            let ndcX = (Float(mouseLocation.x) / Float(viewSize.width)) * 2 - 1
            let ndcY = 1 - (Float(mouseLocation.y) / Float(viewSize.height)) * 2
            let aspectRatio = Float(viewSize.width / viewSize.height)
            let projectedX = ndcX * aspectRatio * tan(FOVRad * 0.5)
            let projectedY = ndcY * tan(FOVRad * 0.5)

            let rayOrigin = scene.camera.position
            let rayDirection = simd_normalize(scene.camera.forward + projectedX * scene.camera.right + projectedY * scene.camera.up)

            let result = scene.tlas?.raycast(origin: rayOrigin, direction: rayDirection)
            if let hit = result {
                print("Hit Mesh Index: \(hit.instanceIndex), Face Index: \(hit.faceIndex), Position: \(hit.hit)")

                // Mesh toevoegen na scene al gebouwd is werkt nog niet omdat
                // de rasterizer van tevoren opaque en transparent sorteert,
                // daarnaast moet de TLAS gerformed worden
                /*
                let importer = ObjectImporter(device: nil)
                let asset = importer.importObject(filePath: "Assets/FriedChicken/FriedChicken.obj")
                for mesh in asset.meshes {
                    //mesh.position = hit.hit
                }
                scene.addAsset(asset)
                */
            } else {
                print("No hit")
            }
        }
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

    public func updateControls(camera: inout Camera) {
        let now = CACurrentMediaTime()
        let delta = Float(now - lastUpdate)
        lastUpdate = now

        let moveSpeed: Float = camera.moveSpeed * delta
        let rotSpeed: Float = camera.rotateSpeed * delta
        var moveDirection = simd_float3(0, 0, 0)

        // Camera Speed Adjustment
        if self.keysDown.contains(24) { camera.moveSpeed = fmax(camera.moveSpeed + 20 * delta, 0) } // = Go Faster
        if self.keysDown.contains(27) { camera.moveSpeed = fmax(camera.moveSpeed - 20 * delta, 0) } // - Go Slower

        // WASD movement
        if self.keysDown.contains(13) { moveDirection += camera.forward } // W Forwards
        if self.keysDown.contains(1) { moveDirection -= camera.forward } // S Backwards
        if self.keysDown.contains(0) { moveDirection -= camera.right } // A Left
        if self.keysDown.contains(2) { moveDirection += camera.right } // D Right
        if self.keysDown.contains(14) { moveDirection += camera.up } // Q Down
        if self.keysDown.contains(12) { moveDirection -= camera.up } // E Up
        if simd_length(moveDirection) != 0 { camera.position += simd_normalize(moveDirection) * moveSpeed }

        // Arrow rotation
        if self.keysDown.contains(123) { camera.rotate(yaw: -rotSpeed, pitch: 0) } // Left
        if self.keysDown.contains(124) { camera.rotate(yaw: rotSpeed, pitch: 0) } // Right
        if self.keysDown.contains(126) { camera.rotate(yaw: 0, pitch: -rotSpeed) } // Up
        if self.keysDown.contains(125) { camera.rotate(yaw: 0, pitch: rotSpeed) } // Down

        let mouseYaw = min(max(rightJoystick.x * camera.mouseSensivity, -100), 100)
        let mousePitch = min(max(rightJoystick.y * camera.mouseSensivity, -100), 100)
        camera.rotate(yaw: mouseYaw, pitch: 0)
        camera.rotate(yaw: 0, pitch: mousePitch)
        rightJoystick.x = 0; rightJoystick.y = 0
    }
}
