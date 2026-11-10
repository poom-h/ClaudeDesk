import Foundation
import Network
import AppKit

/// Google sign-in, Gmail and Calendar reads, and Jev triage calls. Everything here is read-only toward Google,
/// and every secret comes from the Keychain. Runs off the main thread.
enum GoogleService {
    struct Failure: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

    /// Short-lived access tokens, in memory only. Refresh tokens stay in the Keychain.
    actor Tokens {
        private var cache: [String: (token: String, expires: Date)] = [:]
        func valid(_ account: String) -> String? {
            guard let entry = cache[account], entry.expires > Date().addingTimeInterval(60) else { return nil }
            return entry.token
        }
        func store(_ token: String, for account: String, lifetime: TimeInterval) { cache[account] = (token, Date().addingTimeInterval(lifetime)) }
        func forget(_ account: String) { cache[account] = nil }
    }
    static let tokens = Tokens()

    private static func client() throws -> (id: String, secret: String) {
        guard let id = Secrets.get(Secrets.Key.googleClientID), !id.isEmpty,
              let secret = Secrets.get(Secrets.Key.googleClientSecret), !secret.isEmpty else {
            throw Failure(message: "Add your Google OAuth client ID and secret in Settings › Integrations first.")
        }
        return (id, secret)
    }

    // MARK: Sign-in

    /// Opens Google's sign-in in your browser and waits for it to come back to ClaudeDesk. Returns the address.
    static func signIn() async throws -> String {
        let client = try client()
        let receiver = try LoopbackReceiver()
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = GoogleOAuth.codeVerifier(), state = UUID().uuidString
        let url = GoogleOAuth.authorizationURL(clientID: client.id, redirect: redirect, state: state, challenge: GoogleOAuth.challenge(for: verifier))
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        let callback = try await receiver.waitForCallback(timeout: 300)
        if let error = callback.error { throw Failure(message: error == "access_denied" ? "Google sign-in was cancelled." : "Google sign-in failed: \(error).") }
        guard callback.state == state, let code = callback.code else { throw Failure(message: "Google's reply didn't match this sign-in. Try again.") }
        let reply = try await post(GoogleOAuth.tokenEndpoint,
                                   body: GoogleOAuth.exchangeBody(code: code, verifier: verifier, clientID: client.id, secret: client.secret, redirect: redirect))
        guard let refresh = reply["refresh_token"] as? String, let access = reply["access_token"] as? String else {
            throw Failure(message: "Google didn't return a sign-in token: \(reply["error_description"] as? String ?? reply["error"] as? String ?? "unknown error").")
        }
        guard let email = (reply["id_token"] as? String).flatMap(GoogleOAuth.email(fromIDToken:)) else { throw Failure(message: "Google didn't say which account signed in.") }
        guard Secrets.set(refresh, for: Secrets.Key.googleRefreshToken(email)) else { throw Failure(message: "Couldn't save the sign-in to the Keychain.") }
        await tokens.store(access, for: email, lifetime: reply["expires_in"] as? Double ?? 3000)
        return email
    }

    static func accessToken(for account: String) async throws -> String {
        if let token = await tokens.valid(account) { return token }
        let client = try client()
        guard let refresh = Secrets.get(Secrets.Key.googleRefreshToken(account)) else {
            throw Failure(message: "\(account) isn't signed in. Add it again in Settings › Integrations.")
        }
        let reply = try await post(GoogleOAuth.tokenEndpoint, body: GoogleOAuth.refreshBody(refreshToken: refresh, clientID: client.id, secret: client.secret))
        guard let access = reply["access_token"] as? String else {
            if reply["error"] as? String == "invalid_grant" {
                throw Failure(message: "Google signed \(account) out (while a Google OAuth app is in Testing, sign-ins last 7 days). Sign in again in Settings.")
            }
            throw Failure(message: "Couldn't refresh \(account): \(reply["error_description"] as? String ?? reply["error"] as? String ?? "unknown error").")
        }
        await tokens.store(access, for: account, lifetime: reply["expires_in"] as? Double ?? 3000)
        return access
    }

    // MARK: Gmail and Calendar

    /// Recent inbox mail, newest first.
    static func fetchMail(account: String, query: String = "in:inbox newer_than:4d", limit: Int = 30) async throws -> [MailMessage] {
        var list = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        list.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(limit))]
        let ids = (try await get(list.url!, account: account)["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return try await withThrowingTaskGroup(of: MailMessage?.self) { group in
            for id in ids {
                group.addTask {
                    let json = try await get(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!, account: account)
                    return Gmail.message(from: json, account: account)
                }
            }
            var messages: [MailMessage] = []
            for try await message in group { if let message { messages.append(message) } }
            return messages.sorted { $0.date > $1.date }
        }
    }

    /// Events on the primary calendar between two times.
    static func fetchEvents(account: String, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        let iso = ISO8601DateFormatter()
        components.queryItems = [URLQueryItem(name: "timeMin", value: iso.string(from: start)), URLQueryItem(name: "timeMax", value: iso.string(from: end)),
                                 URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime"),
                                 URLQueryItem(name: "maxResults", value: "50")]
        return GoogleCalendar.events(from: try await get(components.url!, account: account), account: account)
    }

    // MARK: Jev

    static func triage(_ message: MailMessage, apiKey: String, model: String) async throws -> MailTriage {
        var request = URLRequest(url: JevTriage.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JevTriage.requestBody(for: message, model: model)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw Failure(message: "Jev didn't accept the API key. Check it in Settings › Integrations.")
        }
        return try JevTriage.parse(data)
    }

    // MARK: HTTP

    private static func get(_ url: URL, account: String, retried: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(try await accessToken(for: account))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried {
            await tokens.forget(account)
            return try await get(url, account: account, retried: true)
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw Failure(message: "Google (\(account)): \(message)")
        }
        return json
    }

    private static func post(_ url: URL, body: Data) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// A one-shot web server on 127.0.0.1 that catches Google's redirect after you sign in, then closes.
final class LoopbackReceiver: @unchecked Sendable {
    typealias Callback = (code: String?, state: String?, error: String?)
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Callback, Error>?
    private var pending: Result<Callback, Error>?
    private var finished = false
    private var readyResumed = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the port the redirect should use.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.resumeReady(ready, .success(self.listener.port?.rawValue ?? 0))
                case .failed(let error): self.resumeReady(ready, .failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: .global())
        }
    }

    private func resumeReady(_ ready: CheckedContinuation<UInt16, Error>, _ result: Result<UInt16, Error>) {
        lock.lock()
        guard !readyResumed else { lock.unlock(); return }
        readyResumed = true
        lock.unlock()
        ready.resume(with: result)
    }

    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending { lock.unlock(); continuation.resume(with: pending); return }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(GoogleService.Failure(message: "Google sign-in timed out. Try again.")))
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let callback = GoogleOAuth.callback(fromRequestLine: text.components(separatedBy: "\r\n").first ?? "")
            let done = callback.code != nil || callback.error != nil
            let html = done
                ? "<html><body style=\"font-family:-apple-system;background:#0a0c18;color:#e6eaf7;padding:48px\"><h2>\(callback.error == nil ? "ClaudeDesk is connected." : "Sign-in didn't finish.")</h2><p>You can close this tab and go back to ClaudeDesk.</p></body></html>"
                : "<html><body>Not found</body></html>"
            let reply = "HTTP/1.1 \(done ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if done { self?.finish(.success(callback)) }
        }
    }

    private func finish(_ result: Result<Callback, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        lock.unlock()
        listener.cancel()
        continuation?.resume(with: result)
    }
}
