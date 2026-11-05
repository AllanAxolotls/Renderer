// TODO: Add a ability to forloop over a BufferAllocator

import Metal
import Foundation

class MTLBufferAllocator<T> {
    unowned private let device: MTLDevice
    var buffer: MTLBuffer
    let bufferOptions: MTLResourceOptions
    private let lock = NSRecursiveLock()

    private var allocList = Set<WeakHandle>()
    private var freeList: [FreeBlock] = []

    // The bigger, the less memory fragmentation (hopefully)
    let minimumSplitDifference: Int = 0x20 // 32 bytes
    let initialLength: Int

    private let stride: Int = MemoryLayout<T>.stride
    var allocatedSize : Int { buffer.allocatedSize }
    var length        : Int { buffer.length        }
    var count         : Int { length / stride      }

    var maximumLength: Int? = nil

    init(
        device: MTLDevice, 
        initialCount: Int = 1, 
        bufferOptions: MTLResourceOptions = [.storageModeShared]
    ) {
        self.device = device
        self.initialLength = MemoryLayout<T>.stride * initialCount
        self.bufferOptions = bufferOptions
        self.buffer = device.makeBuffer(length: initialLength, options: bufferOptions)!

        // Add the sentinel Handle, this is initiates the splitting algorithm
        freeList.append( FreeBlock(offset: 0, count: initialCount, size: initialLength) )
    }

    deinit {
        // In the case that the MTLBufferAllocator gets deinitialized before the handles, deactivate them
        for weakHandle in allocList {
            guard let handle = weakHandle.handle else { continue }
            handle.deactivate()
        }
    }

    func initEmptyHandle() -> Handle { return Handle.initEmpty() }

    func getAllocations() -> [Handle] {
        var handles: [Handle] = []
        for weakHandle in allocList {
            guard let handle = weakHandle.handle else { continue }
            handles.append(handle)
        }
        return handles
    }

    func alloc(count: Int = 1) -> Handle? {
        lock.lock()
        defer { lock.unlock() }

        let size = MemoryLayout<T>.stride * count
        var freeHandleIndex: Int = -1
        var splitHandle: Bool = false


        for (offset, handle) in freeList.enumerated() {
            if handle.size >= size {
                freeHandleIndex = offset
                splitHandle = handle.size > (size + minimumSplitDifference)
                break
            }
        }

        // if there is a free-block available with the minimum size, use it
        if freeHandleIndex != -1 {
            let offset = freeList[freeHandleIndex].offset
            var allocatedSize = size

            if splitHandle {
                // Re-use the old free handle but shift it and reconfigure it
                freeList[freeHandleIndex].offset += size
                freeList[freeHandleIndex].count -= count
                freeList[freeHandleIndex].size -= size
            } else {
                allocatedSize = freeList[freeHandleIndex].size
                freeList.remove(at: freeHandleIndex)
            }

            //print("New Alloc, count: \(count), allocSize: \(allocatedSize) for type: \(T.self)")
            let handle = Handle(offset: offset, count: count, allocatedSize: allocatedSize, parentAllocator: self)
            allocList.insert(WeakHandle( handle ))

            return handle
        }

        // else increase the buffer length
        let oldBufferLength = buffer.length
        let targetLength = Int( Float(oldBufferLength + size) * 1.25 )
        let alignedLength = (targetLength + stride - 1) / stride * stride

        do {
            try resizeBuffer(newLength: alignedLength) 
        } catch {
            print("MTLBufferAllocator: failed to resize buffer, \(error)")
            return nil
        }

        // Retry allocating but with a resized buffer
        return alloc(count: count)
    }

    func allocAndInit(count: Int = 1, pointer: UnsafePointer<T>) -> Handle? {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = alloc(count: count) else {  return nil  }
        guard let destPointer = handle.getPointer() else { return nil }

        destPointer.initialize(from: pointer, count: count)
        return handle
    }

