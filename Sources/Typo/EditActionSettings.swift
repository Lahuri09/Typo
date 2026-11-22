import SwiftUI
import TypoCore

struct EditActionSettings: View {
    let catalog: EditActionCatalog
    @State private var draft: Draft?
    @State private var dropTarget: EditAction.ID?

    private struct Draft: Identifiable {
        var action: EditAction? = nil
        var id: String { action?.id ?? "new" }
    }

    var body: some View {
        Section("Стили редактуры") {
            ForEach(Array(catalog.actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 9) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                        .draggable("typo-edit-style:" + action.id)
                        .help("Перетащить для изменения порядка")
                        .accessibilityHidden(true)

                    Toggle(isOn: Binding(get: { action.isEnabled }, set: { catalog.setEnabled($0, id: action.id) })) {
                        Label(action.name, systemImage: action.icon)
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)

                    Spacer(minLength: 8)

                    Menu {
                        if action.preset == .custom {
                            Button("Изменить…") { draft = Draft(action: action) }
                        }
                        Button("Переместить выше", systemImage: "arrow.up") { move(action, by: -1) }
                            .disabled(index == 0)
                        Button("Переместить ниже", systemImage: "arrow.down") { move(action, by: 1) }
                            .disabled(index == catalog.actions.count - 1)
                        if action.preset == .custom {
                            Divider()
                            Button("Удалить стиль", systemImage: "trash", role: .destructive) {
                                catalog.removeCustom(id: action.id)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Действия для стиля «\(action.name)»")
                }
                .background(dropTarget == action.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, item.hasPrefix("typo-edit-style:") else { return false }
                    return catalog.move(id: String(item.dropFirst("typo-edit-style:".count)), to: action.id)
                } isTargeted: { targeted in
                    if targeted { dropTarget = action.id }
                    else if dropTarget == action.id { dropTarget = nil }
                }
            }

            Button("Добавить стиль…", systemImage: "plus") { draft = Draft() }
        }
        .sheet(item: $draft) { draft in
            EditActionEditor(catalog: catalog, action: draft.action)
        }
    }

    private func move(_ action: EditAction, by offset: Int) {
        guard let from = catalog.actions.firstIndex(where: { $0.id == action.id }),
              catalog.actions.indices.contains(from + offset) else { return }
        catalog.move(id: action.id, to: catalog.actions[from + offset].id)
    }
}

private struct EditActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let catalog: EditActionCatalog
    let action: EditAction?
    @State private var name: String
    @State private var icon: String
    @State private var prompt: String

    private static let icons: [(symbol: String, title: String)] = [
        ("slider.horizontal.3", "Настройка"), ("sparkles", "Искры"), ("star", "Звезда"),
        ("pencil", "Карандаш"), ("text.quote", "Цитата"), ("text.alignleft", "Текст"),
        ("list.bullet", "Список"), ("checkmark.seal", "Проверка"), ("bubble.left", "Диалог"),
        ("envelope", "Письмо"), ("briefcase", "Работа"), ("translate", "Перевод")
    ]

    init(catalog: EditActionCatalog, action: EditAction?) {
        self.catalog = catalog
        self.action = action
        _name = State(initialValue: action?.name ?? "")
        _icon = State(initialValue: action?.icon ?? EditPreset.custom.icon)
        _prompt = State(initialValue: action?.prompt ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action == nil ? "Новый стиль" : "Изменить стиль")
                .font(.headline)
            TextField("Название", text: $name)
            Picker("Иконка", selection: $icon) {
                ForEach(Self.icons, id: \.symbol) { item in
                    Label(item.title, systemImage: item.symbol).tag(item.symbol)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Инструкция для модели")
                TextEditor(text: $prompt)
                    .font(.body)
                    .padding(4)
                    .frame(height: 100)
                    .border(.quaternary)
                    .accessibilityLabel("Инструкция для модели")
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    if catalog.saveCustom(id: action?.id, name: name, icon: icon, prompt: prompt) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 375)
        .padding(22)
    }
}
