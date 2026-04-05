import Foundation
import Combine

enum ColorTheme: String, Codable, CaseIterable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Ping targets
    @Published var pingTargets: [PingTarget] {
        didSet { encode(pingTargets, forKey: "pingTargets") }
    }

    // MARK: - Thresholds
    @Published var thresholds: Thresholds {
        didSet { encode(thresholds, forKey: "thresholds") }
    }

    // MARK: - General
    @Published var alwaysShowBarChart: Bool {
        didSet { UserDefaults.standard.set(alwaysShowBarChart, forKey: "alwaysShowBarChart") }
    }

    @Published var colorTheme: ColorTheme {
        didSet { UserDefaults.standard.set(colorTheme.rawValue, forKey: "colorTheme") }
    }

    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    @Published var pollIntervalSecs: Double {
        didSet { UserDefaults.standard.set(pollIntervalSecs, forKey: "pollIntervalSecs") }
    }

    @Published var showLatencyInMenubar: Bool {
        didSet { UserDefaults.standard.set(showLatencyInMenubar, forKey: "showLatencyInMenubar") }
    }

    @Published var bandwidthScheduleHours: Double {
        didSet { UserDefaults.standard.set(bandwidthScheduleHours, forKey: "bandwidthScheduleHours") }
    }

    @Published var enableLogRotation: Bool {
        didSet { UserDefaults.standard.set(enableLogRotation, forKey: "enableLogRotation") }
    }

    @Published var bandwidthBarRedMbps: Double {
        didSet { UserDefaults.standard.set(bandwidthBarRedMbps, forKey: "bandwidthBarRedMbps") }
    }

    @Published var bandwidthBarYellowMbps: Double {
        didSet { UserDefaults.standard.set(bandwidthBarYellowMbps, forKey: "bandwidthBarYellowMbps") }
    }

    private init() {
        let ud = UserDefaults.standard

        pingTargets = (try? ud.decoded([PingTarget].self, forKey: "pingTargets")) ?? PingTarget.defaults
        thresholds  = (try? ud.decoded(Thresholds.self, forKey: "thresholds")) ?? .default

        alwaysShowBarChart     = ud.bool(forKey: "alwaysShowBarChart")
        colorTheme             = ColorTheme(rawValue: ud.string(forKey: "colorTheme") ?? "") ?? .system
        launchAtLogin          = ud.bool(forKey: "launchAtLogin")
        pollIntervalSecs       = ud.double(forKey: "pollIntervalSecs").nonZero ?? 5
        showLatencyInMenubar   = ud.bool(forKey: "showLatencyInMenubar")
        bandwidthScheduleHours = ud.double(forKey: "bandwidthScheduleHours")
        enableLogRotation      = ud.bool(forKey: "enableLogRotation")
        bandwidthBarRedMbps    = ud.double(forKey: "bandwidthBarRedMbps").nonZero ?? 10
        bandwidthBarYellowMbps = ud.double(forKey: "bandwidthBarYellowMbps").nonZero ?? 25
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? _sharedEncoder.encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// Shared codec instances — JSONEncoder/Decoder are expensive to allocate (~0.1ms each).
// Settings are @MainActor so no concurrent access is possible.
private let _sharedEncoder = JSONEncoder()
private let _sharedDecoder = JSONDecoder()

// MARK: - UserDefaults helpers
private extension UserDefaults {
    func decoded<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T {
        guard let data = data(forKey: key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No data for key \(key)"))
        }
        return try _sharedDecoder.decode(type, from: data)
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
