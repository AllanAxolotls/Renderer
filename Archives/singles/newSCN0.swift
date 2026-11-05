// Serializer and Deserializer
import Foundation

private let versionNumber: UInt32 = 0
private let sectionCount: UInt32 = 12

private enum RRSCNSectionType: CaseIterable {
    case Vertices, MaterialDatas, RasIndices, RTIndices, RTTriMatMap
    case SubMeshes, Meshes 
    case BLASNodes, TLASInstances, TLASNodes
    case MaterialMetas, TextureLinks, StringPool

    /// Returns the exact 4-character ASCII string code for this section
    var magicString: String {
        switch self {
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
        case .TextureLinks:     return "TEXL"
        case .StringPool:       return "STRP"
        }
    }

    /// Converts the string code into a 32-bit FourCC integer (little-endian)
    var fourCC: UInt32 {
        let bytes = Array(magicString.utf8.prefix(4))
        return bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
}

private struct RRSCNHeader {
    let magicNumber: UInt32 
    let versionNumber: UInt32
    let fileSize: UInt32
    let tocOffset: UInt32
    let sectionCount: UInt32
}

private struct RRSCNTOCEntry {
    let fourCC: UInt32
    let flags: UInt32 = 0
    let totalSize: UInt32
    let dataOffset: UInt32
}

struct BinaryWriter {
    var data = Data()

    mutating func write<T>(_ value: T) {
        var value = value
        withUnsafeBytes(of: &value) {
            data.append(contentsOf: $0)
        }
    }

    mutating func writeBytes<T>(_ values: [T]) {
        values.withUnsafeBytes {
            data.append(contentsOf: $0)
        }
    }

    mutating func writeRaw(_ data: Data) {
        self.data.append(data)
    }

    @discardableResult
    mutating func writeString(_ string: String) -> Int {
        let offset = data.count

        let bytes = Array(string.utf8)

        write(UInt32(bytes.count))
        data.append(contentsOf: bytes)

        while data.count % 4 != 0 {
            data.append(0)
        }

        return offset
    }

    @discardableResult
    mutating func reserve(_ count: Int) -> Int {
        let offset = data.count
        data.append(contentsOf: repeatElement(UInt8(0), count: count))
        return offset
    }

    mutating func patch<T>(_ offset: Int, value: T) {
        var value = value

        withUnsafeBytes(of: &value) {
            data.replaceSubrange(
                offset..<offset + MemoryLayout<T>.size,
                with: $0
            )
        }
    }

    mutating func align(_ alignment: Int) {
        while data.count % alignment != 0 {
            data.append(0)
        }
    }
}

struct BinaryReader {

    let data: Data
    var offset: Int = 0


    mutating func read<T>() -> T {

        let value = data.withUnsafeBytes {
            $0.load(
                fromByteOffset: offset,
                as: T.self
            )
        }

        offset += MemoryLayout<T>.size

        return value
    }


    mutating func readArray<T>(_ count: Int) -> [T] {

        let size = MemoryLayout<T>.size * count

        let result = data.withUnsafeBytes {
            Array(
                $0
                .load(
                    fromByteOffset: offset,
                    as: UnsafeRawBufferPointer.self
                )
                .bindMemory(to: T.self)
            )
        }

        offset += size

        return result
    }


    mutating func readString() -> String {

        let length: UInt32 = read()

        let start = offset
        let end = start + Int(length)

        let string = String(
            data: data[start..<end],
            encoding: .utf8
        ) ?? ""

        offset = end

        // 4 byte alignment
        while offset % 4 != 0 {
            offset += 1
        }

        return string
    }


