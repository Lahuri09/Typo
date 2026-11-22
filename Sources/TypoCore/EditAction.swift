import Foundation
import Observation

extension EditPreset: Codable {}

public struct EditAction: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let preset: EditPreset
    public fileprivate(set) var isEnabled: Bool
    public let prompt: String
    fileprivate let customName: String?
    fileprivate let customIcon: String?

    public var name: String { customName ?? preset.title }
    public var icon: String { customIcon ?? preset.icon }
    public var subtitle: String { preset == .custom ? prompt : preset.subtitle }
}

@MainActor @Observable
public final class EditActionCatalog {
    private static let key = "editActionCatalog"
    private let defaults: UserDefaults
    public private(set) var actions: [EditAction] {
        didSet { Self.store(actions, in: defaults) }
    }

    public var enabledActions: [EditAction] { actions.filter(\.isEnabled) }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([EditAction].self, from: stored) {
            actions = saved
            return
        }

        let legacy = defaults.string(forKey: "rewriteInstruction")
            ?? "Исправь орфографию, грамматику и пунктуацию. Сохрани смысл и тон."
        let prompt = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        actions = (EditPreset.chooserActions + [.punctuation, .spelling]).compactMap { preset in
            if preset == .custom, prompt.isEmpty { return nil }
            return EditAction(id: preset.rawValue, preset: preset,
                              isEnabled: EditPreset.chooserActions.contains(preset),
                              prompt: preset == .custom ? prompt : "", customName: nil, customIcon: nil)
        }
        Self.store(actions, in: defaults)
    }

    public func setEnabled(_ enabled: Bool, id: EditAction.ID) {
        guard let index = actions.firstIndex(where: { $0.id == id }), actions[index].isEnabled != enabled else { return }
        actions[index].isEnabled = enabled
    }

    @discardableResult
    public func move(id: EditAction.ID, to destination: EditAction.ID) -> Bool {
        guard id != destination, let from = actions.firstIndex(where: { $0.id == id }),
              let to = actions.firstIndex(where: { $0.id == destination }) else { return false }
        var reordered = actions
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: to)
        actions = reordered
        return true
    }

    @discardableResult
    public func saveCustom(id: EditAction.ID? = nil, name: String, icon: String, prompt: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !icon.isEmpty, !prompt.isEmpty else { return false }
        if let id {
            guard let index = actions.firstIndex(where: { $0.id == id && $0.preset == .custom }) else { return false }
            actions[index] = EditAction(id: id, preset: .custom, isEnabled: actions[index].isEnabled,
                                        prompt: prompt, customName: name, customIcon: icon)
        } else {
            actions.append(EditAction(id: UUID().uuidString, preset: .custom, isEnabled: true,
                                      prompt: prompt, customName: name, customIcon: icon))
        }
        return true
    }

    public func removeCustom(id: EditAction.ID) {
        guard let index = actions.firstIndex(where: { $0.id == id && $0.preset == .custom }) else { return }
        actions.remove(at: index)
    }

    private static func store(_ actions: [EditAction], in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(actions) { defaults.set(data, forKey: key) }
    }
}
