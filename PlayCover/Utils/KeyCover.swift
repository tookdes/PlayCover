//
//  KeyCover.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import CryptoKit
import SwiftUI
import Security

struct KeyCover {
    static var shared = KeyCover()
    static var playChainPath: URL {
        let playChainDir = PlayTools.playCoverContainer.appendingPathComponent("PlayChain")
        do {
            try FileManager.default.createDirectory(at: playChainDir, withIntermediateDirectories: true)
        } catch {
            Log.shared.error(error)
        }
        return playChainDir
    }

    // This is only exposed at runtime
    var keyCoverPlainTextKey: String? = KeyCoverPreferences.shared.keyCoverEnabled == .selfGeneratedPassword
    ? KeyCoverPassword.shared.getKeyCoverPassword() : nil

    func isKeyCoverEnabled() -> Bool {
        return KeyCoverPreferences.shared.keyCoverEnabled != .disabled
    }

    func listKeychains() -> [KeyCoverKey] {
        // Enumerate all the keychains
        let keychains = try? FileManager.default
            .contentsOfDirectory(at: KeyCover.playChainPath,
                                 includingPropertiesForKeys: nil,
                                 options: .skipsHiddenFiles)
        var keychainList: [KeyCoverKey] = []
        for keychain in keychains ?? [] {
            let keychainName = keychain.deletingPathExtension().lastPathComponent
            let keychain = KeyCoverKey(appBundleID: keychainName)
            keychainList.append(keychain)
        }
        return keychainList
    }

    func unlockedCount() -> Int {
        var count = 0
        for keychain in listKeychains() where !keychain.chainEncryptionStatus {
            count += 1
        }
        return count
    }

