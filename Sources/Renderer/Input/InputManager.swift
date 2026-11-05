import Cocoa
import simd
import Combine

@MainActor final class InputManager {
    private unowned let gameView: GameView

    var keysDown: Set<KeyCode> = []
    var ignoreNextMouseDelta: Bool = false
    var rightJoystick = simd_float2(0, 0)

    let eventPublisher = PassthroughSubject<NSEvent, Never>()

    init(gameView: GameView) {
        self.gameView = gameView

        gameView.onEvent = { [weak self] event in
            self?.handleEvent(event)
            self?.eventPublisher.send(event)
        }
    }

    private func handleEvent(_ event: NSEvent) {
        switch event.type {
            case .keyDown:
                if !event.isARepeat {
                    keysDown.insert(KeyCode(rawValue: event.keyCode)!)
                }
            case .keyUp:
                keysDown.remove(KeyCode(rawValue: event.keyCode)!)
            case .leftMouseDown:
                break
            case .rightMouseDown:
                rightJoystick = simd_float2(0, 0)
                ignoreNextMouseDelta = true
            case .rightMouseUp:
                rightJoystick = simd_float2(0, 0)
                ignoreNextMouseDelta = false
            case .rightMouseDragged:
                if ignoreNextMouseDelta {
                    ignoreNextMouseDelta = false
                    return
                }

                let screenSize = gameView.drawableSize
                rightJoystick.x += min(max(Float(event.deltaX) / Float(screenSize.width), -2), 2)
                rightJoystick.y += min(max(Float(event.deltaY) / Float(screenSize.height), -2), 2)

            default:
                break
        }
    }

    public func isKeyDown(_ keyCode: KeyCode) -> Bool {
        return keysDown.contains(keyCode)
    }
}
