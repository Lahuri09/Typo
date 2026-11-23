import AppKit
import SwiftUI
import TypoCore

enum PanelTheme: String, CaseIterable {
    case amber, neutral, blue, violet, mint, rose, coral, lime, black, white, custom

    var title: String {
        switch self {
        case .amber: "Янтарный"
        case .neutral: "Нейтральный"
        case .blue: "Голубой"
        case .violet: "Лиловый"
        case .mint: "Мятный"
        case .rose: "Розовый"
        case .coral: "Коралловый"
        case .lime: "Лаймовый"
        case .black: "Чёрный"
        case .white: "Белый"
        case .custom: "Свой цвет"
        }
    }

    private var accent: Color {
        switch self {
        case .amber: Color(red: 1, green: 0.76, blue: 0.55)
        case .neutral: Color(red: 0.88, green: 0.90, blue: 0.93)
        case .blue: Color(red: 0.60, green: 0.84, blue: 1)
        case .violet: Color(red: 0.85, green: 0.75, blue: 1)
        case .mint: Color(red: 0.55, green: 0.95, blue: 0.76)
        case .rose: Color(red: 1, green: 0.63, blue: 0.73)
        case .coral: Color(red: 1, green: 0.59, blue: 0.49)
        case .lime: Color(red: 0.81, green: 0.91, blue: 0.48)
        case .black, .custom: Color(white: 0.92)
        case .white: Color(white: 0.15)
        }
    }

    private var backdrop: Color {
        switch self {
        case .amber: Color(red: 0.15, green: 0.084, blue: 0.045)
        case .neutral: Color(red: 0.085, green: 0.092, blue: 0.105)
        case .blue: Color(red: 0.039, green: 0.094, blue: 0.17)
        case .violet: Color(red: 0.113, green: 0.064, blue: 0.17)
        case .mint: Color(red: 0.037, green: 0.14, blue: 0.106)
        case .rose: Color(red: 0.17, green: 0.054, blue: 0.091)
        case .coral: Color(red: 0.18, green: 0.052, blue: 0.044)
        case .lime: Color(red: 0.105, green: 0.132, blue: 0.034)
        case .black, .custom: Color(white: 0.025)
        case .white: Color(white: 0.98)
        }
    }

    func palette(custom: NSColor = .black) -> PanelPalette {
        if self == .custom {
            let color = custom.usingColorSpace(.sRGB) ?? .black
            let luminance = 0.2126 * Self.linear(color.redComponent) + 0.7152 * Self.linear(color.greenComponent)
                + 0.0722 * Self.linear(color.blueComponent)
            let ink: Color = luminance > 0.179 ? .black : .white
            let backdrop = Color(nsColor: color)
            return PanelPalette(accent: ink, backdrop: backdrop, ink: ink, swatch: backdrop, isSolid: true,
                                usesLightSurface: luminance > 0.179)
        }
        let monochrome = self == .black || self == .white
        return PanelPalette(accent: accent, backdrop: backdrop, ink: self == .white ? .black : .white,
                            swatch: monochrome ? backdrop : accent, isSolid: monochrome, usesLightSurface: self == .white)
    }

    private static func linear(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

struct PanelPalette {
    let accent: Color
    let backdrop: Color
    let ink: Color
    let swatch: Color
    let isSolid: Bool
    let usesLightSurface: Bool
}

enum FloatingVisibility: String, CaseIterable, Identifiable {
    case hidden, always, inText

    var id: Self { self }

    var title: String {
        switch self {
        case .hidden: "Скрыта"
        case .always: "Всегда"
        case .inText: "В текстовом поле"
        }
    }
}

enum PanelSize: String, CaseIterable {
    case compact, regular, large

    var title: String {
        switch self {
        case .compact: "Маленький"
        case .regular: "Обычный"
        case .large: "Большой"
        }
    }

    var scale: CGFloat {
        switch self {
        case .compact: 0.88
        case .regular: 1
        case .large: 1.16
        }
    }
}

enum PanelPlacement: String, CaseIterable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    var title: String {
        switch self {
        case .topLeft: "Сверху слева"
        case .topCenter: "Сверху по центру"
        case .topRight: "Сверху справа"
        case .bottomLeft: "Снизу слева"
        case .bottomCenter: "Снизу по центру"
        case .bottomRight: "Снизу справа"
        }
    }

    var position: PanelPosition {
        switch self {
        case .topLeft: PanelPosition(horizontal: 0, vertical: 0)
        case .topCenter: PanelPosition(horizontal: 0.5, vertical: 0)
        case .topRight: PanelPosition(horizontal: 1, vertical: 0)
        case .bottomLeft: PanelPosition(horizontal: 0, vertical: 1)
        case .bottomCenter: PanelPosition(horizontal: 0.5, vertical: 1)
        case .bottomRight: PanelPosition(horizontal: 1, vertical: 1)
        }
    }
}

@Observable
final class PanelAppearance {
    private let defaults: UserDefaults

