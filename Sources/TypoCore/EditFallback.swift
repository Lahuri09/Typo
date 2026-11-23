public enum EditFallback {
    public static func resolve(original: String, prepared: String, preset: EditPreset) -> String? {
        guard prepared != original, preset.accepts(prepared, replacing: original) else { return nil }
        return prepared
    }
}
