import Combine
import QuartzCore
import MetalKit

@MainActor final class InputController {
    private unowned let inputManager: InputManager
    private unowned let gameView: GameView

    var cancellables = Set<AnyCancellable>()
    private var rightMouseDragDebounce: Bool = false

    var renderModeDirty: Bool = false
    var pausedDirty: Bool = false

    init(
        inputManager: InputManager,
        gameView: GameView
    ) {
        self.inputManager = inputManager
        self.gameView = gameView
        initListeners()
    }

    func initListeners() {
        inputManager.eventPublisher.sink { event in
        switch event.type {
            case .keyDown:           self.keyDown(with: event)
            case .rightMouseDown:    self.rightMouseDown()
            case .rightMouseUp:      self.rightMouseUp()
            case .rightMouseDragged: self.rightMouseDragged(with: event)
            default: break
        }

        }.store(in: &cancellables)
    }

    func deinitListeners() {
        cancellables.removeAll()
    }

    private func keyDown(with event: NSEvent) {
        guard let keyCode = KeyCode(rawValue: event.keyCode) else { return }
        switch keyCode {
            case KeyCode.R:
                renderModeDirty = true
            case KeyCode.Space:
                pausedDirty = true
            default: 
                break
        }
    }

    private func rightMouseDown() {
        NSCursor.hide()
        rightMouseDragDebounce = true
        recenterMouse()
    }

    private func rightMouseUp() {
        NSCursor.unhide()
    }

    private func rightMouseDragged(with event: NSEvent) {
        if rightMouseDragDebounce {
            rightMouseDragDebounce = false
            return
        }

        recenterMouse()
    }

    func recenterMouse() {
        if let window = gameView.window {
            let centerPointInView = NSPoint(x: gameView.bounds.midX, y: gameView.bounds.midY)
            let centerPointInWindow = gameView.convert(centerPointInView, to: nil)
            let centerPointInScreen = window.convertPoint(toScreen: centerPointInWindow)
            CGWarpMouseCursorPosition(centerPointInScreen)
        }
    }
}