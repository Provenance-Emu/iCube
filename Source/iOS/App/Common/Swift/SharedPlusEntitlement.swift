// Same-device recognition only. iCube sells no Plus products and never publishes
// an ownership mirror. This does not change access to any existing free feature.
import Foundation
import Security

enum SharedPlusMirrorReader {
    static let accessGroupSuffix = "com.joemattiello.shared"
    private static let service = "com.joemattiello.shared.entitlements"
    private static let provenancePlusAccount = "provenance.plus"
    private static let iflyProAccount = "ifly.pro"
    private static let activeValue = "active"

    /// v1 mirror payload (see header contract). `expiresAt` nil = lifetime.
    struct Mirror: Codable {
        var v: Int = 1
        var period: String? // "monthly" | "yearly" | "lifetime"
        var status: String // "active" | "grace" | "expired"
        var expiresAt: Date?
        var updatedAt: Date = .init()
    }

    /// Slack past `expiresAt` before a subscription mirror stops counting —
    /// covers the renewal window when the selling app hasn't re-mirrored yet.
    private static let renewalGrace: TimeInterval = 7 * 24 * 60 * 60

    /// The decoded Provenance Plus mirror, if any (legacy "active" string is
    /// upgraded to an active/lifetime mirror for pre-v1 Provenance builds).
    static func decode(_ raw: String) -> Mirror? {
        if raw == activeValue { return Mirror(period: "lifetime", status: "active", expiresAt: nil) }
        guard let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Mirror.self, from: data)
    }

    /// Does Provenance Plus currently grant Pro here? Status-aware: the mirror
    /// must say active/grace AND (for subscriptions) be within expiry + grace —
    /// enforced HERE so a stale mirror decays even if Provenance never runs
    /// again (uninstalled, or lapsed while iFly is the only app in use).
    static var activeSources: [String] {
        [(provenancePlusAccount, "Provenance"), (iflyProAccount, "iFly")].compactMap { account, name in
            guard let raw = read(account: account), let mirror = decode(raw), grants(mirror, now: Date()) else { return nil }
            return name
        }
    }

    /// Validate subscription and lifetime shapes separately; an incomplete subscription
    /// must never accidentally become an unlimited lifetime purchase.
    static func grants(_ mirror: Mirror, now: Date) -> Bool {
        guard mirror.v == 1, mirror.status == "active" || mirror.status == "grace" else { return false }
        switch mirror.period {
        case "lifetime": return mirror.expiresAt == nil
        case "monthly", "yearly":
            guard let expiry = mirror.expiresAt else { return false }
            return now < expiry.addingTimeInterval(renewalGrace)
        default: return false
        }
    }

    // MARK: - Keychain plumbing

    /// The shared group needs the team-ID prefix, which isn't in Info.plist.
    /// Standard trick: add (or find) a probe item with no explicit group —
    /// it lands in the app's default group "<TEAMID>.<bundle id>" — and read
    /// the prefix off its `kSecAttrAccessGroup`.
    private static let teamPrefix: String? = {
        let probeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.joemattiello.icube.team-probe",
            kSecAttrAccount as String: "probe",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(probeQuery as CFDictionary, &result)
        if status == errSecItemNotFound {
            var addQuery = probeQuery
            addQuery.removeValue(forKey: kSecReturnAttributes as String)
            addQuery.removeValue(forKey: kSecMatchLimit as String)
            addQuery[kSecValueData as String] = Data("probe".utf8)
            addQuery[kSecReturnAttributes as String] = true
            status = SecItemAdd(addQuery as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".") else { return nil }
        return String(group[..<dot])
    }()

    private static var sharedGroup: String? {
        teamPrefix.map { "\($0).\(accessGroupSuffix)" }
    }

    private static func read(account: String) -> String? {
        guard let group = sharedGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

}

@MainActor
final class SharedPlusEntitlement {
    static let shared = SharedPlusEntitlement()
    private var observation: NSObjectProtocol?
    private var refreshTimer: Timer?
    private init() {}

    /// Read at the decision boundary so expiry never relies on a launch latch.
    var hasPurchased: Bool { !SharedPlusMirrorReader.activeSources.isEmpty }

    var statusText: String {
        let sources = SharedPlusMirrorReader.activeSources
        return sources.isEmpty ? "Plus membership is not recognized on this device" : "Plus recognized via " + sources.joined(separator: " and ")
    }

    nonisolated static let restoreGuidance = "To restore a purchase, open Provenance or iFly on this device and use Restore Purchases, then return here. Recognition currently works between supported apps on the same device. iCube remains free."

    func start() {
        guard observation == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            NotificationCenter.default.post(name: .sharedPlusEntitlementDidChange, object: nil)
        }
        observation = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UIApplicationDidBecomeActiveNotification"),
            object: nil, queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .sharedPlusEntitlementDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let sharedPlusEntitlementDidChange = Notification.Name("SharedPlusEntitlementDidChange")
}