    func unlockChain(_ keychain: KeyCoverKey) async throws {
        if keyCoverPlainTextKey == nil {
            let task = Task {@MainActor in
                KeyCoverObservable.shared.isKeyCoverUnlockingPromptShown = true
            }
            await task.value
            while true {
                let promptShown = await MainActor.run {
                    KeyCoverObservable.shared.isKeyCoverUnlockingPromptShown
                }
                if !promptShown { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        if keychain.chainEncryptionStatus {
            try keychain.decryptKeyDB()
        }
    }

    func lockChain(_ keychain: KeyCoverKey) throws {
        if keyCoverPlainTextKey == nil {
            return
        }
        if !keychain.chainEncryptionStatus {
            try keychain.encryptKeyDB()
        }
    }

    func lockAllChainsAsync() {
        Task {
            for keychain in KeyCover.shared.listKeychains() where !keychain.chainEncryptionStatus {
                try? keychain.encryptKeyDB()
            }
        }
    }
}

@MainActor
class KeyCoverObservable: ObservableObject {
    static var shared = KeyCoverObservable()

    @Published var keyCoverEnabled = KeyCover.shared.isKeyCoverEnabled()
    @Published var unlockedCount = KeyCover.shared.unlockedCount()
    @Published var keychains = KeyCover.shared.listKeychains()

    @Published var isKeyCoverUnlockingPromptShown = KeyCoverPreferences.shared.keyCoverEnabled == .selfGeneratedPassword
    ? false : KeyCoverPreferences.shared.keyCoverEnabled == .disabled
    ? false : KeyCoverPreferences.shared.promptForKeyCoverPasswordAtLaunch

    func update() {
        keyCoverEnabled = KeyCover.shared.isKeyCoverEnabled()
        unlockedCount = KeyCover.shared.unlockedCount()
        keychains = KeyCover.shared.listKeychains()
    }
}

struct KeyCoverKey {
    static let encryptedKeyExtension = "keyCover"

    var appBundleID: String

    var decryptedKeyDB: URL {
        KeyCover.playChainPath
            .appendingSafeFileNameComponent(appBundleID)
            .appendingPathExtension("db")
    }
    var encryptedKeyDB: URL {
        KeyCover.playChainPath
            .appendingSafeFileNameComponent(appBundleID)
            .appendingPathExtension(KeyCoverKey.encryptedKeyExtension)
    }

    var chainEncryptionStatus: Bool {
        return FileManager.default.fileExists(atPath: encryptedKeyDB.path)
    }

    func encryptKeyDB() throws {
        if let plainTextKey = KeyCover.shared.keyCoverPlainTextKey {
            guard FileManager.default.fileExists(atPath: "/usr/bin/openssl") else {
                throw ShellError(output: "openssl not found at /usr/bin/openssl")
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            task.currentDirectoryPath = KeyCover.playChainPath.path
            task.arguments = ["enc", "-aes-256-cbc", "-A",
                                "-in", decryptedKeyDB.path,
                                "-out", encryptedKeyDB.path,
                                "-pass", "stdin"]
            let pipe = Pipe()
            task.standardInput = pipe
            try task.run()
            if let keyData = (plainTextKey + "\n").data(using: .utf8) {
                pipe.fileHandleForWriting.write(keyData)
            }
            try? pipe.fileHandleForWriting.close()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else {
                throw ShellError(output: "openssl encryption failed with status \(task.terminationStatus)")
            }

            try deleteKeyDB()

            Task { @MainActor in
                KeyCoverObservable.shared.update()
            }
        }
    }

    func decryptKeyDB() throws {
        if let plainTextKey = KeyCover.shared.keyCoverPlainTextKey {
            guard FileManager.default.fileExists(atPath: "/usr/bin/openssl") else {
                throw ShellError(output: "openssl not found at /usr/bin/openssl")
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            task.arguments = ["enc", "-aes-256-cbc", "-A", "-d", "-in", encryptedKeyDB.path, "-out",
                              decryptedKeyDB.path,
                              "-pass", "stdin"]
            let pipe = Pipe()
            task.standardInput = pipe
            try task.run()
            if let keyData = (plainTextKey + "\n").data(using: .utf8) {
                pipe.fileHandleForWriting.write(keyData)
            }
            try? pipe.fileHandleForWriting.close()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else {
                throw ShellError(output: "openssl decryption failed with status \(task.terminationStatus)")
            }

            try FileManager.default.removeItem(at: encryptedKeyDB)

            Task { @MainActor in
                KeyCoverObservable.shared.update()
            }
        }
    }

    func deleteKeyDB() throws {
        try FileManager.default.removeItem(at: decryptedKeyDB)
    }

    func deleteEncryptedKeyDB() throws {
        try FileManager.default.removeItem(at: encryptedKeyDB)
    }
}

class KeyCoverPassword {
    static let shared = KeyCoverPassword()

    let tag = "io.playcover.masterkey"

    func setKeyCoverPassword(_ key: String) {
        guard let keyData = key.data(using: .utf8) else {
            Log.shared.error("Failed to encode KeyCover password to UTF-8")
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                    kSecValueData as String: keyData]
        // thank you apple very cool
        // Get the key
        let oldKey = getKeyCoverPassword()
        // if it is not nil, then we need to decrypt all the keychains
        if oldKey != nil {
            KeyCover.shared.keyCoverPlainTextKey = oldKey
            for keychain in KeyCover.shared.listKeychains() where keychain.chainEncryptionStatus {
                try? keychain.decryptKeyDB()
            }
            KeyCover.shared.keyCoverPlainTextKey = nil
            // Remove any existing master key
            SecItemDelete(query as CFDictionary)
        }

        // Store the master key in macOS keychain
        Task(priority: .userInitiated) {
            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess {
                Log.shared.error("Error storing master key in keychain (status: \(status))")
            }
        }

        KeyCover.shared.keyCoverPlainTextKey = key

        // Encrypts all keychains
        for keychain in KeyCover.shared.listKeychains() where !keychain.chainEncryptionStatus {
            try? keychain.encryptKeyDB()
        }

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    func getKeyCoverPassword() -> String? {
        // Get the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecReturnData as String: kCFBooleanTrue as Any,
                                    kSecMatchLimit as String: kSecMatchLimitOne]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    func removeKeyCoverPassword() {
        // Decrypt all key dbs
        for chain in KeyCover.shared.listKeychains() where chain.chainEncryptionStatus {
                try? chain.decryptKeyDB()
        }

        // Remove the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        Task(priority: .userInitiated) {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess {
                Log.shared.error("Error removing master key from keychain (status: \(status))")
            }
        }

        KeyCoverPreferences.shared.keyCoverEnabled = .disabled
        KeyCover.shared.keyCoverPlainTextKey = nil

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    func forceResetKeyCoverPassword() {
        // If a key is in memory, don't do anything (prevent accidental deletion)
        if KeyCover.shared.keyCoverPlainTextKey != nil {
            return
        }
        // Remove the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            Log.shared.error("Error removing master key from keychain (status: \(status))")
        }

        KeyCoverPreferences.shared.keyCoverEnabled = .disabled
        KeyCover.shared.keyCoverPlainTextKey = nil

        // Being a force reset, we have to nuke everything (because it's useless otherwise)
        for chain in KeyCover.shared.listKeychains() {
            try? chain.deleteEncryptedKeyDB()
        }

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    func validatePassword(_ key: String) -> Bool {
        guard let stored = getKeyCoverPassword() else { return false }
        // Constant-time comparison to prevent timing attacks
        guard let keyData = key.data(using: .utf8),
              let storedData = stored.data(using: .utf8),
              keyData.count == storedData.count else {
            return false
        }
        var result: UInt8 = 0
        for (a, b) in zip(keyData, storedData) {
            result |= a ^ b
        }
        return result == 0
    }

    func generateVerySecurePassword() -> String {
        // oh my god
        let length = 32
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+"
        return String((0..<length).map { _ in letters.randomElement() ?? "." })
    }
}
