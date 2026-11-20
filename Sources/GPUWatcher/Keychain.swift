import Foundation
import Security

/// SSH passwords live in the user's login keychain, one generic-password item per host.
enum Keychain {
    private static let service = "dev.gpuwatcher.ssh-password"

    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }

    @discardableResult
    static func set(_ password: String, host: String) -> Bool {
        delete(host: host)
        var item = query(host)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "GPU Watcher SSH password (\(host))"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func get(host: String) -> String? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Existence check that never reads the secret (so it never triggers a keychain prompt).
    static func has(host: String) -> Bool {
        var q = query(host)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(host: String) -> Bool {
        let status = SecItemDelete(query(host) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// When ssh needs a password it runs the program in SSH_ASKPASS with the prompt as its argument and reads
/// the answer from stdout. We point it back at this same binary; this is that mode.
enum Askpass {
    static let hostEnv = "GPUWATCHER_ASKPASS_HOST"

    /// Returns the text to hand to ssh, or nil to refuse. Only plain password prompts are answered:
    /// host-key confirmations, key passphrases and 2FA codes are always refused.
    static func answer(prompt: String, kind: String?, host: String) -> String? {
        let p = prompt.lowercased()
        guard kind == nil || kind == "", p.contains("password"), !p.contains("passphrase") else { return nil }
        return Keychain.get(host: host)
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let host = env[hostEnv] else { return }
        let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        guard let pw = answer(prompt: prompt, kind: env["SSH_ASKPASS_PROMPT"], host: host) else { exit(1) }
        print(pw)
        exit(0)
    }
}
