import Foundation

public struct AccessibilityRetryPolicy: Sendable {
    public let delays: [Int]

    public var totalDelay: Duration {
        .milliseconds(delays.reduce(0, +))
    }

    public static let textPublication = Self(delays: [
        12, 16, 20, 24, 28, 32, 36, 40, 44, 48
    ])

    public static let selectionPublication = Self(delays: [
        12, 18, 24, 30, 36, 42
    ])
}
