import SwiftUI

struct PermissionCards: View {
    let engine: InputEngine
    var isNeeded: Bool { !engine.running || !engine.ai.hasMicrophoneAccess }

    var body: some View {
        if isNeeded {
            HStack(alignment: .top, spacing: 8) {
                card("Микрофон", icon: "mic", granted: engine.ai.hasMicrophoneAccess,
                     accessibilityAction: "Выдать доступ к микрофону", action: engine.ai.requestMicrophoneAccess)
                card("Универсальный доступ", icon: "accessibility", granted: engine.running,
                     missingStatus: engine.trusted ? "Нужен мониторинг ввода" : "Нужен доступ",
                     accessibilityAction: "Выдать универсальный доступ", action: engine.requestAccess)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Разрешения")
        }
    }

    private func card(_ title: String, icon: String, granted: Bool, missingStatus: String = "Нужен доступ",
                      accessibilityAction: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if granted {
                Label("Доступ есть", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(missingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Выдать доступ", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(accessibilityAction)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
        .padding(9)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.primary.opacity(0.13))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}