    mutating func seek(_ position: Int) {
        offset = position
    }
}

public extension Scene {

func serializeRRSCN(_ fileName: String?) {

    let savePath = URL(
        fileURLWithPath: (fileName ?? self.name).appending(".rrscn"),
        relativeTo: URL(fileURLWithPath: "Saves/")
    )


    struct PendingString {
        let patchLocation: Int
        let value: String
    }


    var writer = BinaryWriter()

    // Reserve header
    let headerOffset = writer.reserve(
        MemoryLayout<RRSCNHeader>.size
    )

    // Reserve TOC
    let tocOffset = writer.data.count

    let tocEntrySize = MemoryLayout<RRSCNTOCEntry>.size

    writer.reserve(
        tocEntrySize * RRSCNSectionType.allCases.count
    )


    var pendingStrings: [PendingString] = []

    @discardableResult
    func reserveString(_ string: String) -> Int {
        let location = writer.reserve(4)

        pendingStrings.append(
            PendingString(
                patchLocation: location,
                value: string
            )
        )

        return location
    }


    var tocEntries: [RRSCNTOCEntry] = []


    func finishSection(
        _ type: RRSCNSectionType,
        start: Int
    ) {

        writer.align(8)

        let size = UInt32(writer.data.count - start)

        let entry = RRSCNTOCEntry(
            fourCC: type.fourCC,
            totalSize: size,
            dataOffset: UInt32(start)
        )

        tocEntries.append(entry)
    }



    for section in RRSCNSectionType.allCases {

        let sectionStart = writer.data.count


        switch section {


        case .Vertices:

            writer.write(UInt32(vertices.count))

            writer.writeBytes(vertices)



        case .MaterialDatas:

            writer.write(UInt32(materialDatas.count))

            writer.writeBytes(materialDatas)



        case .RasIndices:

            writer.write(UInt32(indices.count))

            writer.writeBytes(indices)



        case .RTIndices:

            writer.write(UInt32(tlas.reorderedIndices.count))

            writer.writeBytes(
                tlas.reorderedIndices
            )



        case .RTTriMatMap:

            writer.write(UInt32(tlas.triangleMaterialMap.count))

            writer.writeBytes(
                tlas.triangleMaterialMap
            )



        case .SubMeshes:

            var count = 0

            for mesh in meshes {
                count += mesh.subMeshes.count
            }

            writer.write(UInt32(count))


            for mesh in meshes {
                writer.writeBytes(mesh.subMeshes)
            }




        case .Meshes:

            writer.write(UInt32(meshes.count))


            var subMeshOffset: UInt32 = 0


            for mesh in meshes {


                writer.write(mesh.id.uuid)

                writer.write(
                    mesh.parentId?.uuid ?? id.uuid
                )


                reserveString(mesh.name)


                writer.write(subMeshOffset)

                writer.write(
                    UInt32(mesh.subMeshes.count)
                )


                subMeshOffset += UInt32(
                    mesh.subMeshes.count
                )


                writer.write(
                    UInt32(mesh.childrenIds.count)
                )


                for child in mesh.childrenIds {
                    writer.write(child.uuid)
                }


                writer.write(mesh.pivot)
                writer.write(mesh.position)
                writer.write(mesh.rotation)
                writer.write(mesh.scale)

                writer.write(mesh.localMinBounds)
                writer.write(mesh.localMaxBounds)
            }



        case .BLASNodes:

            writer.write(
                UInt32(tlas.blasNodes.count)
            )

            writer.writeBytes(
                tlas.blasNodes
            )



        case .TLASInstances:

            writer.write(
                UInt32(tlas.tlasInstances.count)
            )

            writer.writeBytes(
                tlas.tlasInstances
            )



        case .TLASNodes:

            writer.write(
                UInt32(tlas.tlasNodes.count)
            )

            writer.writeBytes(
                tlas.tlasNodes
            )



        case .MaterialMetas:


            writer.write(
                UInt32(materials.count)
            )


            for material in materials {


                writer.write(material.id.uuid)

                reserveString(material.name)


                // texture indices are patched by TextureLinks
                writer.write(UInt32(0))
                writer.write(UInt32(0))
            }



        case .TextureLinks:

            // Keep deterministic ordering
            let textures = Set(
                materials.flatMap {
                    [
                        $0.diffuseTexturePath?.relativePath ?? "Default",
                        $0.dissolveTexturePath?.relativePath ?? "Default"
                    ]
                }
            )


            writer.write(
                UInt32(textures.count)
            )


            for texture in textures {

                writer.write(UInt16(0))
                writer.write(UInt16(0))

                reserveString(texture)
            }




        case .StringPool:

            //let stringPoolStart = writer.data.count


            // First write count
            writer.write(
                UInt32(pendingStrings.count)
            )


            var offsets: [String:Int] = [:]


            for string in pendingStrings {

                if offsets[string.value] == nil {

                    offsets[string.value] =
                    writer.data.count

                    writer.writeString(
                        string.value
                    )
                }


                let offset = UInt32(
                    offsets[string.value]!
                )


                writer.patch(
                    string.patchLocation,
                    value: offset
                )
            }

        }


        finishSection(
            section,
            start: sectionStart
        )
    }



    // Write TOC

    for (index, entry) in tocEntries.enumerated() {

        writer.patch(
            tocOffset + index * tocEntrySize,
            value: entry
        )
    }



    // Header

    let header = RRSCNHeader(
        magicNumber: UInt32(ascii: "RRSCN"),
        versionNumber: versionNumber,
        fileSize: UInt32(writer.data.count),
        tocOffset: UInt32(tocOffset),
        sectionCount: UInt32(tocEntries.count)
    )


    writer.patch(
        headerOffset,
        value: header
    )



    do {
        try writer.data.write(
            to: savePath,
            options: .atomic
        )
    }
    catch {
        print(error)
    }

}

}

public extension Scene {

func deserializeRRSCN(_ fileName: String?) {

    let url = URL(
        fileURLWithPath:
            (fileName ?? self.name).appending(".rrscn"),
        relativeTo:
            URL(fileURLWithPath: "Saves/")
    )


    let data = try! Data(contentsOf: url)


    var reader = BinaryReader(data: data)


    let header: RRSCNHeader = reader.read()


    guard header.magicNumber == UInt32(ascii: "RRSCN")
    else {
        print("Invalid RRSCN")
        return
    }


    reader.seek(
        Int(header.tocOffset)
    )


    var tocEntries:
        [RRSCNTOCEntry] = []


    for _ in 0..<header.sectionCount {

        tocEntries.append(
            reader.read()
        )
    }



    var subMeshes:
        [SubMesh] = []

    var textureLinks:
        [String] = []


    func sectionReader(
        _ entry: RRSCNTOCEntry
    ) -> BinaryReader {

        var r = BinaryReader(data: data)

        r.seek(
            Int(entry.dataOffset)
        )

        return r
    }




    for entry in tocEntries {


        var r = sectionReader(entry)



        switch entry.fourCC {



        case RRSCNSectionType.Vertices.fourCC:


            let count: UInt32 = r.read()

            vertices =
            r.readArray(
                Int(count)
            )



        case RRSCNSectionType.MaterialDatas.fourCC:


            let count: UInt32 = r.read()

            materialDatas =
            r.readArray(
                Int(count)
            )



        case RRSCNSectionType.RasIndices.fourCC:


            let count: UInt32 = r.read()

            indices =
            r.readArray(
                Int(count)
            )



        case RRSCNSectionType.RTIndices.fourCC:


            let count: UInt32 = r.read()

            tlas.reorderedIndices =
            r.readArray(
                Int(count)
            )



        case RRSCNSectionType.RTTriMatMap.fourCC:


            let count: UInt32 = r.read()

            tlas.triangleMaterialMap =
            r.readArray(
                Int(count)
            )



        case RRSCNSectionType.SubMeshes.fourCC:


            let count: UInt32 = r.read()

            subMeshes =
            r.readArray(
                Int(count)
            )



        case RRSCNSectionType.Meshes.fourCC:


            let count: UInt32 = r.read()


            meshes.removeAll(
                keepingCapacity: true
            )


            for _ in 0..<count {


                let uuid: uuid_t = r.read()

                let parentUUID: uuid_t = r.read()


                let nameOffset: UInt32 = r.read()


                let subMeshOffset: UInt32 = r.read()

                let subMeshCount: UInt32 = r.read()



                let childrenCount: UInt32 = r.read()


                var children:
                    [UUID] = []

                children.reserveCapacity(
                    Int(childrenCount)
                )


                for _ in 0..<childrenCount {

                    let childUUID: uuid_t = r.read()

                    children.append(
                        UUID(uuid: childUUID)
                    )
                }



                let pivot:
                    SIMD3<Float> = r.read()

                let position:
                    SIMD3<Float> = r.read()

                let rotation:
                    SIMD3<Float> = r.read()

                let scale:
                    SIMD3<Float> = r.read()

                let minBounds:
                    SIMD3<Float> = r.read()

                let maxBounds:
                    SIMD3<Float> = r.read()



                // Read string directly from string pool

                var stringReader =
                    BinaryReader(data: data)

                stringReader.seek(
                    Int(nameOffset)
                )

                let name =
                    stringReader.readString()



                let mesh = Mesh(

                    id:
                        UUID(uuid: uuid),

                    name:
                        name,

                    subMeshes:
                        Array(
                            subMeshes[
                                Int(subMeshOffset)
                                ..<
                                Int(subMeshOffset)
                                +
                                Int(subMeshCount)
                            ]
                        ),

                    pivot:
                        pivot,

                    position:
                        position,

                    rotation:
                        rotation,

                    scale:
                        scale,

                    localMinBounds:
                        minBounds,

                    localMaxBounds:
                        maxBounds
                )


                mesh.parentId =
                    UUID(uuid: parentUUID)

                mesh.childrenIds =
                    children


                meshes.append(mesh)
            }




        case RRSCNSectionType.BLASNodes.fourCC:


            let count: UInt32 = r.read()

            tlas.blasNodes =
                r.readArray(
                    Int(count)
                )




        case RRSCNSectionType.TLASInstances.fourCC:


            let count: UInt32 = r.read()

            tlas.tlasInstances =
                r.readArray(
                    Int(count)
                )




        case RRSCNSectionType.TLASNodes.fourCC:


            let count: UInt32 = r.read()

            tlas.tlasNodes =
                r.readArray(
                    Int(count)
                )




        case RRSCNSectionType.MaterialMetas.fourCC:


            let count: UInt32 = r.read()


            materials.removeAll(
                keepingCapacity: true
            )


            for _ in 0..<count {


                let id: uuid_t = r.read()


                let nameOffset: UInt32 = r.read()


                let diffuseIndex:
                    UInt32 = r.read()

                let dissolveIndex:
                    UInt32 = r.read()



                var sr =
                    BinaryReader(data: data)

                sr.seek(
                    Int(nameOffset)
                )


                let materialName =
                    sr.readString()



                let material =
                    Material(
                        id: UUID(uuid: id),
                        name: materialName
                    )


                // assign textures later
                // using TextureLinks


                materials.append(material)
            }




        case RRSCNSectionType.TextureLinks.fourCC:


            let count: UInt32 = r.read()


            textureLinks.removeAll()


            for _ in 0..<count {


                _ = r.read() as UInt16
                _ = r.read() as UInt16


                let offset:
                    UInt32 = r.read()


                var sr =
                    BinaryReader(data: data)

                sr.seek(
                    Int(offset)
                )


                textureLinks.append(
                    sr.readString()
                )
            }




        default:

            print(
                "Unhandled section:",
                entry.fourCC
            )
        }
    }
}

}

public extension UInt32 {
    init(ascii: String) {
        let bytes = Array(ascii.utf8.prefix(4))
        self = bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
}
