public struct RecordingCountdown: Sendable {
    public static let limit: Duration = .seconds(120)
    public static let warningThreshold = limit / 10

    public struct Reading: Equatable, Sendable {
        public let seconds: Int
        public let isWarning: Bool

        public init(seconds: Int, isWarning: Bool) {
            self.seconds = seconds
            self.isWarning = isWarning
        }
    }

    public let deadline: ContinuousClock.Instant

    public init(startedAt: ContinuousClock.Instant = .now) {
        deadline = startedAt.advanced(by: Self.limit)
    }

    public func reading(at now: ContinuousClock.Instant = .now) -> Reading {
        let remaining = min(Self.limit, max(.zero, now.duration(to: deadline)))
        let (seconds, fraction) = remaining.components
        return Reading(seconds: Int(seconds) + (fraction > 0 ? 1 : 0), isWarning: remaining < Self.warningThreshold)
    }
}
