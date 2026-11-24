public extension Duration {
    var seconds: Double {
        let (whole, fraction) = components
        return Double(whole) + Double(fraction) / 1e18
    }
}
