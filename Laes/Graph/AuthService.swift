#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct GraphError: LocalizedError {
    var errorDescription: String?
    var status = 0
    init(_ message: String, status: Int = 0) {
        errorDescription = message
        self.status = status
    }
}

/// OAuth 2.0 authorization code + PKCE against the Microsoft identity platform (public client).
final class AuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let redirectURI = "laes://auth"
    /// Notes are on unless switched off in Settings, which also drops the OneDrive folder from the sign-in.
    static var scopes: [String] {
        ["offline_access", "User.Read", "Calendars.ReadWrite", "Tasks.ReadWrite", "MailboxSettings.Read"]
            + (UserDefaults.standard.object(forKey: "notesEnabled") as? Bool ?? true ? ["Files.ReadWrite.AppFolder"] : [])
    }
    /// Multi-tenant public client registered in the ystmr.com Entra tenant; not a secret.
    static let clientID = "2528419c-bb2a-4d01-9c6a-f70ac8dc0e32"

    private static let keychainAccount = "refreshToken"

    private var accessTokenValue: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var webSession: ASWebAuthenticationSession?

    var hasSession: Bool { refreshToken != nil }

    func signIn() async throws {
        let clientID = Self.clientID
        let verifier = Self.randomURLSafe()
        let state = Self.randomURLSafe()
        var components = URLComponents(url: Self.endpoint("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: Self.pkceChallenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account"),  // always show the account picker
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "laes") { @Sendable url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? URLError(.userCancelledAuthentication)) }
            }
            session.presentationContextProvider = self
            webSession = session
            if !session.start() { continuation.resume(throwing: GraphError("Could not start the sign-in session.")) }
        }
        webSession = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let error = query["error"] { throw GraphError(query["error_description"] ?? error) }
        guard query["state"] == state else { throw GraphError("Sign-in response did not match the request. Please try again.") }
        guard let code = query["code"] else { throw GraphError("Sign-in returned no authorization code.") }

        try await redeem([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ])
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        accessTokenValue = nil
        expiry = .distantPast
        refreshToken = nil
    }

    func accessToken() async throws -> String {
        if let accessTokenValue, expiry.timeIntervalSinceNow > 60 { return accessTokenValue }
        return try await refreshAccessToken()
    }

    /// Forces a refresh; concurrent callers share one in-flight request so a rotated refresh token isn't raced.
    func refreshAccessToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task<String, Error> {
            guard let token = refreshToken else { throw GraphError("Not signed in.") }
            try await redeem(["grant_type": "refresh_token", "refresh_token": token])
            return accessTokenValue!
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        var access_token: String?
        var refresh_token: String?
        var expires_in: Double?
        var error: String?
        var error_description: String?
    }

    private func redeem(_ params: [String: String]) async throws {
        var params = params
        params["client_id"] = Self.clientID
        params["scope"] = Self.scopes.joined(separator: " ")
        var request = URLRequest(url: Self.endpoint("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let error = response.error {
            if error == "invalid_grant", params["grant_type"] == "refresh_token" {
                signOut()
                throw GraphError("Your Microsoft session expired. Please sign in again.")
            }
            throw GraphError(response.error_description ?? error)
        }
        guard let access = response.access_token else { throw GraphError("Token response contained no access token.") }
        accessTokenValue = access
        expiry = Date(timeIntervalSinceNow: response.expires_in ?? 3600)
        if let rotated = response.refresh_token { refreshToken = rotated }
    }

    private static func endpoint(_ name: String) -> URL {
        // "common" = any work/school tenant plus personal Microsoft accounts
        URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/\(name)")!
    }

    private static func formEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&")
    }

    // MARK: - PKCE

    static func pkceChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomURLSafe() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain

    private var refreshToken: String? {
        get { Keychain.read(Self.keychainAccount) }
        set { Keychain.write(newValue, account: Self.keychainAccount) }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApp.keyWindow ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        #endif
    }
}

/// Secrets for this app in the Keychain, readable after the first unlock (background sync) and never synced off the device.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.laes.Laes", kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil deletes. Returns whether it was saved.
    @discardableResult
    static func write(_ value: String?, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        guard let value else { return true }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
