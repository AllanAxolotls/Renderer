import simd

struct Color4 : ExpressibleByArrayLiteral {
    var rawValue = simd_float4(0, 0, 0, 1)

    var r: Float { get { return rawValue.x } set { rawValue.x = newValue } }
    var g: Float { get { return rawValue.y } set { rawValue.y = newValue } }
    var b: Float { get { return rawValue.z } set { rawValue.z = newValue } }
    var a: Float { get { return rawValue.w } set { rawValue.w = newValue } }

    var rgb: simd_float3 { return simd_float3(r, g, b) }

    init(_ r: Float = 0, _ g: Float = 0, _ b: Float = 0, _ a: Float = 1) {
        rawValue.x = r
        rawValue.y = g
        rawValue.z = b
        rawValue.w = a
    }

    init(arrayLiteral elements: Float...) {
        self.r = elements.indices.contains(0) ? elements[0] : 0.0
        self.g = elements.indices.contains(1) ? elements[1] : 0.0
        self.b = elements.indices.contains(2) ? elements[2] : 0.0
        self.a = elements.indices.contains(3) ? elements[3] : 1.0
    }

    static func == (lhs: Color4, rhs: Color4) -> Bool {
        return (lhs.r == rhs.r) && (lhs.g == rhs.g) && (lhs.b == rhs.b) && (lhs.a == rhs.a)
    }
}

struct Rgba8 : ExpressibleByArrayLiteral {
     var rawValue = simd_uchar4(0, 0, 0, 255)

    var r: UInt8 { get { return rawValue.x } set { rawValue.x = newValue } }
    var g: UInt8 { get { return rawValue.y } set { rawValue.y = newValue } }
    var b: UInt8 { get { return rawValue.z } set { rawValue.z = newValue } }
    var a: UInt8 { get { return rawValue.w } set { rawValue.w = newValue } }

    init(_ r: UInt8 = 0, _ g: UInt8 = 0, _ b: UInt8 = 0, _ a: UInt8 = 255) {
        rawValue.x = r
        rawValue.y = g
        rawValue.z = b
        rawValue.w = a
    }

    init(arrayLiteral elements: UInt8...) {
        self.r = elements.indices.contains(0) ? elements[0] : 0
        self.g = elements.indices.contains(1) ? elements[1] : 0
        self.b = elements.indices.contains(2) ? elements[2] : 0
        self.a = elements.indices.contains(3) ? elements[3] : 255
    }

    init(_ rgb: simd_float3 = [0, 0, 0], a: Float = 1.0) {
        self.r = UInt8(rgb.x * 255)
        self.g = UInt8(rgb.y * 255)
        self.b = UInt8(rgb.z * 255)
        self.a = UInt8(a * 255)
    }

    static func == (lhs: Rgba8, rhs: Rgba8) -> Bool {
        return (lhs.r == rhs.r) && (lhs.g == rhs.g) && (lhs.b == rhs.b) && (lhs.a == rhs.a)
    }
}