    /// Frees up space for a new allocation
    func free(handle: Handle) {
        lock.lock()
        defer { lock.unlock() }

        if handle.parentAllocator !== self {
            fatalError("MTLBufferAllocator: Handle parentAllocator doesn't match self, wrong allocator got used for freeing!")
        }

        // for Empty Handles:
        guard handle.count != 0 else {
            handle.deactivate()
            return
        }

        var leftOffset: Int? = nil
        var rightOffset: Int? = nil
        var closestLeft: FreeBlock? = nil
        var closestRight: FreeBlock? = nil

        for (offset, candidate) in freeList.enumerated() {
            if candidate.offset > handle.offset {
                rightOffset = offset
                closestRight = candidate
                break
            }

            leftOffset = offset
            closestLeft = candidate
        }

        let mergeLeft: Bool = handle.offset == (closestLeft?.offset ?? -1) + (closestLeft?.size ?? 0)
        let mergeRight: Bool = handle.offset + handle.allocatedSize == (closestRight?.offset ?? -1)

        //print("Freeing Handle, count: \(handle.count), index: \(handle.index) for type: \(T.self)")

        allocList.remove(WeakHandle( handle ))
        

        if !mergeLeft && !mergeRight {
            let freeBlock = FreeBlock(offset: handle.offset, count: handle.count, size: handle.allocatedSize)
            freeList.insert(freeBlock, at: rightOffset ?? freeList.count)

        } else if mergeLeft && !mergeRight {
            if let leftOffset = leftOffset {
                freeList[leftOffset].count += handle.count
                freeList[leftOffset].size += handle.allocatedSize
            }

        } else if !mergeLeft && mergeRight {
            if let rightOffset = rightOffset {
                freeList[rightOffset].offset -= handle.allocatedSize
                freeList[rightOffset].count += handle.count
                freeList[rightOffset].size += handle.allocatedSize
            }

        } else {
            if let rightOffset = rightOffset { freeList.remove(at: rightOffset) }
            if let leftOffset = leftOffset, let closestRight = closestRight {
                freeList[leftOffset].count += handle.count + closestRight.count
                freeList[leftOffset].size += handle.allocatedSize + closestRight.size
            }

        }

        handle.deactivate()
    }

    func realloc(handle: Handle, newCount: Int) -> Handle? {
        let oldOffset = handle.offset
        let oldSize = handle.usedSize
        guard let srcPointer = handle.getPointer() else { return nil }

        // Marks the block as free, but the bytes are still there
        free(handle: handle)

        guard let newHandle = alloc(count: newCount) else {
            fatalError("MTLBufferAllocator: Reallocation failed!")
        }

        // If the reallocation is at the same memory offset, there is no need to memmove
        if newHandle.offset == oldOffset { return newHandle }

        // If the handle had no data, there is nothing to copy
        if oldSize <= 0 { return newHandle }

        let bytesToCopy = min(oldSize, newHandle.usedSize)
        memmove(newHandle.getPointer(), srcPointer, bytesToCopy)

        return newHandle
    }


    func resizeBuffer(newLength: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        let oldLength: Int = buffer.length
        if oldLength == newLength { return }

        // In the case that the buffer shrinks, do a safety check so no memory corruption occurs
        if newLength < oldLength {
            for allocHandle in allocList {
                guard let handle = allocHandle.handle else { continue }
                if (handle.index + handle.allocatedSize) >= newLength {
                    throw NSError(domain: "MTLBufferAllocator", code: 2, userInfo: [NSLocalizedDescriptionKey: "resizeBuffer failed, allocated size > newLength, causing memory corruption"])
                }
            }
        }

        guard let newBuffer = device.makeBuffer(length: newLength, options: bufferOptions) else { 
            throw NSError(domain: "MTLBufferAllocator", code: 1, userInfo: [NSLocalizedDescriptionKey: "device.makeBuffer failed"]) 
        }

        memcpy(newBuffer.contents(), self.buffer.contents(), self.buffer.length)
        self.buffer = newBuffer

        /*
        If the buffer has a free-block at the end it should be extended to the new length
        if there is no free-block at the end, create a new one instead
        */

        var extendLast: Bool = false
        if let last = freeList.last {
            // Check if it's a trailing free-block
            extendLast = (last.offset + last.size) >= oldLength 
        }

        if extendLast {
            let size = newLength - freeList[freeList.count - 1].offset
            freeList[freeList.count - 1].size = size
            freeList[freeList.count - 1].count = size / stride 
        } else {
            let size = newLength - oldLength
            let count = size / stride
            freeList.append( FreeBlock(offset: oldLength, count: count, size: size) )
        }
    }

