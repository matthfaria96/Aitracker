//
//  BrowserCookieService.swift
//  Aitracker
//
//  Reads session cookies straight from the user's real browser (Vivaldi,
//  Chrome, Brave, Edge, Arc, Opera, Chromium, Firefox) instead of running an
//  embedded WebKit login. Every browser profile is scanned, so several
//  accounts — even from the same organization — can be imported side by side,
//  one per browser profile.
//

import AppKit
import CommonCrypto
import Foundation
import Security
import SQLite3

// MARK: - Models

/// A browser installed on this Mac that we know how to read cookies from.
nonisolated struct SupportedBrowser: Identifiable, Hashable, Sendable {
    enum Engine: Sendable { case chromium, firefox }

    let id: String                  // bundle identifier
    let name: String
    let engine: Engine
    /// Data directory relative to ~/Library/Application Support.
    let dataDirectory: String
    /// Keychain service/account holding the cookie encryption password (Chromium only).
    let safeStorageService: String?
    let safeStorageAccount: String?
    /// Opera keeps its single profile directly in the data directory.
    let profilesAtRoot: Bool

    init(
        id: String,
        name: String,
        engine: Engine = .chromium,
        dataDirectory: String,
        safeStorage: String? = nil,
        profilesAtRoot: Bool = false
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.dataDirectory = dataDirectory
        self.safeStorageService = safeStorage.map { "\($0) Safe Storage" }
        self.safeStorageAccount = safeStorage
        self.profilesAtRoot = profilesAtRoot
    }

    var dataURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(dataDirectory, isDirectory: true)
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    var isInstalled: Bool {
        appURL != nil && FileManager.default.fileExists(atPath: dataURL.path)
    }

    static let all: [SupportedBrowser] = [
        SupportedBrowser(id: "com.vivaldi.Vivaldi", name: "Vivaldi", dataDirectory: "Vivaldi", safeStorage: "Vivaldi"),
        SupportedBrowser(id: "com.google.Chrome", name: "Google Chrome", dataDirectory: "Google/Chrome", safeStorage: "Chrome"),
        SupportedBrowser(id: "com.google.Chrome.beta", name: "Chrome Beta", dataDirectory: "Google/Chrome Beta", safeStorage: "Chrome"),
        SupportedBrowser(id: "com.brave.Browser", name: "Brave", dataDirectory: "BraveSoftware/Brave-Browser", safeStorage: "Brave"),
        SupportedBrowser(id: "com.microsoft.edgemac", name: "Microsoft Edge", dataDirectory: "Microsoft Edge", safeStorage: "Microsoft Edge"),
        SupportedBrowser(id: "company.thebrowser.Browser", name: "Arc", dataDirectory: "Arc/User Data", safeStorage: "Arc"),
        SupportedBrowser(id: "com.operasoftware.Opera", name: "Opera", dataDirectory: "com.operasoftware.Opera", safeStorage: "Opera", profilesAtRoot: true),
        SupportedBrowser(id: "org.chromium.Chromium", name: "Chromium", dataDirectory: "Chromium", safeStorage: "Chromium"),
        SupportedBrowser(id: "org.mozilla.firefox", name: "Firefox", engine: .firefox, dataDirectory: "Firefox"),
    ]

    static func browser(withBundleIdentifier bundleId: String) -> SupportedBrowser? {
        all.first { $0.id.caseInsensitiveCompare(bundleId) == .orderedSame }
    }
}

/// One profile inside a browser (Chromium "Default", "Profile 1", a Firefox profile…).
nonisolated struct BrowserProfile: Identifiable, Hashable, Sendable {
    let browser: SupportedBrowser
    /// Directory name, e.g. "Default" or "Profile 2" — what `--profile-directory` expects.
    let directoryName: String
    /// Human name shown in the browser's profile picker, e.g. "Trabalho".
    let displayName: String
    let cookiesURL: URL

    var id: String { "\(browser.id)/\(directoryName)" }
}

/// A session cookie found in a browser profile.
nonisolated struct BrowserSessionCookie: Identifiable, Hashable, Sendable {
    let profile: BrowserProfile
    let domain: String
    let value: String
    let expiresAt: Date?

    var id: String { "\(profile.id)|\(domain)|\(value.suffix(12))" }
}

