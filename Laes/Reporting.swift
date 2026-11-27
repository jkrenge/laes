import BoringKit
import Foundation

/// Crash reports, usage counts and feedback go to lães's own server (BoringKit, a Cloudflare Worker).
/// Nothing from the calendar, tasks or notes ever does: events carry fixed names and numbers only.
enum Reporting {
    // Installed versions keep calling this address, so it can't move once a release is out.
    static let api = URL(string: "https://api.laesapp.com")!

    /// First thing at launch: anything that crashes before it goes unseen.
    static func start() {
        BoringKit.start(api: api)
        Aptabase.shared.trackEvent("app_opened")
    }

    /// An error the app didn't expect. Microsoft's messages can name people and items,
    /// so only the kind of error and the HTTP status go out, never the message.
    static func failed(_ what: String, _ error: Error) {
        Aptabase.shared.trackEvent("\(what)_failed", with: [
            "type": String(describing: type(of: error)),
            "status": (error as? GraphError)?.status ?? 0,
        ])
    }
}
