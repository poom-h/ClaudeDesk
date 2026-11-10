import Foundation
import EventKit
import AppKit

/// Mail and calendar from the accounts already on this Mac: macOS calendars (which include Google Calendar once it's
/// added in Internet Accounts) and Apple Mail. Read-only, no keys: macOS asks once for each permission.
enum MacAccounts {
    struct Failure: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

    private static let store = EKEventStore()

    static var calendarAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var calendarDenied: Bool { [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) }

    /// Shows macOS's calendar permission prompt the first time; afterwards it just reports the answer.
    static func requestCalendarAccess() async -> Bool {
        if calendarAllowed { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func events(from start: Date, to end: Date) throws -> [CalendarEvent] {
        guard calendarAllowed else {
            throw Failure(message: calendarDenied
                ? "ClaudeDesk isn't allowed to read your calendars. Turn it on in System Settings › Privacy & Security › Calendars."
                : "Allow calendar access in Settings › Integrations.")
        }
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled, let start = event.startDate, let end = event.endDate else { return nil }
            // Google calendars are named by their address; other calendars go by their account (iCloud, Exchange…).
            let title = event.calendar?.title ?? ""
            let source = title.contains("@") ? title : event.calendar?.source?.title ?? "Calendar"
            return CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString, account: source.lowercased(),
                                 title: event.title?.isEmpty == false ? event.title! : "(no title)", start: start, end: end,
                                 allDay: event.isAllDay, location: event.location ?? "", meetLink: videoLink(event), webLink: nil)
        }.sorted { $0.start < $1.start }
    }

    /// A video-call link in the event's URL, location or notes: Google Meet, Zoom, Teams or Webex.
    private static func videoLink(_ event: EKEvent) -> String? {
        if let url = event.url?.absoluteString, isVideo(url) { return url }
        let text = [event.location ?? "", event.notes ?? ""].joined(separator: " ")
        guard let range = text.range(of: #"https://[^\s<>"]*(meet\.google\.com|zoom\.us|teams\.microsoft\.com|webex\.com)[^\s<>"]*"#,
                                     options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func isVideo(_ url: String) -> Bool {
        ["meet.google.com", "zoom.us", "teams.microsoft.com", "webex.com"].contains { url.contains($0) }
    }

    /// Recent inbox mail from Apple Mail. The first time, macOS asks whether ClaudeDesk may control Mail.
    static func mail(days: Int = 3, limit: Int = 80) async throws -> [MailMessage] {
        await openMailInBackground()
        let output = try await runAppleScript(AppleMail.script(days: days, limit: limit))
        return AppleMail.messages(from: output)
    }

    /// Mail has to be running for ClaudeDesk to ask it; open it hidden so it doesn't take over the screen.
    private static func openMailInBackground() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try? await Task.sleep(nanoseconds: 3_000_000_000)   // give Mail a moment to load its accounts
    }

    /// Runs AppleScript in `osascript`, off the main thread, with a time limit.
    private static func runAppleScript(_ source: String, timeout: TimeInterval = 120) async throws -> String {
        try await Task.detached { try runBlocking(source, timeout: timeout) }.value
    }

    /// Waits for `osascript` in plain blocking code, so it can't tie up the async thread pool's cooperative threads.
    private static func runBlocking(_ source: String, timeout: TimeInterval) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            // Read both pipes while it runs, so a large answer can't fill a pipe and stall it.
            var outData = Data(), errData = Data()
            let readers = DispatchGroup()
            readers.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
            readers.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                throw Failure(message: "Apple Mail took too long to answer.")
            }
            readers.wait()
            let errorText = String(data: errData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                if errorText.contains("-1743") || errorText.localizedCaseInsensitiveContains("not authorized") {
                    throw Failure(message: "ClaudeDesk isn't allowed to read Mail. Turn it on in System Settings › Privacy & Security › Automation › ClaudeDesk › Mail.")
                }
                throw Failure(message: "Apple Mail: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return String(data: outData, encoding: .utf8) ?? ""
    }

    static func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
