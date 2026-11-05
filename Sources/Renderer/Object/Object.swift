import Foundation
import Combine

class Object : Hashable {
    var id: UUID
    var name: String

    private(set) var children: [Object] = []
    private weak var _parent: Object? = nil

    var parent: Object? {
        get { _parent }
        set {
            guard let newParent = newValue else {
                self.destroy(); 
                return 
            }

            // To avoid self-parenting
            guard newParent !== self else { return }

            if newParent !== _parent { 
                removeParentReference()
                _parent = newParent
                newParent.children.append(self)
            }
        }
    }

    var descendants: [Object] {
        var _descendants: [Object] = children
        for child in children { _descendants.append(contentsOf: child.descendants) }
        return _descendants
    }

    init (id: UUID = UUID(), name: String = "Default Object", parent: Object? = nil) {
        self.id = id
        self.name = name
        self._parent = parent
        if let parent = parent { parent.children.append(self) }
    }

    func destroy() {
        removeParentReference()
        let childrenCopy = children
        for child in childrenCopy { child.destroy() }
    }

    static func == (lhs: Object, rhs: Object) -> Bool { return lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private func removeParentReference() {
         if let parent = self.parent {
            if let index = parent.children.firstIndex(where: { $0 === self }) {
                parent.children.remove(at: index)
            }
            self._parent = nil
        }
    }
    
    let childAddedPublisher = PassthroughSubject<Object, Never>()
    func addChild(_ child: Object) {
        child.parent = self
        childAddedPublisher.send(child)
    }

    let childRemovedPublisher = PassthroughSubject<Object, Never>()
    func removeChild(_ child: Object) {
        if child.parent !== self { return } 
        child.removeParentReference()
        childRemovedPublisher.send(child)
    }
    
    func addChildren(_ children: [Object]) {
        for child in children { addChild(child) }
    }

    func removeChildren() {
        for child in children { removeChild(child) }
    }


    func findFirstChild(name: String) -> Object? {
        for child in children { if child.name == name { return child } }
        return nil
    }

    func findFirstDescendant(name: String) -> Object? {
        for child in children { 
            if child.name == name { return child }
            let result = child.findFirstDescendant(name: name)
            if result != nil { return result }
        }
        return nil
    }

    func findFirstAncestor(name: String) -> Object? {
        guard let parent = self.parent else { return nil }
        if parent.name == name { return parent }
        return parent.findFirstAncestor(name: name)
    }
}