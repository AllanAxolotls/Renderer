import Combine

final class SceneManager {
    var cancellables = Set<AnyCancellable>()

    var currentScene: Scene? = nil {
        didSet {
            deinitListeners()
            initListeners()
            sceneSwitchedPublisher.send(currentScene)
        }
    }

    let sceneSwitchedPublisher = PassthroughSubject<Scene?, Never>()
    let sceneChildAddedPublisher = PassthroughSubject<Object, Never>()
    let sceneChildRemovedPublisher = PassthroughSubject<Object, Never>()

    func initListeners() {
        currentScene?.childAddedPublisher.sink { child in
            self.sceneChildAddedPublisher.send(child)
        }.store(in: &cancellables)
         currentScene?.childRemovedPublisher.sink { child in
            self.sceneChildRemovedPublisher.send(child)
        }.store(in: &cancellables)
    }
    
    func deinitListeners() {
        cancellables.removeAll()
    }

    func addObjectsToScene(_ objects: [Object]) {
        currentScene?.addChildren(objects)
    }
}