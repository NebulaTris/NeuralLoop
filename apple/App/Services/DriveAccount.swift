// The Google account that holds the library (spec 07): sign in through the system's browser sheet (PKCE, no password
// ever touches the app), keep the tokens in the Keychain, refresh them when they expire. Asks only for NeuralLoop's
// own hidden folder in Drive (drive.appdata), the email address, and the name (shown in Settings → Account).

import AuthenticationServices
import Foundation
import NeuralLoopCore
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Observable
final class DriveAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DriveAccount()

    private(set) var email: String?
    private(set) var name: String?
    private(set) var signingIn = false
    var note = ""
    @ObservationIgnored private var tokens: GoogleOAuth.Tokens?
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    private static let keychainName = "GOOGLE_DRIVE_TOKENS"

    /// The OAuth client ID from Config/Google.xcconfig (see docs/DEVELOPMENT.md). Empty until the owner sets it up.
    static var clientID: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? ""
        return value.hasSuffix(".apps.googleusercontent.com") ? value : nil
    }

    var isConfigured: Bool { Self.clientID != nil }
    /// Kept in step with the tokens (which aren't observed), so views showing signed-in things update on sign-in and out.
    private(set) var isSignedIn = false

    override init() {
        super.init()
        if let saved = Keychain.read(Self.keychainName), let data = saved.data(using: .utf8) {
            tokens = try? JSONDecoder().decode(GoogleOAuth.Tokens.self, from: data)
            email = tokens?.email
            name = tokens?.name
            isSignedIn = tokens?.refresh != nil
        }
    }

    /// `loginHint`: the account to suggest (NotebookLM's), so one Google account holds everything.
    func signIn(loginHint: String? = nil) async {
        guard let clientID = Self.clientID else {
            note = "Google Drive sync needs a one-time setup first (see docs/DEVELOPMENT.md → Google Drive sync)."
            return
        }
        let oauth = GoogleOAuth(clientID: clientID)
        let attempt = oauth.begin(loginHint: loginHint)
        signingIn = true
        note = ""
        defer { signingIn = false }
        do {
            // Cancelling the calling task (the first launch's "Not now") closes the sheet, like its own Cancel button.
            let callback: URL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let once = ResumeOnce(continuation)
                    let session = ASWebAuthenticationSession(url: attempt.url, callbackURLScheme: oauth.redirectScheme) { url, error in
                        if let url { once.resume(.success(url)) } else { once.resume(.failure(error ?? DriveError.notSignedIn)) }
                    }
                    session.presentationContextProvider = self
                    session.prefersEphemeralWebBrowserSession = false
                    self.session = session
                    // The sheet couldn't open (no window to show it on, say): say so rather than wait forever.
                    if !session.start() { once.resume(.failure(SignInError.couldNotOpen)) }
                    if Task.isCancelled { session.cancel() }
                }
            } onCancel: {
                Task { @MainActor in self.session?.cancel() }
            }
            session = nil
            guard let code = oauth.code(from: callback, for: attempt) else { throw DriveError.notSignedIn }
            let (data, response) = try await URLSession.shared.data(for: oauth.tokenRequest(code: code, verifier: attempt.verifier))
            guard (response as? HTTPURLResponse)?.statusCode == 200, let fresh = GoogleOAuth.tokens(from: data) else {
                throw DriveError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "sign-in")
            }
            store(fresh)
            DriveSync.shared.signedIn()  // the first sync starts now, not at the next tick
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            session = nil
            note = ""
        } catch {
            session = nil
            note = "Sign-in didn't finish (\(error.localizedDescription)). You can try again any time."
        }
    }

    /// `removeNote`: take this device off the library's device list first (best effort, while the tokens still work).
    /// Not when Google has already refused the tokens: there's nothing left to delete it with.
    func signOut(removeNote: Bool = true) async {
        if removeNote, isSignedIn { await DriveSync.shared.signingOut() }
        if let token = tokens?.refresh ?? tokens?.access, let clientID = Self.clientID {
            _ = try? await URLSession.shared.data(for: GoogleOAuth(clientID: clientID).revokeRequest(token: token))  // best effort: the local tokens go regardless
        }
        tokens = nil
        isSignedIn = false
        email = nil
        name = nil
        Keychain.save(Self.keychainName, "")
    }

    /// A valid access token, refreshed when needed, or right away with `forceRefresh` (Google refused the current one).
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens, let refresh = current.refresh, let clientID = Self.clientID else { throw DriveError.notSignedIn }
        if current.isFresh(), !forceRefresh { return current.access }
        let (data, response) = try await URLSession.shared.data(for: GoogleOAuth(clientID: clientID).refreshRequest(refreshToken: refresh))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let fresh = GoogleOAuth.tokens(from: data, previous: current) else {
            if status == 400 || status == 401 { await signOut(removeNote: false) }  // revoked or expired for good: sign in again
            throw DriveError.http(status, "token refresh")
        }
        store(fresh)
        return fresh.access
    }

    private func store(_ fresh: GoogleOAuth.Tokens) {
        tokens = fresh
        isSignedIn = fresh.refresh != nil
        email = fresh.email
        name = fresh.name
        if let data = try? JSONEncoder().encode(fresh), let text = String(data: data, encoding: .utf8) {
            // Readable after the first unlock, so a Mac preparing books overnight can keep syncing.
            if let problem = Keychain.save(Self.keychainName, text, availableWhileLocked: true) { note = problem }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            return UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

enum SignInError: LocalizedError {
    case couldNotOpen
    var errorDescription: String? { "the Google sign-in window couldn't open" }
}

/// Resumes a continuation at most once (the sign-in sheet's callback and a failed start could both try).
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()
    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
