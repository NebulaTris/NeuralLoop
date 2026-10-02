import Foundation
import Testing
@testable import NeuralLoopCore

private let oauth = GoogleOAuth(clientID: "123-abc.apps.googleusercontent.com")

@Test func pkceChallengeIsTheBase64URLSHA256OfTheVerifier() {
    // Expected values computed independently: base64url(sha256(verifier)) without padding, in Python's hashlib.
    #expect(GoogleOAuth.challenge(for: "dBjftJeZ4CVP-mJ92K9pMYXcZ8dvAQuzJXa_Yg5TM_EVOFsBfr_jx8") == "RTJoGSewc4QcwE4ll7EsEAqWqDURWt5vz1UaTsr_Wl8")
    #expect(GoogleOAuth.challenge(for: "dBjftJeZ4CVP-mJ92K9pMYXcZ8dvAQuzJXa_Yg5TM_E") == "lYQ4pb989gjywcZDlUeiPngA7UTVyGLkHFa_VkZ4ifY")
}

@Test func signInAsksOnlyForTheAppFolderAndChecksTheState() throws {
    let attempt = oauth.begin()
    let items = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)!.queryItems!
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    #expect(value("scope") == "openid email profile https://www.googleapis.com/auth/drive.appdata")
    #expect(value("login_hint") == nil)
    #expect(value("code_challenge_method") == "S256" && value("code_challenge") == GoogleOAuth.challenge(for: attempt.verifier))
    #expect(value("redirect_uri") == "com.googleusercontent.apps.123-abc:/oauth2redirect")
    #expect(attempt.verifier.count == 64 && oauth.begin().verifier != attempt.verifier)
    let good = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=\(attempt.state)&code=4/xyz")!
    let forged = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=nope&code=4/xyz")!
    #expect(oauth.code(from: good, for: attempt) == "4/xyz" && oauth.code(from: forged, for: attempt) == nil)
    let elsewhere = URL(string: "https://evil.example/oauth2redirect?state=\(attempt.state)&code=4/xyz")!
    #expect(oauth.code(from: elsewhere, for: attempt) == nil)
    let stateless = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?code=4/xyz")!
    #expect(oauth.code(from: stateless, for: attempt) == nil)
}

@Test func signingOutRevokesWithTheTokenInTheBody() {
    let request = oauth.revokeRequest(token: "1//r+t/=")
    #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
    #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "token=1%2F%2Fr%2Bt%2F%3D")
}

@Test func theVerifierAndStateUseTheFullPKCEAlphabet() {
    let attempt = oauth.begin()
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    #expect(attempt.state.count == 24 && attempt.state.allSatisfy(allowed.contains) && attempt.verifier.allSatisfy(allowed.contains))
}

@Test func tokensAreReadAndRefreshKeepsWhatItDoesntResend() throws {
    // {"email":"sam@example.com"} as a JWT payload.
    let idToken = "e30." + Data(#"{"email":"sam@example.com"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".sig"
    let first = GoogleOAuth.tokens(from: Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600,"id_token":"\#(idToken)"}"#.utf8),
                                   now: Date(timeIntervalSince1970: 1000))
    #expect(first == GoogleOAuth.Tokens(access: "a1", refresh: "r1", expires: 4600, email: "sam@example.com"))
    let refreshed = GoogleOAuth.tokens(from: Data(#"{"access_token":"a2","expires_in":3600}"#.utf8), previous: first, now: Date(timeIntervalSince1970: 5000))
    #expect(refreshed?.refresh == "r1" && refreshed?.email == "sam@example.com" && refreshed?.access == "a2")
    #expect(first?.isFresh(now: Date(timeIntervalSince1970: 1000)) == true && first?.isFresh(now: Date(timeIntervalSince1970: 4590)) == false)
    let body = String(decoding: oauth.tokenRequest(code: "4/x y", verifier: "v").httpBody!, as: UTF8.self)
    #expect(body.contains("code=4%2Fx%20y") && body.contains("code_verifier=v") && !body.contains("client_secret"))
}

@Test func signInCanSuggestTheNotebookLMAccountAndReadsTheName() throws {
    let items = URLComponents(url: oauth.begin(loginHint: "sam@example.com").url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(items.first { $0.name == "login_hint" }?.value == "sam@example.com")
    #expect(URLComponents(url: oauth.begin(loginHint: "").url, resolvingAgainstBaseURL: false)!.queryItems!.allSatisfy { $0.name != "login_hint" })
    let claims = Data(#"{"email":"sam@example.com","name":"Sam Rivera\nX"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let tokens = try #require(GoogleOAuth.tokens(from: Data(#"{"access_token":"a","refresh_token":"r","expires_in":60,"id_token":"e30.\#(claims).s"}"#.utf8)))
    #expect(tokens.email == "sam@example.com" && tokens.name == "Sam Rivera X")
    let refreshed = try #require(GoogleOAuth.tokens(from: Data(#"{"access_token":"b","expires_in":60}"#.utf8), previous: tokens))
    #expect(refreshed.name == "Sam Rivera X")
    let old = try JSONDecoder().decode(GoogleOAuth.Tokens.self, from: Data(#"{"access":"a","expires":1,"email":"e@x.com"}"#.utf8))
    #expect(old.name == nil)
}
