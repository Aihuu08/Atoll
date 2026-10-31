/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import Security
import Defaults

/// fork 加固：Screen Assistant 的 API key 存在钥匙串里，而不是 UserDefaults 明文 plist。
///
/// 读写方式与原来的 `Defaults[.xxxApiKey]` 相同（字符串，空串表示未设置）。
/// 第一次读取时，如果钥匙串里没有、而旧的 UserDefaults 里有值，会自动迁移到钥匙串
/// 并清空旧值，所以升级后不需要重新填写 key。
enum ScreenAssistantAPIKeys {
    private static let service = "com.Ebullioscopic.Atoll.screen-assistant"

    static var gemini: String {
        get { value(account: "gemini", legacy: .geminiApiKey) }
        set { store(newValue, account: "gemini", legacy: .geminiApiKey) }
    }

    static var openai: String {
        get { value(account: "openai", legacy: .openaiApiKey) }
        set { store(newValue, account: "openai", legacy: .openaiApiKey) }
    }

    static var claude: String {
        get { value(account: "claude", legacy: .claudeApiKey) }
        set { store(newValue, account: "claude", legacy: .claudeApiKey) }
    }

    static var groq: String {
        get { value(account: "groq", legacy: .groqApiKey) }
        set { store(newValue, account: "groq", legacy: .groqApiKey) }
    }

    /// 启动时调用一次，把旧版明文保存的 key 全部迁移到钥匙串。
    static func migrateLegacyKeys() {
        _ = gemini
        _ = openai
        _ = claude
        _ = groq
    }

    // MARK: - Private

    private static func value(account: String, legacy: Defaults.Key<String>) -> String {
        if let stored = read(account: account) {
            return stored
        }
        let legacyValue = Defaults[legacy]
        guard !legacyValue.isEmpty else { return "" }
        // 迁移成功才清空旧值；失败时继续使用旧值，不丢 key。
        if save(legacyValue, account: account) {
            Defaults.reset(legacy)
        }
        return legacyValue
    }

    private static func store(_ newValue: String, account: String, legacy: Defaults.Key<String>) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(account: account)
            Defaults.reset(legacy)
            return
        }
        if save(trimmed, account: account) {
            Defaults.reset(legacy)
        } else {
            // 钥匙串写入失败时退回旧存储，保证功能可用。
            Logger.log("ScreenAssistantAPIKeys: Keychain write failed for \(account), falling back to UserDefaults", category: .warning)
            Defaults[legacy] = trimmed
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else { return nil }
        return string
    }

    @discardableResult
    private static func save(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
