import AppKit
import Combine

/// Publishes a value whenever the system effective appearance changes (light ↔ dark).
@MainActor
public final class AppearanceObserver: NSObject {
    public static let shared = AppearanceObserver()

    /// Fires with the new effective appearance name when it changes.
    public let appearanceChanged = PassthroughSubject<NSAppearance.Name, Never>()

    private var observation: NSKeyValueObservation?

    override public init() {
        super.init()
        // KVO handler is on main thread (observation created on @MainActor init),
        // so no DispatchQueue.main.async needed — eliminates the Sendable warning.
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let newAppearance = change.newValue else { return }
            let name = newAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
            self?.appearanceChanged.send(name)
        }
    }

    public var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