    var theme: PanelTheme {
        didSet { defaults.set(theme.rawValue, forKey: "panelTheme") }
    }
    private var customColor: NSColor
    var palette: PanelPalette { theme.palette(custom: customColor) }
    var colorSelection: Color {
        get { Color(nsColor: customColor) }
        set {
            guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { min(max($0, 0), 1) }
            customColor = NSColor(srgbRed: channels[0], green: channels[1], blue: channels[2], alpha: 1)
            defaults.set(channels.map(Double.init), forKey: "customPanelColor")
            theme = .custom
        }
    }
    var size: PanelSize {
        didSet { defaults.set(size.rawValue, forKey: "panelSize") }
    }
    var usesGradient: Bool {
        didSet { defaults.set(usesGradient, forKey: "panelGradient") }
    }
    var restingOpacity: Double {
        didSet { defaults.set(restingOpacity, forKey: "floatingPanelOpacity") }
    }
    var hudPosition: PanelPosition {
        didSet { Self.save(hudPosition, to: defaults, key: "hudPosition") }
    }
    var floatingVisibility: FloatingVisibility {
        didSet {
            defaults.set(floatingVisibility.rawValue, forKey: "floatingVisibility")
            if isPlacingControls { isPlacingControls = false }
        }
    }
    private(set) var hasTextContext = false
    var isPlacingControls = false

    func setTextContext(_ focused: Bool) {
        if hasTextContext != focused { hasTextContext = focused }
    }
    var controlsPosition: PanelPosition {
        didSet { Self.save(controlsPosition, to: defaults, key: "floatingControlsPosition") }
    }
    var floatingFrames: [CGDirectDisplayID: CGRect] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: "panelTheme").flatMap(PanelTheme.init(rawValue:)) ?? .amber
        if let channels = defaults.array(forKey: "customPanelColor") as? [Double], channels.count == 3,
           channels.allSatisfy({ (0...1).contains($0) }) {
            customColor = NSColor(srgbRed: channels[0], green: channels[1], blue: channels[2], alpha: 1)
        } else {
            customColor = NSColor(srgbRed: 0.16, green: 0.25, blue: 0.32, alpha: 1)
        }
        size = defaults.string(forKey: "panelSize").flatMap(PanelSize.init(rawValue:)) ?? .regular
        usesGradient = defaults.object(forKey: "panelGradient") as? Bool ?? true
        let opacity = defaults.object(forKey: "floatingPanelOpacity") as? Double ?? 0.70
        restingOpacity = opacity.isFinite ? min(max(opacity, 0.25), 1) : 0.70
        hudPosition = Self.position(in: defaults, key: "hudPosition", legacyKey: "hudPlacement", fallback: .topCenter)
        floatingVisibility = defaults.string(forKey: "floatingVisibility").flatMap(FloatingVisibility.init(rawValue:))
            ?? (defaults.bool(forKey: "showsFloatingControls") ? .always : .hidden)
        controlsPosition = Self.position(in: defaults, key: "floatingControlsPosition",
                                         legacyKey: "floatingControlsPlacement", fallback: .bottomRight)
    }

    private static func position(in defaults: UserDefaults, key: String, legacyKey: String,
                                 fallback: PanelPlacement) -> PanelPosition {
        if let coordinates = defaults.array(forKey: key) as? [Double], coordinates.count == 2,
           coordinates.allSatisfy(\.isFinite) {
            return PanelPosition(horizontal: CGFloat(coordinates[0]), vertical: CGFloat(coordinates[1]))
        }
        return (defaults.string(forKey: legacyKey).flatMap(PanelPlacement.init(rawValue:)) ?? fallback).position
    }

    private static func save(_ position: PanelPosition, to defaults: UserDefaults, key: String) {
        defaults.set([Double(position.horizontal), Double(position.vertical)], forKey: key)
    }
}
