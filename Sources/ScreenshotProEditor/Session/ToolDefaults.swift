import Foundation
import ScreenshotProCore

/// Remembered last-used element properties per element type (02 section 2.12). New elements
/// start with these instead of the defaults. Kept in memory and in UserDefaults under the
/// editor's own key.
@MainActor
final class ToolDefaults {
    static let shared = ToolDefaults()
    static let defaultsKey = "ScreenshotPro.editor.lastStyles.v2"

    private let defaults: UserDefaults?
    private var remembered: [ElementType: ElementStyle] = [:]

    /// Pass nil to keep values only in memory (tests).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: ToolDefaults.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ElementStyle].self, from: data) {
            for (k, v) in decoded {
                if let type = ElementType(rawValue: k) { remembered[type] = v }
            }
        }
    }

    /// Style for a new element of `type`: remembered values, else the settings-based defaults.
    func style(for type: ElementType, settings: ScreenshotProSettings) -> ElementStyle {
        remembered[type] ?? ElementStyle.defaults(for: type, settings: settings)
    }

    /// Applies a property change to the remembered style of `type`.
    func remember(_ type: ElementType, settings: ScreenshotProSettings, change: (inout ElementStyle) -> Void) {
        var s = style(for: type, settings: settings)
        change(&s)
        remembered[type] = s
        save()
    }

    func forgetAll() {
        remembered.removeAll()
        save()
    }

    private func save() {
        guard let defaults else { return }
        let dict = Dictionary(uniqueKeysWithValues: remembered.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: ToolDefaults.defaultsKey) }
    }
}

/// Persisted settings of the effects that have parameter sheets.
@MainActor
enum EffectDefaults {
    private static let dropShadowKey = "ScreenshotPro.editor.dropShadow.v1"
    private static let tornEdgesKey = "ScreenshotPro.editor.tornEdges.v1"

    static var dropShadow: DropShadowSettings {
        get { load(dropShadowKey) ?? DropShadowSettings() }
        set { store(newValue, dropShadowKey) }
    }

    static var tornEdges: TornEdgeSettings {
        get { load(tornEdgesKey) ?? TornEdgeSettings() }
        set { store(newValue, tornEdgesKey) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
