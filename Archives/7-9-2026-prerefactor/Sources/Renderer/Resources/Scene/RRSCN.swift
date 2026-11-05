// Serializer and Deserializer
import Foundation
import Compression
import simd

private let versionNumber: UInt32 = 0
private let sectionCount: UInt32 = 13
private let compressRRSCN: Bool = true

private enum SCN0SectionType: UInt32, CaseIterable {
    case Uniforms=0, Vertices, MaterialDatas
    case RasIndices, RTIndices, RTTriMatMap
    case SubMeshes, Meshes 
    case BLASNodes, TLASInstances, TLASNodes
    case MaterialMetas, StringPool

    /// Returns the exact 4-character ASCII string code for this section
    var magicString: String {
        switch self {
        case .Uniforms:         return "UNI0"
        case .Vertices:         return "VERT"
        case .MaterialDatas:    return "MAT0"
        case .RasIndices:       return "INDC"
        case .RTIndices:        return "RIDC"
        case .RTTriMatMap:      return "RTMM"
        case .SubMeshes:        return "SUBM"
        case .Meshes:           return "MESH"
        case .BLASNodes:        return "BNOD"
        case .TLASInstances:    return "TINS"
        case .TLASNodes:        return "TNOD"
        case .MaterialMetas:    return "MATM"
        case .StringPool:       return "STRP"
        }
    }

