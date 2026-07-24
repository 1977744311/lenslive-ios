// KeychainStore —— 串流密钥 / B 站身份码的本机钥匙串存取。
// PRD F3 安全要求：密钥只进 Keychain（kSecClassGenericPassword），
// RTMPTarget 只保存引用键（streamKeyRef），日志/导出永不出现明文。
import Foundation
import Security

struct KeychainStore: Sendable {

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    /// 服务命名空间；account = 引用键（如 RTMPTarget.streamKeyRef）
    var service: String = "dev.steven.LensLive.secrets"

    // MARK: - 写入（存在则更新）

    func save(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else {
            guard updateStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(updateStatus) }
        }
    }

    // MARK: - 读取（不存在返回 nil）

    func read(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 删除（不存在视为成功）

    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 是否已存有该引用键的密钥（界面显示 •••• / 未配置 用）
    func hasValue(forKey key: String) -> Bool {
        read(forKey: key) != nil
    }
}
