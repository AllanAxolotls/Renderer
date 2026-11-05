import Metal

struct MaterialFlags : OptionSet, Sendable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    
    static let isSky = MaterialFlags(rawValue: 1 << 0)
}

struct BaseMaterial {
    var diffuseColor = Color4(1, 1, 1, 1)
    var emissionColor = Color4(0, 0, 0, 1)
    var roughness: Float = 1.0
    var metallic: Float = 0.0
    var refractiveIndex: Float = 1.0
    var flags = MaterialFlags(rawValue: 0)
    var diffuseTextureIndex: UInt16 = 0
    var dissolveTextureIndex: Int16 = -1

    var isSky: Bool {
        get { flags.contains(.isSky) }
        set { if newValue { flags.insert(.isSky) } else { flags.remove(.isSky) } }
    }

    static func == (lhs: BaseMaterial, rhs: BaseMaterial) -> Bool {
        return (lhs.diffuseColor == rhs.diffuseColor) &&
            (lhs.emissionColor == rhs.emissionColor) &&
            (lhs.roughness == rhs.roughness) &&
            (lhs.metallic == rhs.metallic) &&
            (lhs.refractiveIndex == rhs.refractiveIndex) &&
            (lhs.flags == rhs.flags) &&
            // TODO:? I'm not too sure about these
            (lhs.diffuseTextureIndex == rhs.diffuseTextureIndex) &&
            (lhs.dissolveTextureIndex == rhs.dissolveTextureIndex)
    }

    static var diffuseTextureIndexOffset: Int {
        MemoryLayout<BaseMaterial>.offset(of: \.diffuseTextureIndex)!
    }
    
    static var dissolveTextureIndexOffset: Int {
        MemoryLayout<BaseMaterial>.offset(of: \.dissolveTextureIndex)!
    }
}