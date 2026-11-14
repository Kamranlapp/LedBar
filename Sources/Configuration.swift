import Foundation
import Security

struct Broker: Codable, Equatable {
    var host = ""
    var port = "1883"
    var username = ""
    var tls = false
    var delayedPublishEnabled: Bool?
}

struct Topic: Codable, Identifiable {
    var id = UUID()
    var path = ""

    var isValid: Bool {
        !path.isEmpty && path.utf8.count <= 65535 &&
        !path.contains("#") && !path.contains("+") && !path.utf8.contains(0)
    }
}

struct Strip: Codable, Identifiable {
    var id = UUID()
    var name: String
    var topic: UUID?
}

struct Command: Codable, Identifiable {
    struct Publication: Codable {
        var topic: UUID?
        var payload = ""
    }

    var id = UUID()
    var name = ""
    var publications = Array(repeating: Publication(), count: 3)

    private enum CodingKeys: String, CodingKey { case id, name, publications }
    private enum LegacyKeys: String, CodingKey { case topic, payload }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        if let saved = try values.decodeIfPresent([Publication].self, forKey: .publications) {
            for (index, publication) in saved.prefix(publications.count).enumerated() {
                publications[index] = publication
            }
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            publications[0] = Publication(
                topic: try legacy.decodeIfPresent(UUID.self, forKey: .topic),
                payload: try legacy.decodeIfPresent(String.self, forKey: .payload) ?? ""
            )
        }
    }
}

struct Configuration: Codable {
    var broker = Broker()
    var topics: [Topic] = []
    var strips = (1...3).map { Strip(name: "Лента \($0)") }
    var commands: [Command] = []

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "configuration"),
              let configuration = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return configuration
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "configuration")
        }
    }
}

enum PasswordStore {
    private static func query(for broker: Broker) -> [String: Any] {
        let account = [broker.tls ? "tls" : "tcp", broker.host, broker.port, broker.username]
        let data = (try? JSONEncoder().encode(account)) ?? Data()
        return query(account: data.base64EncodedString())
    }

    private static func query(account: String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.kam.ledbar.mqtt",
        kSecAttrAccount as String: account
    ] }

    static func read(for broker: Broker) -> String {
        read(query(for: broker)) ?? ""
    }

    static func migrateLegacy(for broker: Broker) {
        let legacy = query(account: "broker")
        guard !broker.host.isEmpty, let password = read(legacy) else { return }
        if (read(query(for: broker)) != nil || write(password, for: broker)) {
            SecItemDelete(legacy as CFDictionary)
        }
    }

    private static func read(_ query: [String: Any]) -> String? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ password: String, for broker: Broker) -> Bool {
        let query = query(for: broker)
        if password.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let value = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