    /// Converts the string code into a 32-bit FourCC integer (little-endian)
    var fourCC: UInt32 {
        let bytes = Array(magicString.utf8.prefix(4))
        return bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
}

private enum RRSCNCompression: UInt32 {
    case none = 0
    case lzfse = 1
    //case zlib = 2
    //case lz4 = 3
}

private struct RRSCNHeader {
    let magicNumber: UInt32 
    let compressionType: UInt32
    let uncompressedSize: UInt32 // for scn0
    let compressedSize: UInt32
}

private struct SCN0Header {
    let magicNumber: UInt32 
    let versionNumber: UInt32
    let scn0Size: UInt32
    let sectionCount: UInt32 
}

private struct SCN0TOCEntry {
    let fourCC: UInt32
    let flags: UInt32 = 0
    let totalSize: UInt32
    let dataOffset: UInt32
}

func compress(_ data: Data, algorithm: compression_algorithm = COMPRESSION_LZFSE) -> Data? {
    if data.isEmpty {
        return Data()
    }

    var destinationSize = max(64, data.count)

    while true {
        var destination = Data(count: destinationSize)

        let compressedSize = data.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                compression_encode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    destinationSize,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
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

func decompress(
    _ data: Data,
    expectedSize: Int,
    algorithm: compression_algorithm = COMPRESSION_LZFSE
) -> Data? {

    if expectedSize == 0 {
        return Data()
    }

    var destination = Data(count: expectedSize)

    let decodedSize = data.withUnsafeBytes { sourceBuffer in
        destination.withUnsafeMutableBytes { destinationBuffer in
            compression_decode_buffer(
                destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                expectedSize,
                sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                algorithm
            )
        }
    }

    if decodedSize == 0 {
        return nil
    }

    destination.count = decodedSize
    return destination
}

public extension Scene {
    // if URL is given then serialize to that URL otherwise, if filename is given serialize to "Saves/(fileName).rrscn" else serialize to "Saves/\(self.name).rrscn"
    func serializeRRSCN(_ url: URL? = nil, fileName: String? = nil) {
        let savePath = url ?? URL(
            fileURLWithPath: (fileName ?? self.name).appending(".rrscn"),
            relativeTo: URL(fileURLWithPath: "Saves/")
        )
        /*
        let savePath = */
        // Change to this in the future if it becomes an app: let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

       

        var data = Data()

        // Reserve SCN0 Header
        let scn0HeaderSize = MemoryLayout<SCN0Header>.size
        data.append(contentsOf: Array(repeating: UInt8(0), count: scn0HeaderSize))

        // Table of Contents
        let tocOffset = scn0HeaderSize
        let tocEntrySize = MemoryLayout<SCN0TOCEntry>.size
        let tocSize = tocEntrySize * Int(sectionCount)
        data.append(contentsOf: Array(repeating: UInt8(0), count: tocSize))

        var scn0Size = UInt32(scn0HeaderSize + tocSize)

        // For StringPool
        struct ReservedString {
            let nameOffsetLocation: Int?
            let string: String
        }

        var reservedStrings: [ReservedString] = [
            ReservedString(nameOffsetLocation: nil, string: fileName ?? self.name)
        ]

        var dataOffset: UInt32 = UInt32(tocOffset + tocSize)
        for (index, sectionType) in SCN0SectionType.allCases.enumerated() {
            var bytes: [UInt8] = []

            switch sectionType {
                case .Uniforms:
                    var sceneId = self.id.uuid
                    withUnsafeBytes(of: &sceneId) { bytes.append(contentsOf: $0) }
                    withUnsafeBytes(of: &self.camera.position) { bytes.append(contentsOf: $0) }
                    withUnsafeBytes(of: &self.camera.orientation) { bytes.append(contentsOf: $0) }
                    withUnsafeBytes(of: &self.camera.moveSpeed) { bytes.append(contentsOf: $0) }
                    withUnsafeBytes(of: &self.camera.fov) { bytes.append(contentsOf: $0) }
                    withUnsafeBytes(of: &self.camera.zNear) { bytes.append(contentsOf: $0) }
                    withUnsafeBytes(of: &self.camera.zFar) { bytes.append(contentsOf: $0) }
                case .Vertices:
                    var count = UInt32(self.vertices.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    self.vertices.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                case .MaterialDatas:
                    var count = UInt32(self.materialDatas.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    self.materialDatas.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                case .RasIndices:
                    var count = UInt32(self.indices.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    self.indices.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                case .RTIndices:
                    var count = UInt32(self.tlas.reorderedIndices.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    self.tlas.reorderedIndices.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                case .RTTriMatMap:
                    var count = UInt32(self.tlas.triangleMaterialMap.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    self.tlas.triangleMaterialMap.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                case .SubMeshes:
                    var count: UInt32 = 0
                    for mesh in self.meshes { count += UInt32(mesh.subMeshes.count) }
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    for mesh in self.meshes {
                        mesh.subMeshes.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                    }
                case .Meshes:
                    var count = UInt32(self.meshes.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    var subMeshOffset: UInt32 = 0

                    for mesh in self.meshes {
                        var id = mesh.id.uuid
                        withUnsafeBytes(of: &id) { bytes.append(contentsOf: $0) }
                        var parentId = mesh.parentId?.uuid ?? self.id.uuid
                        withUnsafeBytes(of: &parentId) { bytes.append(contentsOf: $0) }
                        
                        reservedStrings.append(ReservedString(
                            nameOffsetLocation: data.count + bytes.count,
                            string: mesh.name
                        ))
                        bytes.append(contentsOf: Array(repeating: UInt8(0), count: 4))

                        withUnsafeBytes(of: &subMeshOffset) { bytes.append(contentsOf: $0) }
                        var subMeshCount = UInt32(mesh.subMeshes.count)
                        withUnsafeBytes(of: &subMeshCount) { bytes.append(contentsOf: $0) }
                        subMeshOffset += UInt32(subMeshCount)

                        var childrenCount = UInt32(mesh.childrenIds.count)
                        withUnsafeBytes(of: &childrenCount) { bytes.append(contentsOf: $0) }
                        for childId in mesh.childrenIds {
                            var childUUID = childId.uuid
                            withUnsafeBytes(of: &childUUID) { bytes.append(contentsOf: $0) }
                        }
                        var (pivot, position, rotation, scale, localMinBounds, localMaxBounds) = (mesh.pivot, mesh.position, mesh.rotation, mesh.scale, mesh.localMinBounds, mesh.localMaxBounds)
                        withUnsafeBytes(of: &pivot) { bytes.append(contentsOf: $0) }
                        withUnsafeBytes(of: &position) { bytes.append(contentsOf: $0) }
                        withUnsafeBytes(of: &rotation) { bytes.append(contentsOf: $0) }
                        withUnsafeBytes(of: &scale) { bytes.append(contentsOf: $0) }
                        withUnsafeBytes(of: &localMinBounds) { bytes.append(contentsOf: $0) }
                        withUnsafeBytes(of: &localMaxBounds) { bytes.append(contentsOf: $0) }
                    }
                    break
                case .BLASNodes:
                    var count = UInt32(self.tlas.blasNodes.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    self.tlas.blasNodes.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                case .TLASInstances:
                    var count = UInt32(self.tlas.tlasInstances.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    self.tlas.tlasInstances.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                case .TLASNodes:
                    var count = UInt32(self.tlas.tlasNodes.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    self.tlas.tlasNodes.withUnsafeBytes({ buffer in bytes.append(contentsOf: buffer) })
                case .MaterialMetas:
                    var count = UInt32(self.materials.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                    for material in self.materials {
                        var id = material.id.uuid
                        withUnsafeBytes(of: &id) { bytes.append(contentsOf: $0) }
                        reservedStrings.append(ReservedString(
                            nameOffsetLocation: data.count + bytes.count,
                            string: material.name
                        ))
                        bytes.append(contentsOf: Array(repeating: UInt8(0), count: 4))
                        
                        var materialDataIndex = material.materialDataIndex
                        withUnsafeBytes(of: &materialDataIndex) { bytes.append(contentsOf: $0) }

                        // Don't want to save absolute paths to a Scene
                        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        if let diffusePath = (material.diffuseTexturePath.map { relativePath(from: packageRoot, to: $0) }) {
                            reservedStrings.append(ReservedString(
                                nameOffsetLocation: data.count + bytes.count,
                                string: diffusePath
                            ))
                        }
                        bytes.append(contentsOf: Array(repeating: UInt8(0), count: 4))
                        if let dissolvePath = (material.dissolveTexturePath.map { relativePath(from: packageRoot, to: $0) }) {
                            reservedStrings.append(ReservedString(
                                nameOffsetLocation: data.count + bytes.count,
                                string: dissolvePath
                            ))
                        }
                        bytes.append(contentsOf: Array(repeating: UInt8(0), count: 4))
                    }
                    break
                case .StringPool:
                    var count = UInt32(reservedStrings.count)
                    withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }

                    for reservedString in reservedStrings {
                        let utf8 = Array(reservedString.string.utf8)
                        var stringLength = UInt32(utf8.count)
                        var stringOffset = UInt32(data.count + bytes.count)
                        
                        if let loc = reservedString.nameOffsetLocation {
                            withUnsafeBytes(of: &stringOffset) {
                                data.replaceSubrange(loc..<loc + 4, with: $0)
                            }
                        }

                        let remainder = (stringOffset + stringLength) % 4
                        if remainder != 0 {
                            let padding = 4 - remainder
                            stringLength += UInt32(padding)
                        }

                        withUnsafeBytes(of: &stringLength) { bytes.append(contentsOf: $0) }
                        bytes.append(contentsOf: utf8)

                        // align string entry
                        if remainder != 0 {
                            bytes.append(contentsOf: Array(repeating: 0, count: 4 - Int(remainder)) )
                        }
                    }
            }

            // Total size gets 64-bit aligned
            let remainder = bytes.count % 8
            let padding = (remainder != 0) ? (8 - remainder) : 0
            let totalSize = UInt32(bytes.count + padding)
            scn0Size += totalSize
            
            data.append(contentsOf: bytes)
            if (padding > 0) { data.append(contentsOf: Array(repeating: UInt8(0), count: padding)) }

            var tocEntry = SCN0TOCEntry(
                fourCC: sectionType.fourCC, 
                totalSize: totalSize, 
                dataOffset: dataOffset
            )

            dataOffset += totalSize

            let entryOffset = tocOffset + index * tocEntrySize
            withUnsafeBytes(of: &tocEntry) { data.replaceSubrange(entryOffset ..< entryOffset + tocEntrySize, with: $0) }
        }

        // Write Header
        var header = SCN0Header(
            magicNumber: UInt32.init(ascii: "SCN0"),
            versionNumber: versionNumber,
            scn0Size: scn0Size,
            sectionCount: sectionCount,
        )

        withUnsafeBytes(of: &header) { data.replaceSubrange(0 ..< scn0HeaderSize, with: $0)}

        if compressRRSCN {
            if let compressed = compress(data) {
                data = compressed
            } else {
                print("Failed to compress SCN0 data!")
            }
        }

        var headerData = Data()
        var rrscnHeader = RRSCNHeader(
            magicNumber: UInt32.init(ascii: "RRSC"),
            compressionType: compressRRSCN ? RRSCNCompression.lzfse.rawValue : RRSCNCompression.none.rawValue,
            uncompressedSize: scn0Size,
            compressedSize: UInt32(data.count)
        )
        withUnsafeBytes(of: &rrscnHeader) { headerData.append(contentsOf: $0) }

        headerData.append(data)

        do {
            try headerData.write(to: savePath, options: .atomic)
        } catch {
            print("Failed to write RRSCN file: \(error)")
        }
    }



    func deserializeRRSCN(_ url: URL) {
        var data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            print("Failed to read RRSCN file: \(error)")
            return
        }

        var offset = 0
        let rrscnHeaderSize = MemoryLayout<RRSCNHeader>.size
        let rrscnHeaderData = data.subdata(in: offset ..< offset + rrscnHeaderSize)
        let rrscnHeader = rrscnHeaderData.withUnsafeBytes { $0.load(as: RRSCNHeader.self) }
        offset += rrscnHeaderSize

        if (rrscnHeader.magicNumber != UInt32.init(ascii: "RRSC")) {
            print("Invalid RRSCN File!")
        }

        if rrscnHeader.compressionType == RRSCNCompression.lzfse.rawValue {
            if let decompressed = decompress(
                data.subdata(in: offset ..< offset + Int(rrscnHeader.compressedSize)),
                expectedSize: Int(rrscnHeader.uncompressedSize) + rrscnHeaderSize
            ) {
                data = rrscnHeaderData
                data.append(decompressed)
            } else {
                print("Decompression of SCN0 failed!")
            }
        }

        let headerSize = MemoryLayout<SCN0Header>.size
        let headerData = data.subdata(in: offset..<offset + headerSize)
        let header = headerData.withUnsafeBytes { $0.load(as: SCN0Header.self) }
        offset += headerSize

        if header.magicNumber != UInt32.init(ascii: "SCN0") {
            print("Invalid RRSCN File!")
            return
        }

        let tocEntrySize = MemoryLayout<SCN0TOCEntry>.size
        var tocEntries: [SCN0TOCEntry] = []

        for _ in 0..<header.sectionCount {
            let tocEntryData = data.subdata(in: offset..<offset + tocEntrySize)
            let tocEntry = tocEntryData.withUnsafeBytes { $0.load(as: SCN0TOCEntry.self) }
            tocEntries.append(tocEntry)
            offset += tocEntrySize
        }

        var subMeshes: [SubMesh] = []

        func readString(_ data: Data, offset: UInt32) -> String {
            let offset = Int(offset) + rrscnHeaderSize
            let length = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }

            let start = offset + 4
            let end = start + Int(length)

            return String(
                data: data.subdata(in: start..<end),
                encoding: .utf8
            ) ?? ""
        }

        self.dirtyFlags.ignoreTLASMakeDirties = true
        self.dirtyFlags.flags[DirtyFlagType.RebuildTLAS.rawValue] = false

        for (tocIndex, tocEntry) in tocEntries.enumerated() {
            let dataOffset = Int(tocEntry.dataOffset) + rrscnHeaderSize

            if (data.count < dataOffset + Int(tocEntry.totalSize)) {
                print("Invalid RRSCN file format: section data exceeds file size for tocIndex: \(tocIndex).\nTotalSize: \(tocEntry.totalSize), DataOffset: \(dataOffset), FileSize: \(data.count)")
                return
            }
            let sectionData = data.subdata(in: dataOffset ..< dataOffset + Int(tocEntry.totalSize))

            switch tocEntry.fourCC {
                case SCN0SectionType.Uniforms.fourCC:
                    var offset = 0
                    let sceneId = sectionData.withUnsafeBytes { $0.load(as: uuid_t.self) }
                    self.id = UUID(uuid: sceneId)
                    offset += MemoryLayout<uuid_t>.size
                    self.camera.position = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: simd_float3.self) }
                    offset += MemoryLayout<simd_float3>.stride
                    self.camera.orientation = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: simd_quatf.self) }
                    offset += MemoryLayout<simd_quatf>.stride
                    self.camera.moveSpeed = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
                    offset += MemoryLayout<Float>.size
                    self.camera.fov = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
                    offset += MemoryLayout<Float>.size
                    self.camera.zNear = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
                    offset += MemoryLayout<Float>.size
                    self.camera.zFar = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
                    
                case SCN0SectionType.Vertices.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let verticesData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<Vertex>.stride)
                    self.vertices = Array(verticesData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: Vertex.self).map { $0 }
                    })
                case SCN0SectionType.MaterialDatas.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let materialDatasData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<MaterialData>.stride)
                    self.materialDatas = Array(materialDatasData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: MaterialData.self).map { $0 }
                    })
                case SCN0SectionType.RasIndices.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let indicesData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<UInt32>.stride)
                    self.indices = Array(indicesData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: UInt32.self).map { $0 }
                    })
                case SCN0SectionType.RTIndices.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let indicesData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<UInt32>.stride)
                    self.tlas.reorderedIndices = Array(indicesData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: UInt32.self).map { $0 }
                    })
                case SCN0SectionType.RTTriMatMap.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let triMatMapData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<UInt32>.stride)
                    self.tlas.triangleMaterialMap = Array(triMatMapData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: UInt32.self).map { $0 }
                    })
                case SCN0SectionType.SubMeshes.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let subMeshData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<SubMesh>.stride)
                    subMeshes = Array(subMeshData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: SubMesh.self).map { $0 }
                    })
                case SCN0SectionType.Meshes.fourCC:
                    var offset = MemoryLayout<UInt32>.size
                    let count = sectionData.withUnsafeBytes { $0.load(as: UInt32.self) }

                    self.meshes.removeAll(keepingCapacity: true)

                    for _ in 0..<count {

                        let id = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: uuid_t.self) }
                        offset += MemoryLayout<uuid_t>.size
                        let parentId = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: uuid_t.self)}
                        offset += MemoryLayout<uuid_t>.size
                        let nameOffset = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
                        offset += MemoryLayout<UInt32>.size
                        let subMeshOffset = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
                        offset += MemoryLayout<UInt32>.size
                        let subMeshCount = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
                        offset += MemoryLayout<UInt32>.size
                        let childrenCount = Int(sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) })
                        offset += MemoryLayout<UInt32>.size

                        var childrenIds: [UUID] = []
                        childrenIds.reserveCapacity(childrenCount)

                        for _ in 0..<childrenCount {
                            let childUUID = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: uuid_t.self) }
                            offset += MemoryLayout<uuid_t>.size
                            childrenIds.append(UUID(uuid: childUUID))
                        }

                        // TODO: sohuldn't these be stride?
                        let pivot = sectionData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: SIMD3<Float>.self) }
                        offset += MemoryLayout<simd_float3>.stride
                        let position = sectionData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: SIMD3<Float>.self) }
                        offset += MemoryLayout<simd_float3>.stride
                        let rotation = sectionData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: SIMD3<Float>.self) }
                        offset += MemoryLayout<simd_float3>.stride
                        let scale = sectionData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: SIMD3<Float>.self) }
                        offset += MemoryLayout<simd_float3>.stride
                        let localMinBounds = sectionData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: SIMD3<Float>.self) }
                        offset += MemoryLayout<simd_float3>.stride
                        let localMaxBounds = sectionData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: SIMD3<Float>.self) }
                        offset += MemoryLayout<simd_float3>.stride

                        let mesh = Mesh(
                            id: UUID(uuid: id),
                            name: readString(data, offset: nameOffset),
                            subMeshes: Array(subMeshes[Int(subMeshOffset)..<Int(subMeshOffset + subMeshCount)]),
                            pivot: pivot,
                            position: position,
                            rotation: rotation,
                            scale: scale,
                            localMinBounds: localMinBounds,
                            localMaxBounds: localMaxBounds
                        )
                        mesh.parentId = UUID(uuid: parentId)
                        mesh.childrenIds.append(contentsOf: childrenIds)

                        self.meshes.append(mesh)
                    }
                case SCN0SectionType.BLASNodes.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let blasNodesData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<BLASNode>.stride)
                    self.tlas.blasNodes = Array(blasNodesData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: BLASNode.self).map { $0 }
                    })
                case SCN0SectionType.TLASInstances.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let tlasInstancesData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<TLASInstance>.stride)
                    self.tlas.tlasInstances = Array(tlasInstancesData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: TLASInstance.self).map { $0 }
                    })
                case SCN0SectionType.TLASNodes.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let tlasNodesData = sectionData.subdata(in: MemoryLayout<UInt32>.size..<MemoryLayout<UInt32>.size + count * MemoryLayout<TLASNode>.stride)
                    self.tlas.tlasNodes = Array(tlasNodesData.withUnsafeBytes { buffer in
                        buffer.bindMemory(to: TLASNode.self).map { $0 }
                    })
                case SCN0SectionType.MaterialMetas.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    var offset = MemoryLayout<UInt32>.size

                    self.materials.removeAll(keepingCapacity: true)

                    for _ in 0 ..< count {
                        let id = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: uuid_t.self) }
                        offset += MemoryLayout<uuid_t>.size
                        let nameOffset = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
                        offset += MemoryLayout<UInt32>.size
                        let materialDataIndex = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
                        offset += MemoryLayout<UInt32>.size
                        let diffuseTextureNameOffset = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
                        offset += MemoryLayout<UInt32>.size
                        let dissolveTextureNameOffset = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
                        offset += MemoryLayout<UInt32>.size

                        var material = Material(
                            id: UUID(uuid: id),
                            name: readString(data, offset: nameOffset)
                        )
                        material.materialDataIndex = materialDataIndex
                        if diffuseTextureNameOffset != 0 { material.diffuseTexturePath = URL(fileURLWithPath: readString(data, offset: diffuseTextureNameOffset)) }
                        if dissolveTextureNameOffset != 0 { material.dissolveTexturePath = URL(fileURLWithPath: readString(data, offset: dissolveTextureNameOffset)) }
                        self.materials.append(material)
                    }
  
                case SCN0SectionType.StringPool.fourCC:
                    let count = Int(sectionData.withUnsafeBytes { $0.load(as: UInt32.self) })
                    var offset = MemoryLayout<UInt32>.size

                    for i in 0..<count {
                        let stringLength = sectionData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
                        offset += MemoryLayout<UInt32>.size
                        let stringData = sectionData.subdata(in: offset..<offset + Int(stringLength))
                        if let string = String(data: stringData, encoding: .utf8) {
                            let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                            if i == 0 { 
                                self.name = trimmed
                                break
                            }
                        }
                        offset += Int(stringLength)
                    }

                    break
                default:
                    print("Deserialization for section \(tocEntry.fourCC) not implemented yet. (Index: \(tocIndex))")
            }
        }

        self.dirtyFlags.ignoreTLASMakeDirties = false
    }
}

public extension UInt32 {
    init(ascii: String) {
        let bytes = Array(ascii.utf8.prefix(4))
        self = bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
}
