/// Shared Hyper-mode remaps for navigation keys.
enum HyperNavigationMapping {
    private static let virtualKeyMap: [Int64: UInt16] = [
        0x04: 0x7B, // h -> left arrow
        0x26: 0x7D, // j -> down arrow
        0x28: 0x7E, // k -> up arrow
        0x25: 0x7C, // l -> right arrow
    ]

    static func arrowKeyCode(forVirtualKeyCode keyCode: Int64) -> UInt16? {
        guard hyperNavigationEnabled else { return nil }
        return virtualKeyMap[keyCode]
    }
}
