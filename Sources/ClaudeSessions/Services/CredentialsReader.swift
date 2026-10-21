import Foundation
import Security

enum CredentialsReader {
    struct Credentials {
        let accessToken: String
        let subscriptionType: String?
        let rateLimitTier: String?
        let expiresAt: Date?
    }

    static func read() -> Credentials? {
        if let k = readFromKeychain() { return k }
        return readFromFile()
    }

    private static func readFromKeychain() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return parse(jsonString: str)
    }

    private static func readFromFile() -> Credentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return parse(jsonString: str)
    }

    private static func parse(jsonString: String) -> Credentials? {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }

        let expiresAt: Date? = {
            if let ms = oauth["expiresAt"] as? Double {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            return nil
        }()

        return Credentials(
            accessToken: token,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            expiresAt: expiresAt
        )
    }
}
