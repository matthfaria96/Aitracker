import CommonCrypto
import CryptoKit
import SQLite3
import XCTest
@testable import Claude_Usage

/// Covers the pieces of browser sign-in that don't need the user's Keychain:
/// Chromium cookie crypto, timestamp conversion, and reading a cookie DB.
final class BrowserCookieServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserCookieServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Crypto

    /// Encrypts like Chromium on macOS: "v10" + AES-128-CBC(PKCS7, IV = 16 spaces).
    private func chromiumEncrypt(_ plaintext: Data, key: Data) -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = key.withUnsafeBytes { keyBytes in
            plaintext.withUnsafeBytes { input in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv,
                        input.baseAddress, plaintext.count,
                        &output, output.count, &outLength)
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + Data(output[0..<outLength])
    }

    func testDeriveKeyIsAES128() {
        let key = BrowserCookieService.deriveKey(password: Data("peanuts".utf8))
        XCTAssertEqual(key.count, 16)
        // Deterministic for the same password.
        XCTAssertEqual(key, BrowserCookieService.deriveKey(password: Data("peanuts".utf8)))
    }

    func testDecryptLegacySchema() {
        let key = BrowserCookieService.deriveKey(password: Data("secret".utf8))
        let encrypted = chromiumEncrypt(Data("sk-ant-sid01-abc".utf8), key: key)
        XCTAssertEqual(BrowserCookieService.decryptChromiumValue(encrypted, key: key, dbVersion: 23), "sk-ant-sid01-abc")
    }

    func testDecryptV24StripsDomainHash() {
        let key = BrowserCookieService.deriveKey(password: Data("secret".utf8))
        let domainHash = Data(SHA256.hash(data: Data(".claude.ai".utf8)))
        let encrypted = chromiumEncrypt(domainHash + Data("sk-ant-sid01-xyz".utf8), key: key)
        XCTAssertEqual(BrowserCookieService.decryptChromiumValue(encrypted, key: key, dbVersion: 24), "sk-ant-sid01-xyz")
    }

    func testDecryptRejectsWrongKeyOrPrefix() {
        let key = BrowserCookieService.deriveKey(password: Data("secret".utf8))
        let wrong = BrowserCookieService.deriveKey(password: Data("other".utf8))
        let encrypted = chromiumEncrypt(Data("sk-ant-sid01-abc".utf8), key: key)
        XCTAssertNotEqual(BrowserCookieService.decryptChromiumValue(encrypted, key: wrong, dbVersion: 23), "sk-ant-sid01-abc")
        XCTAssertNil(BrowserCookieService.decryptChromiumValue(Data("xyz123".utf8), key: key, dbVersion: 24))
    }

    func testChromiumDate() {
        // 2026-01-01T00:00:00Z in Chromium microseconds since 1601.
        let unix: Int64 = 1_767_225_600
        let chromium = (unix + 11_644_473_600) * 1_000_000
        XCTAssertEqual(BrowserCookieService.chromiumDate(chromium)?.timeIntervalSince1970, TimeInterval(unix))
        XCTAssertNil(BrowserCookieService.chromiumDate(0))
    }

    // MARK: - Reading a Chromium cookie DB

    private func makeChromiumDB(rows: [(host: String, name: String, value: String)]) throws -> URL {
        let url = tempDir.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        INSERT INTO meta VALUES('version','24');
        CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
                             expires_utc INTEGER, last_access_utc INTEGER);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let sql = "INSERT INTO cookies VALUES('\(row.host)','\(row.name)','\(row.value)',x'',13410000000000000,\(index));"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    func testReadsOnlyExactDomain() throws {
        let cookies = try makeChromiumDB(rows: [
            (".claude.ai", "sessionKey", "sk-ant-sid01-claude"),
            ("platform.claude.com", "sessionKey", "sk-ant-sid01-console"),
            (".claude.ai", "lastActiveOrg", "org-1"),
            (".evilclaude.ai", "sessionKey", "sk-ant-sid01-evil"),
        ])
        let browser = SupportedBrowser.browser(withBundleIdentifier: "com.vivaldi.Vivaldi")!
        let profile = BrowserProfile(browser: browser, directoryName: "Default", displayName: "Trabalho", cookiesURL: cookies)

        let claude = try BrowserCookieService.shared.readCookies(named: "sessionKey", domain: "claude.ai", from: profile)
        XCTAssertEqual(claude.map(\.value), ["sk-ant-sid01-claude"])
        XCTAssertNotNil(claude.first?.expiresAt)

        let console = try BrowserCookieService.shared.readCookies(named: "sessionKey", domain: "platform.claude.com", from: profile)
        XCTAssertEqual(console.map(\.value), ["sk-ant-sid01-console"])
    }

    func testBrowserCatalogHasVivaldiSafeStorage() {
        let vivaldi = SupportedBrowser.browser(withBundleIdentifier: "com.vivaldi.vivaldi")
        XCTAssertEqual(vivaldi?.safeStorageService, "Vivaldi Safe Storage")
        XCTAssertEqual(vivaldi?.dataDirectory, "Vivaldi")
    }
}
