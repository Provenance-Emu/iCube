// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity

/// Custody of this device's long-term pairing key.
///
/// The key lives in the **Keychain**, not in the User directory, for one
/// specific reason: the User directory is what the WebDAV/HTTP upload server
/// serves and what a future sync feature would copy off-device. A private
/// signing key sitting there would be one mis-scoped enumeration away from
/// leaving the device — and unlike a save file, a leaked signing key lets
/// somebody else be this device to every peer that ever paired with it.
///
/// `ThisDeviceOnly` accessibility, so the key never rides an iCloud or
/// encrypted-backup restore onto a second device: two devices sharing one
/// pairing identity would each be able to claim the other's sessions.
enum ContinuityIdentityStore {

    private static let service = "com.joemattiello.icube.continuity"
    private static let account = "peer-identity"
    /// The stable id lives in `UserDefaults` because it is not secret; only the
    /// key material needs the Keychain.
    private static let idDefaultsKey = "continuity_peer_id"

    /// Loads the persisted identity, or mints and persists a new one.
    ///
    /// If the Keychain is unreadable (first unlock not yet reached, say) this
    /// returns a **fresh, unpersisted** identity rather than crashing. The
    /// consequence is honest and visible: the device appears as a new peer and
    /// has to pair again. Silently reusing a random key each launch would look
    /// like pairing that simply never sticks.
    static func loadOrCreate(displayName: String) -> ContinuityPeerIdentity {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: idDefaultsKey),
           let keyData = readKey(),
           let restored = try? ContinuityPeerIdentity(id: id, name: displayName, privateKeyData: keyData) {
            return restored
        }

        let fresh = ContinuityPeerIdentity(name: displayName)
        defaults.set(fresh.id, forKey: idDefaultsKey)
        if !writeKey(fresh.privateKeyData) {
            NSLog("[Continuity] could not persist the pairing key; this device will have to pair again next launch")
        }
        return fresh
    }

    /// Forgets this device's identity. Every peer that trusted it will have to
    /// pair again — which is the point: this is the "reset my identity" escape
    /// hatch for a user who believes their key is compromised.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: idDefaultsKey)
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKey() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeKey(_ data: Data) -> Bool {
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
