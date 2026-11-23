import Foundation
import Observation

public enum DictationFallback: String, CaseIterable, Sendable {
    case history, clipboard, disabled

    public var title: String {
        switch self {
        case .history: "Сохранить в истории"
        case .clipboard: "Скопировать в буфер"
        case .disabled: "Требовать текстовое поле"
        }
    }
}

public struct DictationEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
}

@MainActor @Observable
public final class DictationHistory {
    public static let limit = 30
    private static let key = "standaloneDictationHistory"
    private let defaults: UserDefaults
    public private(set) var entries: [DictationEntry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([DictationEntry].self, from: $0) }
        entries = Array((saved ?? []).prefix(Self.limit))
    }

    public func add(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(DictationEntry(id: UUID(), date: .now, text: text), at: 0)
        if entries.count > Self.limit { entries.removeLast() }
        save()
    }

    public func remove(_ id: DictationEntry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(entries) { defaults.set(encoded, forKey: Self.key) }
    }
}
