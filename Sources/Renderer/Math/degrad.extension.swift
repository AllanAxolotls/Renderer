extension BinaryFloatingPoint {
    @inlinable
    var radians: Self {
        return self * .pi / 180
    }
    
    @inlinable
    var degrees: Self {
        return self * 180 / .pi
    }
}