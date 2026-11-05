import Foundation
import Compression

@MainActor final class SceneSaver {
    private unowned let engine: Ryx

    init(engine: Ryx) {
        self.engine = engine
    }

    func saveScene(url: URL?, compressionType: RyxSceneCompressionType = .lzfse) {
        guard let scene = self.engine.sceneManager.currentScene else { return }
        let savePath = url ?? URL(
            fileURLWithPath: scene.name.appending(".rrscn"),
            relativeTo: URL(fileURLWithPath: "Saves/")
        )
        
        var data = Data()

        // Reserve Scene Header
        data.append(contentsOf: Array(repeating: UInt8(0), count: MemoryLayout<RyxSceneHeader>.size))
        
        // Save the Body
        let bodyOffset = MemoryLayout<RyxSceneHeader>.size
        var body = Data()

        // Table of Contents
        var sectionCount = UInt64(RyxSceneSectionType.allCases.count)
        withUnsafeBytes(of: &sectionCount) { body.append(contentsOf: $0) }
        // Reserve every section on in the TOC
        let tocEntrySize = MemoryLayout<RyxSceneTocEntry>.size
        let sizeOfTocEntries = tocEntrySize * Int(sectionCount)
        body.append(contentsOf: Array(repeating: UInt8(0), count: sizeOfTocEntries))

        for (sectionIndex, sectionType) in RyxSceneSectionType.allCases.enumerated() {
            let currentBodySize = body.count
            let payloadOffset = UInt64(currentBodySize + bodyOffset)
            let versionNumber: UInt32 = 0

            switch sectionType {
                case .vertices:           body.appendMTLBufferAllocator(engine.resourceManager.vertexAllocator)
                case .indices:            body.appendMTLBufferAllocator(engine.resourceManager.indexAllocator)           
                case .baseMaterials:      body.appendMTLBufferAllocator(engine.resourceManager.materialAllocator)
                case .meshTris:           body.appendMTLBufferAllocator(engine.collisionManager.meshTriAllocator)
                case .blasNodes:          body.appendMTLBufferAllocator(engine.collisionManager.blasNodeAllocator)
                case .tlasNodes:          body.appendMTLBufferAllocator(engine.collisionManager.tlasNodeAllocator)
                case .tlasInstances:      body.appendMTLBufferAllocator(engine.collisionManager.tlasInstanceAllocator)
                case .meshes:

                    break
                case .meshResources:     
                    break
                case .materials: 
                    break
                case .materialResources: 
                    break
                case .textures:          
                    break
                case .textureResources:  
                    break
                case .meshLibrary:       
                    break
                case .materialLibrary:   
                    break
                case .sceneGraph:        
                    break
            }

            let payloadByteSize = UInt64(body.count - currentBodySize)
            var tocEntry = RyxSceneTocEntry(
                magicNumber: sectionType.fourCC, 
                versionNumber: versionNumber, 
                payloadByteSize: payloadByteSize, 
                payloadAbsoluteByteOffset: payloadOffset
            )

            let tocEntryOffset = MemoryLayout<UInt64>.size + tocEntrySize * sectionIndex
            withUnsafeBytes(of: &tocEntry) { body.replaceSubrange(tocEntryOffset ..< tocEntryOffset + tocEntrySize, with: $0)}
        }

        // Compress Body
        let uncompressedBodySize: UInt64 = UInt64(body.count)
        if let compressionAlgorithm = compressionType.getCompressionAlgorithm() {
            body = body.compress(algorithm: compressionAlgorithm)
        }
        let compressedBodySize: UInt64 = UInt64(body.count)
        data.append(body)

        // Fill in reserved Scene Header
        var ryxSceneHeader = RyxSceneHeader(
            magicNumber: UInt32.init(ascii: "RYXS"), 
            versionNumber: 0, 
            compressionType: .none, 
            flags: 0, 
            tocOffset: UInt64(bodyOffset), 
            compressedBodySize: compressedBodySize, 
            uncompressedBodySize: uncompressedBodySize
        )
        withUnsafeBytes(of: &ryxSceneHeader) { data.replaceSubrange(0 ..< MemoryLayout<RyxSceneHeader>.size, with: $0) }

        do {
            try data.write(to: savePath, options: .atomic)
        } catch {
            print("Failed to save Ryx Scene: \(error)")
        }
    }
}

extension Data {
    func compress(algorithm: compression_algorithm = COMPRESSION_LZFSE) -> Data {
        if self.isEmpty { return self }

        var destinationSize = Swift.max(64, self.count)
        while true {
            var destination = Data(count: destinationSize)

            let compressedSize = self.withUnsafeBytes { sourceBuffer in
                destination.withUnsafeMutableBytes { destinationBuffer in
                    compression_encode_buffer(
                        destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        destinationSize,
                        sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        self.count,
                        nil,
                        algorithm
                    )
                }
            }

            if compressedSize != 0 {
                destination.count = compressedSize
                return destination
            }

            destinationSize *= 2
        }
    }

    func decompress(algorithm: compression_algorithm = COMPRESSION_LZFSE, uncompressedSize: UInt64?) -> Data {
        if uncompressedSize == 0 { return Data() }

        // TODO: make it not self.count * 2, find another way for it to not have to need the expectedSize upfront
        let expectedSize = Int(uncompressedSize ?? UInt64(self.count * 2))
        var destination = Data(count: expectedSize)
        let decodedSize = self.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                compression_decode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    self.count,
                    nil,
                    algorithm
                )
            }
        }

        if decodedSize == 0 { return Data() }
        destination.count = decodedSize
        return destination
    }

    mutating func appendWithUnsafeBytes<T>(_ bytes: inout T) {
        Swift.withUnsafeBytes(of: &bytes) { self.append(contentsOf: $0) }
    }

    mutating func append(_ newElement: UInt32) {
        var copy = newElement
        self.appendWithUnsafeBytes(&copy)
    }

    mutating func append<T>(_ newElement: [T]) {
        self.append(UInt32(newElement.count))
        var copy = newElement
        self.appendWithUnsafeBytes(&copy)
    }

    mutating func append(_ newElement: String) {
        self.append(UInt32(newElement.count))
        self.append(contentsOf: Array(newElement.utf8))
    }

    mutating func appendMTLBufferAllocator<T>(_ newElement: MTLBufferAllocator<T>) {
        self.append(UInt32(newElement.count))
        self.appendWithUnsafeBytes(&newElement.buffer)
    }
}

extension UInt32 {
    init(ascii: String) {
        let bytes = Array(ascii.utf8.prefix(4))
        self = bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
}

extension Resource {
    struct SerializedResource {
        let objectId: ObjectIdentifier

    }

    func serialize() -> Data {
        return Data()
    }
}

extension Object {
    func serialize() -> Data {
        return Data()
    }
}