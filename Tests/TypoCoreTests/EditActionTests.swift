import Foundation
import TypoCore

@MainActor func runEditActionChecks(_ expect: (Bool) -> Void) {
    let suite = "EditActionTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("Структурируй текст по абзацам.", forKey: "rewriteInstruction")

    let catalog = EditActionCatalog(defaults: defaults)
    expect(catalog.enabledActions.map(\.preset) == [.proofread, .concise, .business, .conversational, .custom])
    let migrated = catalog.enabledActions.last!
    expect(migrated.prompt == "Структурируй текст по абзацам.")
    expect(!catalog.saveCustom(name: " ", icon: "star", prompt: "Текст"))
    expect(catalog.saveCustom(name: " Письмо ", icon: "envelope", prompt: " Добавь обращение. "))
    let added = catalog.enabledActions.last!
    expect(catalog.saveCustom(id: added.id, name: "Ответ", icon: "bubble.left", prompt: "Поблагодари."))
    catalog.setEnabled(false, id: "proofread")
    expect(catalog.move(id: added.id, to: "concise"))
    catalog.removeCustom(id: migrated.id)
    catalog.removeCustom(id: "concise")

    let reopened = EditActionCatalog(defaults: defaults)
    expect(reopened.enabledActions.map(\.name) == ["Ответ", "Сократить", "Деловой тон", "Разговорный тон"])
    expect(reopened.enabledActions.first?.id == added.id)
    expect(reopened.enabledActions.first?.icon == "bubble.left")
    expect(reopened.enabledActions.first?.prompt == "Поблагодари.")
    for action in reopened.enabledActions { reopened.setEnabled(false, id: action.id) }
    expect(EditActionCatalog(defaults: defaults).enabledActions.isEmpty)
}
