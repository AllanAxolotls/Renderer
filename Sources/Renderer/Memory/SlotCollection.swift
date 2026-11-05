final class SlotCollection<T> {
    private var slots: [T?] = []
    private var freeIndices: [Int] = []
    
    var count: Int {
        return slots.count - freeIndices.count
    }
    
    /// Inserts an element and returns its stable index handle
    @discardableResult
    func insert(_ element: T) -> Int {
        if let freeIndex = freeIndices.popLast() {
            slots[freeIndex] = element
            return freeIndex
        } else {
            let newIndex = slots.count
            slots.append(element)
            return newIndex
        }
    }
    
    /// Removes an element at a given index without shifting other elements
    func remove(at index: Int) -> T? {
        guard index >= 0 && index < slots.count, let existing = slots[index] else { return nil }
        slots[index] = nil
        freeIndices.append(index)
        return existing
    }
    
    subscript(index: Int) -> T? {
        get {
            guard index >= 0 && index < slots.count else { return nil }
            return slots[index]
        }
        set {
            guard index >= 0 && index < slots.count else { return }
            slots[index] = newValue
        }
    }
    
    /// Flattens the collection into an array without holes by replacing empty slots with a fallback
    func packed(using fallback: T) -> [T] {
        return slots.map { $0 ?? fallback }
    }
}