nonisolated enum BrowserCookieError: LocalizedError {
    case keychainAccessDenied(browser: String)
    case keychainItemMissing(browser: String)
    case databaseUnreadable(path: String)

    var errorDescription: String? {
        switch self {
        case .keychainAccessDenied(let browser):
            return String(format: NSLocalizedString("browser_auth.error.keychain_denied", comment: ""), browser)
        case .keychainItemMissing(let browser):
            return String(format: NSLocalizedString("browser_auth.error.keychain_missing", comment: ""), browser)
        case .databaseUnreadable(let path):
            return String(format: NSLocalizedString("browser_auth.error.db_unreadable", comment: ""), path)
        }
    }
}

// MARK: - Service

/// Stateless reader for browser cookie stores. All work is synchronous and
/// file-bound, so call it from a background task.
nonisolated final class BrowserCookieService: @unchecked Sendable {
    static let shared = BrowserCookieService()

    /// Chromium cookie encryption keys, cached per keychain service so macOS only
    /// asks for Keychain permission once per browser per app launch.
    private var keyCache: [String: Data] = [:]
    private let lock = NSLock()

    // MARK: Browser discovery

    /// The browser macOS opens https links with (e.g. Vivaldi).
    func defaultBrowserBundleIdentifier() -> String? {
        guard let probe = URL(string: "https://claude.ai"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    /// Installed browsers we can read, with the system default first.
    func installedBrowsers() -> [SupportedBrowser] {
        let installed = SupportedBrowser.all.filter(\.isInstalled)
        guard let defaultId = defaultBrowserBundleIdentifier(),
              let index = installed.firstIndex(where: { $0.id.caseInsensitiveCompare(defaultId) == .orderedSame }) else {
            return installed
        }
        var ordered = installed
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    func profiles(for browser: SupportedBrowser) -> [BrowserProfile] {
        switch browser.engine {
        case .chromium: return chromiumProfiles(for: browser)
        case .firefox: return firefoxProfiles(for: browser)
        }
    }

    private func chromiumProfiles(for browser: SupportedBrowser) -> [BrowserProfile] {
        let fm = FileManager.default
        let root = browser.dataURL

        func cookiesFile(in dir: URL) -> URL? {
            // macOS Chromium keeps "Cookies" at the profile root; newer builds
            // on some platforms moved it under "Network/".
            for candidate in [dir.appendingPathComponent("Cookies"),
                              dir.appendingPathComponent("Network/Cookies")]
            where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            return nil
        }

        if browser.profilesAtRoot {
            guard let cookies = cookiesFile(in: root) else { return [] }
            return [BrowserProfile(browser: browser, directoryName: "", displayName: browser.name, cookiesURL: cookies)]
        }

        // Human-readable names live in "Local State" → profile.info_cache.
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, info) in cache {
                if let name = (info as? [String: Any])?["name"] as? String, !name.isEmpty {
                    names[dir] = name
                }
            }
        }

        let entries = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return entries
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .compactMap { dir -> BrowserProfile? in
                guard let cookies = cookiesFile(in: root.appendingPathComponent(dir)) else { return nil }
                return BrowserProfile(browser: browser, directoryName: dir, displayName: names[dir] ?? dir, cookiesURL: cookies)
            }
            .sorted { lhs, rhs in
                if lhs.directoryName == "Default" { return true }
                if rhs.directoryName == "Default" { return false }
                return lhs.directoryName.localizedStandardCompare(rhs.directoryName) == .orderedAscending
            }
    }

    private func firefoxProfiles(for browser: SupportedBrowser) -> [BrowserProfile] {
        let fm = FileManager.default
        let profilesDir = browser.dataURL.appendingPathComponent("Profiles")
        let entries = (try? fm.contentsOfDirectory(atPath: profilesDir.path)) ?? []
        return entries.sorted().compactMap { dir in
            let cookies = profilesDir.appendingPathComponent(dir).appendingPathComponent("cookies.sqlite")
            guard fm.fileExists(atPath: cookies.path) else { return nil }
            // Directory is "<salt>.<name>", e.g. "a1b2c3.default-release".
            let display = dir.split(separator: ".", maxSplits: 1).last.map(String.init) ?? dir
            return BrowserProfile(browser: browser, directoryName: dir, displayName: display, cookiesURL: cookies)
        }
    }

    // MARK: Opening the browser

    /// Opens `url` in the given browser — in a specific profile when one is
    /// given (Chromium only) — and brings it to the front.
    func open(_ url: URL, in browser: SupportedBrowser?, profile: BrowserProfile? = nil) {
        guard let browser, let appURL = browser.appURL else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if browser.engine == .chromium, let profile, !profile.directoryName.isEmpty {
            // A second Chromium process hands its command line to the running
            // instance (process singleton) and exits, so this opens the URL in
            // the requested profile whether or not the browser is already open.
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--profile-directory=\(profile.directoryName)", url.absoluteString]
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    logOnMain("BrowserCookieService: profile launch failed, falling back – \(error.localizedDescription)")
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            return
        }

        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }

    // MARK: Reading cookies

    /// Finds the cookie `name` for `domain` (exact host or its dot-prefixed
    /// form — so "claude.ai" never matches "platform.claude.com") in every
    /// profile of every given browser. Errors per browser are returned rather
    /// than thrown so one locked keychain item doesn't hide the others.
    func findCookies(
        named name: String,
        domain: String,
        in browsers: [SupportedBrowser]
    ) -> (cookies: [BrowserSessionCookie], errors: [String: Error]) {
        var found: [BrowserSessionCookie] = []
        var errors: [String: Error] = [:]
        for browser in browsers {
            for profile in profiles(for: browser) {
                do {
                    found.append(contentsOf: try readCookies(named: name, domain: domain, from: profile))
                } catch {
                    errors[browser.id] = error
                    // A keychain refusal applies to every profile of this browser.
                    if error is BrowserCookieError { break }
                }
            }
        }
        return (found, errors)
    }

    func readCookies(named name: String, domain: String, from profile: BrowserProfile) throws -> [BrowserSessionCookie] {
        let hosts = [domain, ".\(domain)"]
        switch profile.browser.engine {
        case .chromium:
            return try readChromiumCookies(named: name, hosts: hosts, profile: profile)
        case .firefox:
            return try readFirefoxCookies(named: name, hosts: hosts, profile: profile)
        }
    }

    private func readChromiumCookies(named name: String, hosts: [String], profile: BrowserProfile) throws -> [BrowserSessionCookie] {
        let rows = try withSnapshot(of: profile.cookiesURL) { db -> (version: Int, rows: [(host: String, value: String, encrypted: Data, expires: Int64)]) in
            var version = 0
            if let meta = try? query(db, "SELECT value FROM meta WHERE key = 'version'", bind: [], map: { stmt in
                Int(columnText(stmt, 0) ?? "") ?? 0
            }), let first = meta.first {
                version = first
            }
            let rows = try query(
                db,
                "SELECT host_key, value, encrypted_value, expires_utc FROM cookies WHERE name = ? AND host_key IN (?, ?) ORDER BY last_access_utc DESC",
                bind: [name] + hosts
            ) { stmt in
                (host: columnText(stmt, 0) ?? "",
                 value: columnText(stmt, 1) ?? "",
                 encrypted: columnBlob(stmt, 2),
                 expires: sqlite3_column_int64(stmt, 3))
            }
            return (version, rows)
        }

        guard !rows.rows.isEmpty else { return [] }

        return try rows.rows.compactMap { row -> BrowserSessionCookie? in
            var value = row.value
            if value.isEmpty, !row.encrypted.isEmpty {
                let key = try encryptionKey(for: profile.browser)
                guard let decrypted = Self.decryptChromiumValue(row.encrypted, key: key, dbVersion: rows.version) else {
                    logOnMain("BrowserCookieService: could not decrypt cookie in \(profile.id)")
                    return nil
                }
                value = decrypted
            }
            guard !value.isEmpty else { return nil }
            return BrowserSessionCookie(
                profile: profile,
                domain: row.host,
                value: value,
                expiresAt: Self.chromiumDate(row.expires)
            )
        }
    }

    private func readFirefoxCookies(named name: String, hosts: [String], profile: BrowserProfile) throws -> [BrowserSessionCookie] {
        try withSnapshot(of: profile.cookiesURL) { db in
            try query(
                db,
                "SELECT host, value, expiry FROM moz_cookies WHERE name = ? AND host IN (?, ?) ORDER BY lastAccessed DESC",
                bind: [name] + hosts
            ) { stmt in
                let expiry = sqlite3_column_int64(stmt, 2)
                return BrowserSessionCookie(
                    profile: profile,
                    domain: columnText(stmt, 0) ?? "",
                    value: columnText(stmt, 1) ?? "",
                    // Firefox stores seconds; some versions store milliseconds.
                    expiresAt: expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry > 100_000_000_000 ? expiry / 1000 : expiry)) : nil
                )
            }
            .filter { !$0.value.isEmpty }
        }
    }

    // MARK: Chromium crypto

    /// Chromium on macOS encrypts cookies with AES-128-CBC using a key derived
    /// (PBKDF2-SHA1, salt "saltysalt", 1003 rounds) from a random password the
    /// browser keeps in the login Keychain as "<Browser> Safe Storage". Reading
    /// it makes macOS ask the user once ("Always Allow" persists the grant).
    private func encryptionKey(for browser: SupportedBrowser) throws -> Data {
        guard let service = browser.safeStorageService else {
            throw BrowserCookieError.keychainItemMissing(browser: browser.name)
        }

        lock.lock()
        if let cached = keyCache[service] { lock.unlock(); return cached }
        lock.unlock()

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account = browser.safeStorageAccount {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound, query[kSecAttrAccount as String] != nil {
            // Some builds use a different account name — match on service only.
            query.removeValue(forKey: kSecAttrAccount as String)
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw BrowserCookieError.keychainItemMissing(browser: browser.name)
        default:
            // errSecUserCanceled / errSecAuthFailed / errSecInteractionNotAllowed…
            throw BrowserCookieError.keychainAccessDenied(browser: browser.name)
        }

        guard let passwordData = item as? Data else {
            throw BrowserCookieError.keychainItemMissing(browser: browser.name)
        }

        let key = Self.deriveKey(password: passwordData)
        lock.lock()
        keyCache[service] = key
        lock.unlock()
        return key
    }

    static func deriveKey(password: Data) -> Data {
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        _ = password.withUnsafeBytes { pwd in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pwd.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &derived, derived.count
            )
        }
        return Data(derived)
    }

    /// Decrypts a "v10"/"v11" Chromium cookie value. From cookie DB schema
    /// version 24 on, the plaintext starts with SHA-256(host_key) (32 bytes),
    /// which is stripped here.
    static func decryptChromiumValue(_ encrypted: Data, key: Data, dbVersion: Int) -> String? {
        let bytes = [UInt8](encrypted)
        guard bytes.count > 3 else { return nil }
        let prefix = String(bytes: bytes[0..<3], encoding: .ascii)
        guard prefix == "v10" || prefix == "v11" else { return nil }

        let ciphertext = Array(bytes[3...])
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128) // 16 spaces
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outLength = 0

        let status = key.withUnsafeBytes { keyBytes in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                keyBytes.baseAddress, key.count,
                iv,
                ciphertext, ciphertext.count,
                &output, output.count,
                &outLength
            )
        }
        guard status == kCCSuccess else { return nil }

        var plaintext = Array(output[0..<outLength])
        if dbVersion >= 24, plaintext.count >= 32 {
            plaintext.removeFirst(32)
        }
        return String(bytes: plaintext, encoding: .utf8)
    }

    /// Chromium timestamps are microseconds since 1601-01-01 UTC.
    static func chromiumDate(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let unixMicros = value - 11_644_473_600_000_000
        return Date(timeIntervalSince1970: TimeInterval(unixMicros) / 1_000_000)
    }

    // MARK: SQLite helpers

    /// Browsers keep their cookie DB open (and Chromium locks it), so read from
    /// a private copy (plus any -wal/-journal sidecars) in a temp directory.
    private func withSnapshot<T>(of url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("aitracker-cookies-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tempDir) }

        let copy = tempDir.appendingPathComponent("Cookies.db")
        do {
            try fm.copyItem(at: url, to: copy)
        } catch {
            throw BrowserCookieError.databaseUnreadable(path: url.path)
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw BrowserCookieError.databaseUnreadable(path: url.path)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func query<T>(_ db: OpaquePointer, _ sql: String, bind: [String], map: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw BrowserCookieError.databaseUnreadable(path: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient)
        }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(map(stmt))
        }
        return results
    }
}

private nonisolated func logOnMain(_ message: String) {
    Task { @MainActor in LoggingService.shared.logError(message) }
}

private nonisolated func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
}

private nonisolated func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
    let length = Int(sqlite3_column_bytes(stmt, index))
    guard length > 0, let pointer = sqlite3_column_blob(stmt, index) else { return Data() }
    return Data(bytes: pointer, count: length)
}
