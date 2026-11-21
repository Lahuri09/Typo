public struct Shortcut: Codable, Equatable, Sendable {
    public let key: UInt16
    public let modifiers: UInt64
    public let double: Bool

    public init(key: UInt16, modifiers: UInt64, double: Bool = false) {
        self.key = key
        self.modifiers = modifiers
        self.double = double
    }
}

public struct HotkeyMatcher {
    private var pending: (Shortcut, Double)?
    private var held: UInt16?

    public init() {}

    public mutating func press(_ shortcut: Shortcut, at time: Double) -> Bool {
        guard held != shortcut.key else { return false }
        held = shortcut.key
        guard shortcut.double else {
            pending = nil
            return true
        }
        if let (previous, start) = pending, previous == shortcut, (0...0.35).contains(time - start) {
            pending = nil
            return true
        }
        pending = (shortcut, time)
        return false
    }

    public mutating func release(_ key: UInt16) {
        if held == key { held = nil }
    }

    public mutating func reset() {
        pending = nil
        held = nil
    }
}
