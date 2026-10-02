// Signing in with Google for the Drive library (spec 07): OAuth 2.0 for installed apps with PKCE, the flow Google
// accepts from a system browser sheet. No client secret (an iOS-type client ID, used by the Mac and iPad apps); the
// app asks only for its own hidden app folder in Drive plus the person's email and name (shown in Settings → Account).
// Tokens live in the Keychain.

import CryptoKit
import Foundation

public struct GoogleOAuth: Sendable {
    public static let scopes = ["openid", "email", "profile", "https://www.googleapis.com/auth/drive.appdata"]
    public let clientID: String

    public init(clientID: String) { self.clientID = clientID }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc" (Google's redirect scheme for it).
    public var redirectScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    public var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    public struct Attempt: Sendable {
        public let verifier: String
        public let state: String
        public let url: URL
    }

    /// A fresh sign-in: a one-time secret (PKCE verifier) and the Google page to open. `loginHint` suggests an account
    /// (the one NotebookLM is signed in with), so the same Google account holds the library.
    public func begin(loginHint: String? = nil) -> Attempt {
        let verifier = Self.randomString(64)
        let state = Self.randomString(24)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        if let hint = loginHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "login_hint", value: hint))
        }
        return Attempt(verifier: verifier, state: state, url: components.url!)
    }

    /// The code from Google's redirect, if it belongs to this attempt (our redirect scheme, and the state must match).
    public func code(from callback: URL, for attempt: Attempt) -> String? {
        guard callback.scheme?.lowercased() == redirectScheme.lowercased() else { return nil }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == attempt.state else { return nil }
        return items.first(where: { $0.name == "code" })?.value
    }

    public func tokenRequest(code: String, verifier: String) -> URLRequest {
        form(["code": code, "client_id": clientID, "redirect_uri": redirectURI, "grant_type": "authorization_code", "code_verifier": verifier])
    }

    public func refreshRequest(refreshToken: String) -> URLRequest {
        form(["refresh_token": refreshToken, "client_id": clientID, "grant_type": "refresh_token"])
    }

    /// Signing out: Google forgets the grant. The token goes in the POST body, never the URL (URLs end up in logs).
    public func revokeRequest(token: String) -> URLRequest {
        form(["token": token], to: "https://oauth2.googleapis.com/revoke")
    }

    public struct Tokens: Codable, Equatable, Sendable {
        public var access: String
        public var refresh: String?
        public var expires: Double      // Unix seconds
        public var email: String?
        public var name: String?
        public func isFresh(now: Date = Date()) -> Bool { expires - 60 > now.timeIntervalSince1970 }
    }

    /// Reads Google's token answer. A refresh answer has no refresh token or ID token: keep the ones we had.
    public static func tokens(from data: Data, previous: Tokens? = nil, now: Date = Date()) -> Tokens? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String else { return nil }
        let lifetime = (object["expires_in"] as? Double) ?? Double(object["expires_in"] as? Int ?? 3600)
        let claims = (object["id_token"] as? String).flatMap(claimsFromIDToken)
        let email = (claims?["email"] as? String) ?? previous?.email
        let name = (claims?["name"] as? String).map(Self.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? previous?.name
        return Tokens(access: access, refresh: (object["refresh_token"] as? String) ?? previous?.refresh,
                      expires: now.timeIntervalSince1970 + lifetime, email: email, name: name)
    }

    /// The email inside Google's ID token (a signed JWT we received straight from Google over TLS; only displayed).
    static func emailFromIDToken(_ token: String) -> String? { claimsFromIDToken(token)?["email"] as? String }

    /// A name on one line, of a sensible length (it's only ever displayed).
    static func displayName(_ name: String) -> String { String(name.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80)) }

    static func claimsFromIDToken(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
    }

    private func form(_ fields: [String: String], to endpoint: String = "https://oauth2.googleapis.com/token") -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        return request
    }
}