    /// Removes all Memory Fragmentation
    /// TODO: CollisionManager and all other managers do not support this yet!
    func compact() {
        lock.lock()
        defer { lock.unlock() }

        // Just to be safe, technically not required
        allocList = allocList.filter{ $0.handle != nil }

        let activeHandles = allocList.compactMap { $0.handle }
        let sortedHandles = activeHandles.sorted { $0.offset < $1.offset }

        var currentDestinationByteOffset = 0
        let contents = buffer.contents()

        for handle in sortedHandles {
            let sourceByteOffset = handle.offset
            let destByteOffset = currentDestinationByteOffset

            if sourceByteOffset != destByteOffset {
                let srcPtr = contents.advanced(by: sourceByteOffset)
                let dstPtr = contents.advanced(by: destByteOffset)
                memmove(dstPtr, srcPtr, handle.usedSize)
            }

            handle.offset = destByteOffset
            currentDestinationByteOffset += handle.allocatedSize
        }

        // Completely reset the freeList and add just one block if there is space
        freeList.removeAll()

        let totalBufferBytes = buffer.length
        let remainingBytes = totalBufferBytes - currentDestinationByteOffset

        if remainingBytes > 0 {
            let freeCount = remainingBytes / stride
            let trailingFreeBlock = FreeBlock(
                offset: currentDestinationByteOffset, 
                count: freeCount, 
                size: remainingBytes
            )
            freeList.append(trailingFreeBlock)
        }
    }

    subscript(index: Int) -> T? {
        get {
            let elementCount = count
            guard index >= 0 && index < elementCount else { return nil }
            return self.buffer.contents().bindMemory(to: T.self, capacity: elementCount)[index]
        }
    }


    class Handle {
        weak var parentAllocator: MTLBufferAllocator<T>?
        var offset: Int { didSet {
            for tagMap in observers.values {
                for action in tagMap.values { action() }
            }
        }}
        private(set) var count: Int
        private(set) var usedSize: Int
        private(set) var allocatedSize: Int
        var index: Int { offset / MemoryLayout<T>.stride }
        private var observers: [ObjectIdentifier: [String: () -> Void]] = [:]
        private(set) var activated: Bool = true

        init(offset: Int = 0, count: Int = 0, allocatedSize: Int? = nil, parentAllocator: MTLBufferAllocator<T>? = nil, activated: Bool = true) {
            self.parentAllocator = parentAllocator
            self.offset = offset
            self.count = count
            self.usedSize = MemoryLayout<T>.stride * count
            self.allocatedSize = allocatedSize ?? self.usedSize
            self.activated = activated
        }

        func addOffsetChangedObserver(key: AnyObject, tag: String = "default", action: @escaping () -> Void) {
            let objectID = ObjectIdentifier(key)
            
            if observers[objectID] == nil { observers[objectID] = [:] }
            observers[objectID]?[tag] = action
            
            action() // Sync initial state immediately
        }

        func removeOffsetChangedObserver(key: AnyObject, tag: String? = nil) {
            let objectID = ObjectIdentifier(key)
            if let tag = tag {
                observers[objectID]?.removeValue(forKey: tag)
                if observers[objectID]?.isEmpty == true {
                    observers.removeValue(forKey: objectID)
                }
            } else {
                // Remove all tags for this key if no tag specified
                observers.removeValue(forKey: objectID)
            }
        }

        static func initEmpty() -> Handle { return Handle(activated: false) }
        deinit { free() }

        func free() {
            if activated {
                print("Freed Handle \(T.self) with count: \(self.count)")
                parentAllocator?.free(handle: self)
                deactivate()
            }
        }

        var first: T? {
            guard count > 0, let pointer = getPointer() else { return nil }
            return pointer.pointee
        }

        var last: T? {
            guard count > 0, let pointer = getPointer() else { return nil }
            return pointer[count - 1]
        }

        subscript(index: Int) -> T? {
            get {
                guard index >= 0 && index < count, let pointer = getPointer() else { return nil }
                return pointer[index]
            }
        }

        func getRawPointer() -> UnsafeMutableRawPointer? {
            return parentAllocator?.buffer.contents().advanced(by: self.offset)
        }

        func getPointer() -> UnsafeMutablePointer<T>? {
            return getRawPointer()?.bindMemory(to: T.self, capacity: count)
        }

        func getArrayCopy() -> [T]? {
            guard let pointer = getPointer() else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }

        func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<T>) throws -> R) rethrows -> R {
            guard let rawPointer = getRawPointer() else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            
            let typedPointer = rawPointer.bindMemory(to: T.self, capacity: count)
            let bufferPointer = UnsafeBufferPointer(start: typedPointer, count: count)
            return try body(bufferPointer)
        }

        func deactivate() {
            activated = false
            parentAllocator = nil
        }
    }


    private class WeakHandle : Hashable {
        weak var handle: Handle?
        private let objectID: ObjectIdentifier

        init(_ handle: Handle) { 
            self.handle = handle 
            self.objectID = ObjectIdentifier(handle)
        }

        static func == (lhs: WeakHandle, rhs: WeakHandle) -> Bool {
            return (lhs.objectID == rhs.objectID)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(objectID)
        }
    }

    struct FreeBlock {
        var offset: Int
        var count: Int
        var size: Int
    }
}
